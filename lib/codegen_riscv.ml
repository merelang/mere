(* codegen_riscv.ml — a fifth Mere backend that emits raw RV32IM machine code.
   Where -c / -ll / -w delegate to a C compiler / LLVM / a Wasm runtime, this
   backend lowers Mere all the way to a flat little-endian binary that runs on
   the Mere-written RV32I emulator (memu/riscv). "The self-made language runs on
   the self-made CPU."

   This is the M0 vertical slice: 32-bit integers, arithmetic, comparisons,
   short-circuit &&/||, if, let, top-level (mutually) recursive functions,
   saturated calls, and print_int. No heap, closures, strings, or ADTs yet —
   anything outside the slice raises Codegen_error with a clear message.

   Value representation: everything is a 32-bit int in a register (bool 0/1,
   unit 0). Evaluation is a simple stack machine — each expression leaves its
   result in a0, spilling intermediates to the memory stack (sp). Named
   bindings (params + lets) live in fp-relative frame slots. No register
   allocation yet; correctness first.

   Output: the returned string's bytes ARE the flat binary, so
   `mere -rv prog.mere > prog.bin` produces something the emulator loads at
   address 0 and runs from _start with no external assembler or linker. *)

exception Codegen_error of Loc.t * string

let err loc msg = raise (Codegen_error (loc, msg))

(* --- register numbers (ABI names) --------------------------------------- *)
let zero = 0
let ra = 1
let sp = 2
let gp = 3            (* repurposed as the bump-heap top pointer *)
let fp = 8            (* s0 *)
let t0 = 5
let t1 = 6
let t2 = 7
let t3 = 28
let t4 = 29
let t5 = 30
let t6 = 31
let a0 = 10
let a1 = 11
let a2 = 12
let a7 = 17

(* --- instruction encoders (mirror the emulator's asm_* / imm_* pair) ----- *)
let enc_r f7 rs2 rs1 f3 rd op =
  (f7 lsl 25) lor (rs2 lsl 20) lor (rs1 lsl 15) lor (f3 lsl 12) lor (rd lsl 7) lor op

let enc_i imm rs1 f3 rd op =
  ((imm land 0xFFF) lsl 20) lor (rs1 lsl 15) lor (f3 lsl 12) lor (rd lsl 7) lor op

let enc_s imm rs2 rs1 f3 op =
  let i = imm land 0xFFF in
  ((i lsr 5) lsl 25) lor (rs2 lsl 20) lor (rs1 lsl 15) lor (f3 lsl 12)
  lor ((i land 0x1F) lsl 7) lor op

let enc_u imm20 rd op =
  ((imm20 land 0xFFFFF) lsl 12) lor (rd lsl 7) lor op

let enc_b imm rs2 rs1 f3 op =
  let i = imm land 0x1FFF in
  let b12 = (i lsr 12) land 1 in
  let b11 = (i lsr 11) land 1 in
  let b10_5 = (i lsr 5) land 0x3F in
  let b4_1 = (i lsr 1) land 0xF in
  (b12 lsl 31) lor (b10_5 lsl 25) lor (rs2 lsl 20) lor (rs1 lsl 15)
  lor (f3 lsl 12) lor (b4_1 lsl 8) lor (b11 lsl 7) lor op

let enc_j imm rd op =
  let i = imm land 0x1FFFFF in
  let b20 = (i lsr 20) land 1 in
  let b19_12 = (i lsr 12) land 0xFF in
  let b11 = (i lsr 11) land 1 in
  let b10_1 = (i lsr 1) land 0x3FF in
  (b20 lsl 31) lor (b19_12 lsl 12) lor (b11 lsl 20) lor (b10_1 lsl 21)
  lor (rd lsl 7) lor op

(* --- emitted items: concrete words + label-relative jumps/branches ------- *)
type item =
  | Word of int                       (* fully encoded instruction *)
  | Label of string                   (* zero-width address marker *)
  | Jal of int * string               (* rd, target label -> J-type (op 0x6F) *)
  | Branch of int * int * int * string (* f3, rs1, rs2, target -> B-type (op 0x63) *)
  | LoadAddr of int * string          (* rd, label -> lui+addi loading label's absolute addr (8 bytes) *)
  | Bytes of string                   (* raw data (rodata); length is a multiple of 4 *)

let items : item list ref = ref []
let emit x = items := x :: !items
let emit_word w = emit (Word w)

let lbl_counter = ref 0
let fresh_label prefix = incr lbl_counter; prefix ^ string_of_int !lbl_counter

(* string literals collected as rodata blocks (label, raw bytes), emitted
   after the code. A string value is a pointer to [len:4][bytes][pad to 4]. *)
let string_data : (string * string) list ref = ref []
let mk_str_block (s : string) : string =
  let len = String.length s in
  let b = Buffer.create (8 + len) in
  Buffer.add_char b (Char.chr (len land 0xFF));
  Buffer.add_char b (Char.chr ((len lsr 8) land 0xFF));
  Buffer.add_char b (Char.chr ((len lsr 16) land 0xFF));
  Buffer.add_char b (Char.chr ((len lsr 24) land 0xFF));
  Buffer.add_string b s;
  let pad = (4 - ((4 + len) land 3)) land 3 in
  for _ = 1 to pad do Buffer.add_char b '\000' done;
  Buffer.contents b

(* load a 32-bit immediate into rd *)
let li rd v =
  if v >= -2048 && v <= 2047 then
    emit_word (enc_i v zero 0 rd 0x13)                 (* addi rd, x0, v *)
  else begin
    let hi = (v + 0x800) asr 12 in
    let lo = v - (hi lsl 12) in
    emit_word (enc_u (hi land 0xFFFFF) rd 0x37);       (* lui  rd, hi *)
    emit_word (enc_i lo rd 0 rd 0x13)                  (* addi rd, rd, lo *)
  end

(* stack helpers: the memory stack (sp) holds evaluation temporaries *)
let push rd =
  emit_word (enc_i (-4) sp 0 sp 0x13);                 (* addi sp, sp, -4 *)
  emit_word (enc_s 0 rd sp 2 0x23)                     (* sw   rd, 0(sp) *)
let pop rd =
  emit_word (enc_i 0 sp 2 rd 0x03);                    (* lw   rd, 0(sp) *)
  emit_word (enc_i 4 sp 0 sp 0x13)                     (* addi sp, sp, 4 *)

(* bump-allocate n words, leaving the block pointer in rd. The caller must
   not make any call between this and its field stores (rd/gp are volatile). *)
let alloc_words rd n =
  emit_word (enc_i 0 gp 0 rd 0x13);                    (* mv   rd, gp *)
  emit_word (enc_i (n * 4) gp 0 gp 0x13)               (* addi gp, gp, n*4 *)

(* pending lambdas to lift: (label, captured var names, param, body). Filled
   by the Fun case, drained (and possibly extended) by build_items. *)
let lambdas : (string * string list * string * Ast.expr) list ref = ref []

(* the variables a pattern binds *)
let rec pat_vars (p : Ast.pattern) : string list =
  match p.Ast.pnode with
  | Ast.P_var x -> [x]
  | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit -> []
  | Ast.P_tuple ps -> List.concat_map pat_vars ps
  | Ast.P_constr (_, Some s) -> pat_vars s
  | Ast.P_constr (_, None) -> []
  | Ast.P_as (inner, x) -> x :: pat_vars inner
  | Ast.P_or (a, _) -> pat_vars a
  | Ast.P_record (_, fs) -> List.concat_map (fun (_, q) -> pat_vars q) fs

(* free variables of an expression (respecting binders) — used to decide
   what a lambda must capture *)
let rec free_vars_of (e : Ast.expr) : string list =
  let rm names lst = List.filter (fun x -> not (List.mem x names)) lst in
  match e.node with
  | Ast.Var x -> [x]
  | Ast.Int_lit _ | Ast.Bool_lit _ | Ast.Unit_lit | Ast.Str_lit _ | Ast.Float_lit _ -> []
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) -> free_vars_of a @ free_vars_of b
  | Ast.Neg a | Ast.Annot (a, _) -> free_vars_of a
  | Ast.If (a, b, c) -> free_vars_of a @ free_vars_of b @ free_vars_of c
  | Ast.Let (p, rhs, body) -> free_vars_of rhs @ rm (pat_vars p) (free_vars_of body)
  | Ast.Let_rec (bs, body) ->
    let names = List.map fst bs in
    rm names (List.concat_map (fun (_, e) -> free_vars_of e) bs @ free_vars_of body)
  | Ast.Fun (x, _, b) -> rm [x] (free_vars_of b)
  | Ast.App (a, b) -> free_vars_of a @ free_vars_of b
  | Ast.Tuple es -> List.concat_map free_vars_of es
  | Ast.Constr (_, Some a) -> free_vars_of a
  | Ast.Constr (_, None) -> []
  | Ast.Match (s, arms) ->
    free_vars_of s
    @ List.concat_map (fun (p, g, b) ->
        rm (pat_vars p) (free_vars_of b @ (match g with Some gg -> free_vars_of gg | None -> []))) arms
  | _ -> []

let dedup lst = List.fold_left (fun acc x -> if List.mem x acc then acc else x :: acc) [] lst |> List.rev

(* --- program shape: peel top-level fn bindings, find the main body ------- *)

(* peel `fn a -> fn b -> body` into ([a;b], body) *)
let rec collect_fun (e : Ast.expr) =
  match e.node with
  | Ast.Fun (p, _, body) -> let (ps, b) = collect_fun body in (p :: ps, b)
  | _ -> ([], e)

(* free-ish var occurrences, used only to compute reachable top-level fns.
   Over-approximation is fine: reachability filters against the tops map. *)
let rec vars_in (e : Ast.expr) (acc : string list) : string list =
  match e.node with
  | Ast.Var v -> v :: acc
  | Ast.Int_lit _ | Ast.Bool_lit _ | Ast.Unit_lit
  | Ast.Str_lit _ | Ast.Float_lit _ -> acc
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) ->
    vars_in a (vars_in b acc)
  | Ast.Neg a | Ast.Annot (a, _) -> vars_in a acc
  | Ast.If (a, b, c) -> vars_in a (vars_in b (vars_in c acc))
  | Ast.Let (_, a, b) -> vars_in a (vars_in b acc)
  | Ast.Let_rec (bs, b) ->
    List.fold_left (fun ac (_, e) -> vars_in e ac) (vars_in b acc) bs
  | Ast.Fun (_, _, b) -> vars_in b acc
  | Ast.App (a, b) -> vars_in a (vars_in b acc)
  | Ast.Tuple elems -> List.fold_left (fun ac el -> vars_in el ac) acc elems
  | Ast.Constr (_, Some a) -> vars_in a acc
  | Ast.Match (scrut, arms) ->
    List.fold_left (fun ac (_, g, b) ->
      let ac = vars_in b ac in
      match g with Some gg -> vars_in gg ac | None -> ac) (vars_in scrut acc) arms
  | _ -> acc

(* the tops map: top-level function name -> (params, body) *)
let tops : (string, string list * Ast.expr) Hashtbl.t = Hashtbl.create 64

(* constructor name -> tag (index within its type, declaration order), read
   by Constr (writes the tag) and Match (compares against it). Distinct only
   within a type, which is all Match needs. Populated from Top_type decls. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 32
let tag_of loc name =
  match Hashtbl.find_opt variant_tags (Ast.canonical_ctor name) with
  | Some t -> t
  | None -> err loc (Printf.sprintf "RV32I: unknown constructor `%s`" name)

(* peel the leading chain of `let f = fn ...` / `let rec f = fn ...` into
   `tops`, returning the remaining expression as the program's main body. *)
let rec split_tops (e : Ast.expr) : Ast.expr =
  match e.node with
  | Ast.Let ({ pnode = Ast.P_var name; _ }, ({ node = Ast.Fun _; _ } as f), body) ->
    Hashtbl.replace tops name (collect_fun f);
    split_tops body
  | Ast.Let_rec (bindings, body)
    when List.for_all (fun (_, v) -> match v.Ast.node with Ast.Fun _ -> true | _ -> false) bindings ->
    List.iter (fun (name, f) -> Hashtbl.replace tops name (collect_fun f)) bindings;
    split_tops body
  | _ -> e

(* --- expression compiler: result left in a0 ------------------------------ *)

(* env maps a bound name to its fp-relative frame slot index *)
type env = (string * int) list

let slot_off i = i * 4

(* count binding introductions to size a function frame (each named binding
   gets a distinct slot — P_var lets and each P_var inside a tuple pattern) *)
let rec pvars_in_pattern p =
  match p.Ast.pnode with
  | Ast.P_var _ -> 1
  | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit -> 0
  | Ast.P_tuple pats -> List.fold_left (fun n q -> n + pvars_in_pattern q) 0 pats
  | Ast.P_constr (_, Some sub) -> pvars_in_pattern sub
  | Ast.P_constr (_, None) -> 0
  | Ast.P_as (inner, _) -> 1 + pvars_in_pattern inner
  | Ast.P_or (a, _) -> pvars_in_pattern a
  | Ast.P_record (_, fields) -> List.fold_left (fun n (_, q) -> n + pvars_in_pattern q) 0 fields

let rec count_lets (e : Ast.expr) : int =
  match e.node with
  | Ast.Let (p, a, b) -> pvars_in_pattern p + count_lets a + count_lets b
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) -> count_lets a + count_lets b
  | Ast.Neg a | Ast.Annot (a, _) -> count_lets a
  | Ast.If (a, b, c) -> count_lets a + count_lets b + count_lets c
  | Ast.App (a, b) -> count_lets a + count_lets b
  | Ast.Tuple elems -> List.fold_left (fun n el -> n + count_lets el) 0 elems
  | Ast.Constr (_, Some a) -> count_lets a
  | Ast.Match (scrut, arms) ->
    (* +1 for the scrutinee stash slot, plus each arm's pattern bindings *)
    count_lets scrut + 1
    + List.fold_left (fun n (pat, guard, body) ->
        n + pvars_in_pattern pat + count_lets body
        + (match guard with Some g -> count_lets g | None -> 0)) 0 arms
  | _ -> 0

let is_top name = Hashtbl.mem tops name

(* flatten `((f a) b) c` into (f, [a;b;c]) *)
let rec flatten_app (e : Ast.expr) =
  match e.node with
  | Ast.App (f, a) -> let (h, args) = flatten_app f in (h, args @ [a])
  | _ -> (e, [])

(* --- register allocation (M1) -------------------------------------------
   Named bindings (params + lets) live in callee-saved registers s1..s11.
   They are callee-saved, so a value in an s-register survives any nested
   call (the callee saves/restores it) — which is exactly what lets us read
   an operand straight out of its register even when the other operand does
   a call. Functions with more than 11 live names spill the overflow to
   fp-relative memory slots. Evaluation temporaries still use the memory
   stack, which is always correct across calls. *)

let sregs = [| 9; 18; 19; 20; 21; 22; 23; 24; 25; 26; 27 |]   (* s1..s11 *)
let nregs = Array.length sregs

(* per-function frame shape, set by emit_function *)
let cur_nsaved = ref 0        (* how many s-registers this function uses *)
let cur_noverflow = ref 0     (* how many bindings spilled to memory *)

type loc = Reg of int | Mem of int   (* Mem i = fp-relative word slot i *)

(* binding index -> where it lives. Indices 0..nsaved-1 use sregs[i];
   the rest live in memory slots 0..noverflow-1. *)
let loc_of (idx : int) : loc =
  if idx < !cur_nsaved then Reg sregs.(idx)
  else Mem (idx - !cur_nsaved)

let is_small n = n >= -2048 && n <= 2047

(* binding_ctr tracks the next binding index within the function *)
let slot_ctr = ref 0

(* If e is a variable that currently lives in a register, that register —
   used to read an operand in place without emitting any code. *)
let simple_reg (env : env) (e : Ast.expr) : int option =
  match e.node with
  | Ast.Var x ->
    (match List.assoc_opt x env with
     | Some idx -> (match loc_of idx with Reg r -> Some r | Mem _ -> None)
     | None -> None)
  | _ -> None

(* store a0 into / load a0 from a binding's home location *)
let store_a0_to idx =
  match loc_of idx with
  | Reg r -> emit_word (enc_i 0 a0 0 r 0x13)                      (* mv sX, a0 *)
  | Mem slot -> emit_word (enc_s (slot_off slot) a0 fp 2 0x23)    (* sw a0, slot(fp) *)
let load_to_a0 idx =
  match loc_of idx with
  | Reg r -> emit_word (enc_i 0 r 0 a0 0x13)                      (* mv a0, sX *)
  | Mem slot -> emit_word (enc_i (slot_off slot) fp 2 a0 0x03)    (* lw a0, slot(fp) *)

let emit_binop op rd rs1 rs2 loc =
  match op with
  | Ast.Add -> emit_word (enc_r 0 rs2 rs1 0 rd 0x33)
  | Ast.Sub -> emit_word (enc_r 0x20 rs2 rs1 0 rd 0x33)
  | Ast.Mul -> emit_word (enc_r 1 rs2 rs1 0 rd 0x33)
  | Ast.Div -> emit_word (enc_r 1 rs2 rs1 4 rd 0x33)
  | Ast.Mod -> emit_word (enc_r 1 rs2 rs1 6 rd 0x33)
  | Ast.Concat -> err loc "RV32I: internal — string concat is handled in compile_bin"

let rec compile_expr (env : env) (e : Ast.expr) : unit =
  match e.node with
  | Ast.Int_lit n -> li a0 n
  | Ast.Bool_lit b -> li a0 (if b then 1 else 0)
  | Ast.Unit_lit -> li a0 0
  | Ast.Var v ->
    (match List.assoc_opt v env with
     | Some idx ->
       (match loc_of idx with
        | Reg r -> emit_word (enc_i 0 r 0 a0 0x13)                   (* mv  a0, sX *)
        | Mem slot -> emit_word (enc_i (slot_off slot) fp 2 a0 0x03))(* lw  a0, slot(fp) *)
     | None ->
       if is_top v then
         err e.loc (Printf.sprintf
           "RV32I: `%s` used as a value (higher-order / partial application not supported yet)" v)
       else
         err e.loc (Printf.sprintf "RV32I: unbound variable `%s`" v))
  | Ast.Neg a ->
    compile_expr env a;
    emit_word (enc_r 0x20 a0 zero 0 a0 0x33)                         (* sub a0, x0, a0 *)
  | Ast.Bin (op, l, r) -> compile_bin env op l r
  | Ast.Cmp (op, l, r) -> compile_cmp env op l r
  | Ast.Logic (op, l, r) -> compile_logic env op l r
  | Ast.If (c, t, e2) ->
    let l_else = fresh_label ".else" in
    let l_end = fresh_label ".endif" in
    compile_expr env c;
    emit (Branch (0, a0, zero, l_else));                             (* beq a0, x0, else *)
    compile_expr env t;
    emit (Jal (zero, l_end));                                        (* j end *)
    emit (Label l_else);
    compile_expr env e2;
    emit (Label l_end)
  | Ast.Let ({ pnode = Ast.P_var name; _ }, rhs, body) ->
    compile_expr env rhs;
    let idx = !slot_ctr in incr slot_ctr;
    (match loc_of idx with
     | Reg r -> emit_word (enc_i 0 a0 0 r 0x13)                      (* mv  sX, a0 *)
     | Mem slot -> emit_word (enc_s (slot_off slot) a0 fp 2 0x23));  (* sw  a0, slot(fp) *)
    compile_expr ((name, idx) :: env) body
  | Ast.Let ({ pnode = Ast.P_wild; _ }, rhs, body) ->
    compile_expr env rhs;
    compile_expr env body
  | Ast.Let ({ pnode = Ast.P_tuple pats; _ }, rhs, body) ->
    (* destructure a heap tuple: rhs -> pointer, load each field into its binding *)
    compile_expr env rhs;
    emit_word (enc_i 0 a0 0 t1 0x13);                                (* mv t1, a0 (tuple ptr) *)
    let env = ref env in
    List.iteri (fun i p ->
      match p.Ast.pnode with
      | Ast.P_wild -> ()
      | Ast.P_var name ->
        emit_word (enc_i (i * 4) t1 2 a0 0x03);                      (* lw a0, i*4(t1) *)
        let idx = !slot_ctr in incr slot_ctr;
        (match loc_of idx with
         | Reg r -> emit_word (enc_i 0 a0 0 r 0x13)                  (* mv sX, a0 *)
         | Mem slot -> emit_word (enc_s (slot_off slot) a0 fp 2 0x23));
        env := (name, idx) :: !env
      | _ -> err p.Ast.ploc "RV32I: nested tuple patterns are not supported yet"
    ) pats;
    compile_expr !env body
  | Ast.Let (_, _, _) ->
    err e.loc "RV32I: only `let x = ...`, `let _ = ...`, and `let (a, b) = ...` are supported"
  | Ast.Tuple elems ->
    (* evaluate elements (each may call/alloc), then allocate the block and
       fill it — no call happens between the bump and the stores *)
    List.iter (fun el -> compile_expr env el; push a0) elems;
    let n = List.length elems in
    alloc_words t1 n;                                                (* t1 = block ptr *)
    for i = n - 1 downto 0 do
      pop t0;
      emit_word (enc_s (i * 4) t0 t1 2 0x23)                         (* sw t0, i*4(t1) *)
    done;
    emit_word (enc_i 0 t1 0 a0 0x13)                                 (* mv a0, t1 *)
  | Ast.Constr (name, None) ->
    (* nullary constructor: a 1-word block holding just the tag *)
    let tag = tag_of e.loc name in
    alloc_words t1 1;
    li t0 tag; emit_word (enc_s 0 t0 t1 2 0x23);                     (* sw t0, 0(t1) *)
    emit_word (enc_i 0 t1 0 a0 0x13)                                 (* mv a0, t1 *)
  | Ast.Constr (name, Some arg) ->
    (* [tag][payload]; payload is one word (an int, or a pointer — a tuple
       pointer when the constructor has several fields) *)
    compile_expr env arg; push a0;
    let tag = tag_of e.loc name in
    alloc_words t1 2;
    pop t0; emit_word (enc_s 4 t0 t1 2 0x23);                        (* sw t0, 4(t1) — payload *)
    li t0 tag; emit_word (enc_s 0 t0 t1 2 0x23);                     (* sw t0, 0(t1) — tag *)
    emit_word (enc_i 0 t1 0 a0 0x13)                                 (* mv a0, t1 *)
  | Ast.Match (scrut, arms) -> compile_match env scrut arms
  | Ast.Annot (a, _) -> compile_expr env a
  | Ast.App (_, _) -> compile_app env e
  | Ast.Fun (param, _, body) ->
    (* closure = [code_ptr][captured...]; capture the locals the body uses *)
    let fvs = dedup (free_vars_of e) |> List.filter (fun n -> List.mem_assoc n env) in
    let label = fresh_label "__lam_" in
    lambdas := (label, fvs, param, body) :: !lambdas;
    let k = List.length fvs in
    List.iter (fun name -> load_to_a0 (List.assoc name env); push a0) fvs;
    alloc_words t1 (k + 1);                                         (* [code][cap...] *)
    for i = k - 1 downto 0 do pop t0; emit_word (enc_s ((i + 1) * 4) t0 t1 2 0x23) done;
    emit (LoadAddr (t0, label));                                    (* t0 = &lambda code *)
    emit_word (enc_s 0 t0 t1 2 0x23);                               (* sw t0, 0(t1) *)
    emit_word (enc_i 0 t1 0 a0 0x13)                                (* mv a0, t1 *)
  | Ast.Let_rec _ ->
    err e.loc "RV32I: local `let rec` is not supported yet (define functions at top level)"
  | Ast.Str_lit s ->
    let label = fresh_label "str_" in
    string_data := (label, mk_str_block s) :: !string_data;
    emit (LoadAddr (a0, label))                                     (* a0 = &block *)
  | Ast.Float_lit _ -> err e.loc "RV32I: floats are not supported yet"
  | _ -> err e.loc "RV32I: this expression form is not supported yet"

(* Evaluate l and r so that left ends in reg RL and right in reg RR, then
   run [k RL RR]. Reads operands straight from their registers when possible
   (s-registers survive the other operand's evaluation, calls included);
   otherwise spills the left result to the memory stack across r. *)
and with_operands env l r (k : int -> int -> unit) =
  match simple_reg env l, simple_reg env r with
  | Some a, Some b -> k a b
  | None, Some b -> compile_expr env l; k a0 b            (* left -> a0, right in place *)
  | Some a, None -> compile_expr env r; k a a0            (* right -> a0, left in place (s-reg) *)
  | None, None ->
    compile_expr env l; push a0;
    compile_expr env r; pop t0;                           (* t0 = left, a0 = right *)
    k t0 a0

and compile_bin env op l r =
  match op, r.node with
  (* string concat: evaluate both pointers, call the runtime helper *)
  | Ast.Concat, _ ->
    compile_expr env l; push a0;
    compile_expr env r;
    emit_word (enc_i 0 a0 0 a1 0x13);                    (* mv a1, a0 (right) *)
    pop a0;                                              (* a0 = left *)
    emit (Jal (ra, "__str_concat"))
  (* immediate fast paths: `x + k` / `x - k` for a small literal k (the hot
     `n - 1` / `n + 1` of recursion) fold into a single addi *)
  | Ast.Add, Ast.Int_lit n when is_small n ->
    compile_expr env l; emit_word (enc_i n a0 0 a0 0x13)            (* addi a0, a0, n *)
  | Ast.Sub, Ast.Int_lit n when is_small (- n) ->
    compile_expr env l; emit_word (enc_i (- n) a0 0 a0 0x13)        (* addi a0, a0, -n *)
  | _ ->
    (match op, l.node with
     | Ast.Add, Ast.Int_lit n when is_small n ->
       compile_expr env r; emit_word (enc_i n a0 0 a0 0x13)
     | _ -> with_operands env l r (fun rl rr -> emit_binop op a0 rl rr l.loc))

and compile_cmp env op l r =
  (* string comparison: compare content, not pointers *)
  if l.Ast.ty = Some Ast.TyStr then begin
    compile_expr env l; push a0;
    compile_expr env r; emit_word (enc_i 0 a0 0 a1 0x13); pop a0;   (* a0=l, a1=r *)
    (match op with
     | Ast.Eq -> emit (Jal (ra, "__str_eq"))
     | Ast.Ne -> emit (Jal (ra, "__str_eq")); emit_word (enc_i 1 a0 4 a0 0x13)   (* xori a0,1 *)
     | Ast.Lt -> emit (Jal (ra, "__str_cmp")); emit_word (enc_i 0 a0 2 a0 0x13)  (* slti a0,a0,0 *)
     | Ast.Le -> emit (Jal (ra, "__str_cmp")); emit_word (enc_i 1 a0 2 a0 0x13)  (* slti a0,a0,1 *)
     | Ast.Gt -> emit (Jal (ra, "__str_cmp")); emit_word (enc_r 0 a0 zero 2 a0 0x33) (* slt a0,x0,a0 *)
     | Ast.Ge -> emit (Jal (ra, "__str_cmp")); emit_word (enc_i 0 a0 2 a0 0x13);
                emit_word (enc_i 1 a0 4 a0 0x13))                                 (* !(d<0) *)
  end else
  (* `x < k` / `x <= k` with a small literal fold into slti *)
  match op, r.node with
  | Ast.Lt, Ast.Int_lit n when is_small n ->
    compile_expr env l; emit_word (enc_i n a0 2 a0 0x13)            (* slti a0, a0, n *)
  | Ast.Le, Ast.Int_lit n when is_small (n + 1) ->
    compile_expr env l; emit_word (enc_i (n + 1) a0 2 a0 0x13)      (* slti a0, a0, n+1 *)
  | _ ->
    with_operands env l r (fun rl rr ->
      match op with
      | Ast.Eq -> emit_word (enc_r 0x20 rr rl 0 a0 0x33);           (* sub  a0, rl, rr *)
                 emit_word (enc_i 1 a0 3 a0 0x13)                   (* sltiu a0, a0, 1 *)
      | Ast.Ne -> emit_word (enc_r 0x20 rr rl 0 a0 0x33);           (* sub  a0, rl, rr *)
                 emit_word (enc_r 0 a0 zero 3 a0 0x33)              (* sltu a0, x0, a0 *)
      | Ast.Lt -> emit_word (enc_r 0 rr rl 2 a0 0x33)               (* slt  a0, rl, rr *)
      | Ast.Gt -> emit_word (enc_r 0 rl rr 2 a0 0x33)               (* slt  a0, rr, rl *)
      | Ast.Le -> emit_word (enc_r 0 rl rr 2 a0 0x33);              (* slt  a0, rr, rl *)
                 emit_word (enc_i 1 a0 4 a0 0x13)                   (* xori a0, a0, 1 *)
      | Ast.Ge -> emit_word (enc_r 0 rr rl 2 a0 0x33);              (* slt  a0, rl, rr *)
                 emit_word (enc_i 1 a0 4 a0 0x13))                  (* xori a0, a0, 1 *)

and compile_logic env op l r =
  let l_end = fresh_label ".land" in
  (match op with
   | Ast.And ->
     let l_false = fresh_label ".lfalse" in
     compile_expr env l;
     emit (Branch (0, a0, zero, l_false));               (* beq a0,x0,false *)
     compile_expr env r;
     emit (Jal (zero, l_end));
     emit (Label l_false); li a0 0;
     emit (Label l_end)
   | Ast.Or ->
     let l_true = fresh_label ".ltrue" in
     compile_expr env l;
     emit (Branch (1, a0, zero, l_true));                (* bne a0,x0,true *)
     compile_expr env r;
     emit (Jal (zero, l_end));
     emit (Label l_true); li a0 1;
     emit (Label l_end))

and compile_app env e =
  let (head, args) = flatten_app e in
  match head.node with
  | Ast.Var "print_int" when List.length args = 1 ->
    compile_expr env (List.hd args);
    emit (Jal (ra, "__print_int"))
  | Ast.Var "print" when List.length args = 1 ->
    (* print_endline semantics: write the bytes, then a trailing newline *)
    compile_expr env (List.hd args);                     (* a0 = string ptr *)
    emit_word (enc_i 0 a0 2 a2 0x03);                    (* lw   a2, 0(a0)  — len *)
    emit_word (enc_i 4 a0 0 a1 0x13);                    (* addi a1, a0, 4  — bytes *)
    emit_word (enc_i 64 zero 0 a7 0x13);                 (* li   a7, 64 *)
    emit_word (enc_i 0 zero 0 zero 0x73);                (* ecall (write string) *)
    emit_word (enc_u 0x60 t0 0x37);                      (* lui  t0, 0x60  — scratch *)
    emit_word (enc_i 10 zero 0 t1 0x13);                 (* li   t1, '\n' *)
    emit_word (enc_s 0 t1 t0 0 0x23);                    (* sb   t1, 0(t0) *)
    emit_word (enc_i 0 t0 0 a1 0x13);                    (* mv   a1, t0 *)
    emit_word (enc_i 1 zero 0 a2 0x13);                  (* li   a2, 1 *)
    emit_word (enc_i 64 zero 0 a7 0x13);                 (* li   a7, 64 *)
    emit_word (enc_i 0 zero 0 zero 0x73)                 (* ecall (write '\n') *)
  | Ast.Var "str_len" when List.length args = 1 ->
    compile_expr env (List.hd args);
    emit_word (enc_i 0 a0 2 a0 0x03)                     (* lw a0, 0(a0) — length header *)
  | Ast.Var "print_no_nl" when List.length args = 1 ->
    compile_expr env (List.hd args);
    emit_word (enc_i 0 a0 2 a2 0x03);                    (* lw a2, 0(a0) — len *)
    emit_word (enc_i 4 a0 0 a1 0x13);                    (* addi a1, a0, 4 *)
    emit_word (enc_i 64 zero 0 a7 0x13);
    emit_word (enc_i 0 zero 0 zero 0x73)                 (* ecall *)
  | Ast.Var "str_of_int" when List.length args = 1 ->
    compile_expr env (List.hd args); emit (Jal (ra, "__str_of_int"))
  | Ast.Var "ord" when List.length args = 1 ->
    compile_expr env (List.hd args);
    emit_word (enc_i 4 a0 4 a0 0x03)                     (* lbu a0, 4(a0) — first byte *)
  | Ast.Var "chr" when List.length args = 1 ->
    compile_expr env (List.hd args);                     (* a0 = byte value *)
    emit_word (enc_i 0 a0 0 t2 0x13);                    (* mv t2, a0 *)
    alloc_words t0 2;
    li t1 1; emit_word (enc_s 0 t1 t0 2 0x23);           (* sw len=1 *)
    emit_word (enc_s 4 t2 t0 0 0x23);                    (* sb byte, 4(t0) *)
    emit_word (enc_i 0 t0 0 a0 0x13)                     (* mv a0, t0 *)
  | Ast.Var "char_at" when List.length args = 2 ->
    compile_expr env (List.nth args 0); push a0;
    compile_expr env (List.nth args 1);
    emit_word (enc_i 0 a0 0 a1 0x13); pop a0;            (* a0=s, a1=i *)
    emit_word (enc_r 0 a1 a0 0 t0 0x33);                 (* add t0, s, i *)
    emit_word (enc_i 4 t0 4 t0 0x03);                    (* lbu t0, 4(t0) *)
    alloc_words t1 2;
    li t2 1; emit_word (enc_s 0 t2 t1 2 0x23);           (* sw len=1 *)
    emit_word (enc_s 4 t0 t1 0 0x23);                    (* sb byte *)
    emit_word (enc_i 0 t1 0 a0 0x13)                     (* mv a0, t1 *)
  | Ast.Var "str_eq" when List.length args = 2 ->
    compile_expr env (List.nth args 0); push a0;
    compile_expr env (List.nth args 1);
    emit_word (enc_i 0 a0 0 a1 0x13); pop a0;
    emit (Jal (ra, "__str_eq"))
  | Ast.Var "str_compare" when List.length args = 2 ->
    compile_expr env (List.nth args 0); push a0;
    compile_expr env (List.nth args 1);
    emit_word (enc_i 0 a0 0 a1 0x13); pop a0;
    emit (Jal (ra, "__str_cmp"))
  | Ast.Var "substring" when List.length args = 3 ->
    compile_expr env (List.nth args 0); push a0;
    compile_expr env (List.nth args 1); push a0;
    compile_expr env (List.nth args 2);
    emit_word (enc_i 0 a0 0 a2 0x13);                    (* a2 = len *)
    pop a1; pop a0;                                      (* a1 = start, a0 = s *)
    emit (Jal (ra, "__substring"))
  | Ast.Var f when is_top f && not (List.mem_assoc f env)
                   && List.length args = List.length (fst (Hashtbl.find tops f)) ->
    (* fast path: a saturated direct call to a known top-level function.
       Args go in a0.., a plain jal — the register-allocated calling
       convention. Everything else goes through closures below. *)
    let arity = List.length args in
    if arity > 8 then err e.loc "RV32I: functions with more than 8 args are not supported yet";
    List.iter (fun arg -> compile_expr env arg; push a0) args;
    for i = arity - 1 downto 0 do pop (a0 + i) done;
    emit (Jal (ra, "u_" ^ f))
  | _ ->
    (* general path: evaluate the head to a closure value and apply the
       arguments one at a time via indirect (curried) calls *)
    compile_expr env head;                               (* a0 = closure *)
    List.iter (fun arg ->
      push a0;                                           (* save the closure *)
      compile_expr env arg;                              (* a0 = arg *)
      emit_word (enc_i 0 a0 0 a1 0x13);                  (* mv a1, a0 (arg) *)
      pop a0;                                            (* a0 = closure (its own env) *)
      emit_word (enc_i 0 a0 2 t1 0x03);                  (* lw t1, 0(a0) — code ptr *)
      emit_word (enc_i 0 t1 0 ra 0x67)                   (* jalr ra, t1 — call; result in a0 *)
    ) args

and compile_match env scrut arms =
  compile_expr env scrut;                          (* a0 = scrutinee *)
  let sidx = !slot_ctr in incr slot_ctr;
  store_a0_to sidx;                                (* stash it (survives arm bodies) *)
  let l_end = fresh_label ".mend" in
  List.iter (fun (pat, guard, body) ->
    let l_next = fresh_label ".marm" in
    load_to_a0 sidx;                               (* reload scrutinee into a0 *)
    let env' = compile_pattern_bind env pat l_next in
    (match guard with
     | Some g -> compile_expr env' g; emit (Branch (0, a0, zero, l_next))  (* beqz a0 -> next *)
     | None -> ());
    compile_expr env' body;
    emit (Jal (zero, l_end));
    emit (Label l_next)
  ) arms;
  emit (Label l_end)   (* typer guarantees exhaustiveness, so some arm matched *)

(* Test the pattern against the value in a0; branch to l_fail on mismatch,
   bind its variables on match, and return the extended env. Supports the
   top level plus one level of sub-structure (enough for Option/Result and
   typical enums); deeper nesting raises Codegen_error. *)
and compile_pattern_bind env pat l_fail =
  match pat.Ast.pnode with
  | Ast.P_wild | Ast.P_unit -> env
  | Ast.P_var name ->
    let idx = !slot_ctr in incr slot_ctr; store_a0_to idx; (name, idx) :: env
  | Ast.P_int n -> li t0 n; emit (Branch (1, a0, t0, l_fail)); env
  | Ast.P_bool b -> li t0 (if b then 1 else 0); emit (Branch (1, a0, t0, l_fail)); env
  | Ast.P_tuple pats -> bind_tuple_fields env pats
  | Ast.P_constr (name, sub) ->
    let tag = tag_of pat.Ast.ploc name in
    emit_word (enc_i 0 a0 2 t0 0x03);              (* lw t0, 0(a0) — tag *)
    li t1 tag; emit (Branch (1, t0, t1, l_fail));  (* bne t0, t1, fail *)
    (match sub with
     | None -> env
     | Some subp ->
       emit_word (enc_i 4 a0 2 a0 0x03);           (* lw a0, 4(a0) — payload *)
       (match subp.Ast.pnode with
        | Ast.P_wild | Ast.P_unit -> env
        | Ast.P_var name -> let idx = !slot_ctr in incr slot_ctr; store_a0_to idx; (name, idx) :: env
        | Ast.P_tuple pats -> bind_tuple_fields env pats
        | Ast.P_int n -> li t0 n; emit (Branch (1, a0, t0, l_fail)); env
        | Ast.P_bool b -> li t0 (if b then 1 else 0); emit (Branch (1, a0, t0, l_fail)); env
        | _ -> err subp.Ast.ploc "RV32I: this nested constructor payload pattern is not supported yet"))
  | _ -> err pat.Ast.ploc "RV32I: this match pattern is not supported yet"

(* a0 = tuple pointer; bind each P_var field (tuple patterns are irrefutable) *)
and bind_tuple_fields env pats =
  emit_word (enc_i 0 a0 0 t1 0x13);                (* mv t1, a0 — tuple ptr *)
  let env = ref env in
  List.iteri (fun i p ->
    match p.Ast.pnode with
    | Ast.P_wild -> ()
    | Ast.P_var name ->
      emit_word (enc_i (i * 4) t1 2 a0 0x03);      (* lw a0, i*4(t1) *)
      let idx = !slot_ctr in incr slot_ctr; store_a0_to idx; env := (name, idx) :: !env
    | _ -> err p.Ast.ploc "RV32I: nested tuple patterns are not supported yet"
  ) pats;
  !env

(* --- function + runtime emission ----------------------------------------- *)

(* Emit the prologue for a function with `total` named bindings, sets
   cur_nsaved/cur_noverflow, and returns the frame parameters for the
   matching epilogue. Incoming argument registers (a0..) are untouched. *)
let emit_prologue total =
  let nsaved = min total nregs in
  let noverflow = total - nsaved in
  cur_nsaved := nsaved;
  cur_noverflow := noverflow;
  let sreg_base = noverflow in           (* [overflow][saved s-regs][fp][ra] *)
  let fp_slot = noverflow + nsaved in
  let ra_slot = fp_slot + 1 in
  let fsz = (ra_slot + 1) * 4 in
  emit_word (enc_i (-fsz) sp 0 sp 0x13);                (* addi sp, sp, -fsz *)
  emit_word (enc_s (ra_slot * 4) ra sp 2 0x23);         (* sw   ra, ra_slot(sp) *)
  emit_word (enc_s (fp_slot * 4) fp sp 2 0x23);         (* sw   fp, fp_slot(sp) *)
  for k = 0 to nsaved - 1 do
    emit_word (enc_s ((sreg_base + k) * 4) sregs.(k) sp 2 0x23)
  done;
  emit_word (enc_i 0 sp 0 fp 0x13);                     (* addi fp, sp, 0 *)
  (nsaved, sreg_base, fp_slot, ra_slot, fsz)

let emit_epilogue (nsaved, sreg_base, fp_slot, ra_slot, fsz) =
  (* result already in a0, which the teardown never touches *)
  for k = 0 to nsaved - 1 do
    emit_word (enc_i ((sreg_base + k) * 4) fp 2 sregs.(k) 0x03)
  done;
  emit_word (enc_i (ra_slot * 4) fp 2 ra 0x03);         (* lw   ra, ra_slot(fp) *)
  emit_word (enc_i (fp_slot * 4) fp 2 t0 0x03);         (* lw   t0, fp_slot(fp) — old fp *)
  emit_word (enc_i fsz fp 0 sp 0x13);                   (* addi sp, fp, fsz *)
  emit_word (enc_i 0 t0 0 fp 0x13);                     (* addi fp, t0, 0 *)
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* jalr x0, ra, 0 (ret) *)

(* a top-level function: args arrive in a0.. (direct convention) *)
let emit_function ~label ~params ~body =
  let nparams = List.length params in
  let total = nparams + count_lets body in
  emit (Label label);
  let fr = emit_prologue total in
  List.iteri (fun i _ ->
    match loc_of i with
    | Reg r -> emit_word (enc_i 0 (a0 + i) 0 r 0x13)               (* mv sX, aI *)
    | Mem slot -> emit_word (enc_s (slot_off slot) (a0 + i) fp 2 0x23)
  ) params;
  slot_ctr := nparams;
  compile_expr (List.mapi (fun i p -> (p, i)) params) body;
  emit_epilogue fr

(* a lifted lambda: closure env ptr in a0, the (single) argument in a1.
   Bindings are captures (indices 0..k-1) then the param (index k). *)
let emit_lambda ~label ~captures ~param ~body =
  let k = List.length captures in
  let total = k + 1 + count_lets body in
  emit (Label label);
  let fr = emit_prologue total in
  (* load captured values from the closure env (a0), env[i+1] -> binding i *)
  List.iteri (fun i _ ->
    emit_word (enc_i ((i + 1) * 4) a0 2 t0 0x03);                  (* lw t0, (i+1)*4(a0) *)
    match loc_of i with
    | Reg r -> emit_word (enc_i 0 t0 0 r 0x13)                     (* mv sX, t0 *)
    | Mem slot -> emit_word (enc_s (slot_off slot) t0 fp 2 0x23)
  ) captures;
  (* the argument (a1) -> the param binding (index k) *)
  (match loc_of k with
   | Reg r -> emit_word (enc_i 0 a1 0 r 0x13)                      (* mv sX, a1 *)
   | Mem slot -> emit_word (enc_s (slot_off slot) a1 fp 2 0x23));
  slot_ctr := k + 1;
  let env = List.mapi (fun i c -> (c, i)) captures @ [(param, k)] in
  compile_expr env body;
  emit_epilogue fr

(* _start MUST be the first bytes (loaded at address 0, PC starts there) *)
let emit_start () =
  emit (Label "_start");
  emit_word (enc_u 0x70 sp 0x37);                       (* lui  sp, 0x70  (sp = 0x70000) *)
  emit_word (enc_i 0 sp 0 fp 0x13);                     (* addi fp, sp, 0 *)
  emit_word (enc_u 0x10 gp 0x37);                       (* lui  gp, 0x10  (heap top = 0x10000) *)
  emit (Jal (ra, "__main"));                            (* run main *)
  li a7 93;                                             (* exit syscall *)
  li a0 0;
  emit_word (enc_i 0 zero 0 zero 0x73);                 (* ecall *)
  emit (Label "__hang");
  emit (Jal (zero, "__hang"))                           (* safety: spin if it ever returns *)

(* print_int: itoa(a0) + '\n' -> ecall write. A leaf; clobbers t*/a* only.
   Scratch decimal buffer lives at 0x60000 (below sp, above the program). *)
let emit_print_int () =
  emit (Label "__print_int");
  emit_word (enc_i 0 a0 0 t4 0x13);                     (* addi t4, a0, 0  — t4 = value *)
  emit_word (enc_i 0 zero 0 t3 0x13);                   (* addi t3, x0, 0  — neg flag *)
  emit (Branch (5, t4, zero, ".pi_pos"));               (* bge t4, x0, pos *)
  emit_word (enc_r 0x20 t4 zero 0 t4 0x33);             (* sub t4, x0, t4  — negate *)
  emit_word (enc_i 1 zero 0 t3 0x13);                   (* addi t3, x0, 1 *)
  emit (Label ".pi_pos");
  emit_word (enc_u 0x60 t1 0x37);                       (* lui t1, 0x60    — BUF *)
  emit_word (enc_i 63 t1 0 t2 0x13);                    (* addi t2, t1, 63 — END cursor *)
  emit_word (enc_i 10 zero 0 t5 0x13);                  (* addi t5, x0, 10 — '\n' *)
  emit_word (enc_s 0 t5 t2 0 0x23);                     (* sb  t5, 0(t2)   — store newline *)
  emit_word (enc_i (-1) t2 0 t2 0x13);                  (* addi t2, t2, -1 *)
  emit_word (enc_i 10 zero 0 t6 0x13);                  (* addi t6, x0, 10 — divisor *)
  emit (Label ".pi_loop");
  emit_word (enc_r 1 t6 t4 6 t5 0x33);                  (* rem  t5, t4, t6 *)
  emit_word (enc_r 1 t6 t4 4 t4 0x33);                  (* div  t4, t4, t6 *)
  emit_word (enc_i 48 t5 0 t5 0x13);                    (* addi t5, t5, '0' *)
  emit_word (enc_s 0 t5 t2 0 0x23);                     (* sb   t5, 0(t2) *)
  emit_word (enc_i (-1) t2 0 t2 0x13);                  (* addi t2, t2, -1 *)
  emit (Branch (1, t4, zero, ".pi_loop"));              (* bne t4, x0, loop *)
  emit (Branch (0, t3, zero, ".pi_nosign"));            (* beq t3, x0, nosign *)
  emit_word (enc_i 45 zero 0 t5 0x13);                  (* addi t5, x0, '-' *)
  emit_word (enc_s 0 t5 t2 0 0x23);                     (* sb   t5, 0(t2) *)
  emit_word (enc_i (-1) t2 0 t2 0x13);                  (* addi t2, t2, -1 *)
  emit (Label ".pi_nosign");
  emit_word (enc_i 1 t2 0 a1 0x13);                     (* addi a1, t2, 1  — buf start *)
  emit_word (enc_u 0x60 t0 0x37);                       (* lui t0, 0x60 *)
  emit_word (enc_i 63 t0 0 t0 0x13);                    (* addi t0, t0, 63 — END *)
  emit_word (enc_r 0x20 t2 t0 0 a2 0x33);               (* sub a2, t0, t2  — len = END - cursor *)
  emit_word (enc_i 64 zero 0 a7 0x13);                  (* addi a7, x0, 64 — write syscall *)
  emit_word (enc_i 0 zero 0 zero 0x73);                 (* ecall *)
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* jalr x0, ra, 0 (ret) *)

(* __str_concat(a0=left, a1=right) -> a0 = new [len][bytes] block. A leaf;
   allocates via gp and byte-copies both operands' payloads. *)
let emit_str_concat () =
  emit (Label "__str_concat");
  emit_word (enc_i 0 a0 2 t0 0x03);                     (* lw t0, 0(a0)  — len1 *)
  emit_word (enc_i 0 a1 2 t1 0x03);                     (* lw t1, 0(a1)  — len2 *)
  emit_word (enc_r 0 t1 t0 0 t2 0x33);                  (* add t2, t0, t1 — total *)
  emit_word (enc_i 0 gp 0 t3 0x13);                     (* mv t3, gp     — result ptr *)
  emit_word (enc_s 0 t2 t3 2 0x23);                     (* sw t2, 0(t3)  — store total len *)
  emit_word (enc_i 3 t2 0 t4 0x13);                     (* addi t4, t2, 3 *)
  emit_word (enc_i (-4) t4 7 t4 0x13);                  (* andi t4, t4, -4 — round4(total) *)
  emit_word (enc_i 4 t4 0 t4 0x13);                     (* addi t4, t4, 4  — + len word *)
  emit_word (enc_r 0 t4 t3 0 gp 0x33);                  (* add gp, t3, t4  — new heap top *)
  emit_word (enc_i 4 a0 0 t5 0x13);                     (* addi t5, a0, 4  — src1 *)
  emit_word (enc_i 4 t3 0 t6 0x13);                     (* addi t6, t3, 4  — dst *)
  emit (Label ".sc_l1");
  emit (Branch (0, t0, zero, ".sc_d1"));                (* beq t0, x0, d1 *)
  emit_word (enc_i 0 t5 0 a2 0x03);                     (* lb a2, 0(t5) *)
  emit_word (enc_s 0 a2 t6 0 0x23);                     (* sb a2, 0(t6) *)
  emit_word (enc_i 1 t5 0 t5 0x13);                     (* addi t5, t5, 1 *)
  emit_word (enc_i 1 t6 0 t6 0x13);                     (* addi t6, t6, 1 *)
  emit_word (enc_i (-1) t0 0 t0 0x13);                  (* addi t0, t0, -1 *)
  emit (Jal (zero, ".sc_l1"));
  emit (Label ".sc_d1");
  emit_word (enc_i 4 a1 0 t5 0x13);                     (* addi t5, a1, 4  — src2 *)
  emit (Label ".sc_l2");
  emit (Branch (0, t1, zero, ".sc_d2"));                (* beq t1, x0, d2 *)
  emit_word (enc_i 0 t5 0 a2 0x03);                     (* lb a2, 0(t5) *)
  emit_word (enc_s 0 a2 t6 0 0x23);                     (* sb a2, 0(t6) *)
  emit_word (enc_i 1 t5 0 t5 0x13);                     (* addi t5, t5, 1 *)
  emit_word (enc_i 1 t6 0 t6 0x13);                     (* addi t6, t6, 1 *)
  emit_word (enc_i (-1) t1 0 t1 0x13);                  (* addi t1, t1, -1 *)
  emit (Jal (zero, ".sc_l2"));
  emit (Label ".sc_d2");
  emit_word (enc_i 0 t3 0 a0 0x13);                     (* mv a0, t3 *)
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* ret *)

(* __str_eq(a0=s1, a1=s2) -> a0 = 1 if byte-equal else 0. Leaf. *)
let emit_str_eq () =
  emit (Label "__str_eq");
  emit_word (enc_i 0 a0 2 t0 0x03);                     (* lw t0, 0(a0) — len1 *)
  emit_word (enc_i 0 a1 2 t1 0x03);                     (* lw t1, 0(a1) — len2 *)
  emit (Branch (1, t0, t1, ".se_ne"));                  (* bne t0, t1, ne *)
  emit_word (enc_i 4 a0 0 t2 0x13);                     (* addi t2, a0, 4 *)
  emit_word (enc_i 4 a1 0 t3 0x13);                     (* addi t3, a1, 4 *)
  emit (Label ".se_loop");
  emit (Branch (0, t0, zero, ".se_eq"));                (* beq t0, x0, eq *)
  emit_word (enc_i 0 t2 0 t4 0x03);                     (* lb t4, 0(t2) *)
  emit_word (enc_i 0 t3 0 t5 0x03);                     (* lb t5, 0(t3) *)
  emit (Branch (1, t4, t5, ".se_ne"));                  (* bne t4, t5, ne *)
  emit_word (enc_i 1 t2 0 t2 0x13);
  emit_word (enc_i 1 t3 0 t3 0x13);
  emit_word (enc_i (-1) t0 0 t0 0x13);
  emit (Jal (zero, ".se_loop"));
  emit (Label ".se_eq"); li a0 1; emit_word (enc_i 0 ra 0 zero 0x67);
  emit (Label ".se_ne"); li a0 0; emit_word (enc_i 0 ra 0 zero 0x67)

(* __str_cmp(a0=s1, a1=s2) -> a0 = <0 / 0 / >0 lexicographically. Leaf. *)
let emit_str_cmp () =
  emit (Label "__str_cmp");
  emit_word (enc_i 0 a0 2 t0 0x03);                     (* lw t0, 0(a0) — len1 *)
  emit_word (enc_i 0 a1 2 t1 0x03);                     (* lw t1, 0(a1) — len2 *)
  emit_word (enc_i 0 t0 0 t2 0x13);                     (* mv t2, t0  — min = len1 *)
  emit (Branch (5, t2, t1, ".cm_min"));                 (* bge t2, t1 -> min already t1? no *)
  emit (Jal (zero, ".cm_have"));                        (* t2 (=len1) < len1? fallthrough handling *)
  emit (Label ".cm_min");
  emit_word (enc_i 0 t1 0 t2 0x13);                     (* mv t2, t1  — min = len2 (len1>=len2) *)
  emit (Label ".cm_have");
  emit_word (enc_i 4 a0 0 t3 0x13);                     (* addi t3, a0, 4 *)
  emit_word (enc_i 4 a1 0 t4 0x13);                     (* addi t4, a1, 4 *)
  emit (Label ".cm_loop");
  emit (Branch (0, t2, zero, ".cm_len"));               (* beq t2, x0 -> compare lengths *)
  emit_word (enc_i 0 t3 4 t5 0x03);                     (* lbu t5, 0(t3) *)
  emit_word (enc_i 0 t4 4 t6 0x03);                     (* lbu t6, 0(t4) *)
  emit_word (enc_r 0x20 t6 t5 0 a0 0x33);               (* sub a0, t5, t6 *)
  emit (Branch (1, a0, zero, ".cm_done"));              (* bne a0, x0, done *)
  emit_word (enc_i 1 t3 0 t3 0x13);
  emit_word (enc_i 1 t4 0 t4 0x13);
  emit_word (enc_i (-1) t2 0 t2 0x13);
  emit (Jal (zero, ".cm_loop"));
  emit (Label ".cm_len");
  emit_word (enc_r 0x20 t1 t0 0 a0 0x33);               (* sub a0, len1, len2 *)
  emit (Label ".cm_done");
  (* normalize to -1 / 0 / 1 (matches the interpreter's str_compare) *)
  emit (Branch (0, a0, zero, ".cm_ret"));               (* beq a0, x0 -> 0 *)
  emit (Branch (4, a0, zero, ".cm_neg"));               (* blt a0, x0 -> -1 *)
  li a0 1; emit (Jal (zero, ".cm_ret"));
  emit (Label ".cm_neg"); li a0 (-1);
  emit (Label ".cm_ret");
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* ret *)

(* __str_of_int(a0=n) -> a0 = heap [len][decimal bytes]. Leaf; uses the
   0x60000 scratch to build digits, then copies into a fresh heap block. *)
let emit_str_of_int () =
  emit (Label "__str_of_int");
  emit_word (enc_i 0 a0 0 t4 0x13);                     (* mv t4, a0 — value *)
  emit_word (enc_i 0 zero 0 t3 0x13);                   (* neg flag = 0 *)
  emit (Branch (5, t4, zero, ".si_pos"));               (* bge t4, x0 *)
  emit_word (enc_r 0x20 t4 zero 0 t4 0x33);             (* neg *)
  emit_word (enc_i 1 zero 0 t3 0x13);
  emit (Label ".si_pos");
  emit_word (enc_u 0x60 t1 0x37);                       (* lui t1, 0x60 *)
  emit_word (enc_i 63 t1 0 t2 0x13);                    (* addi t2, t1, 63 — cursor *)
  emit_word (enc_i 10 zero 0 t6 0x13);                  (* divisor 10 *)
  emit (Label ".si_loop");
  emit_word (enc_r 1 t6 t4 6 t5 0x33);                  (* rem t5, t4, 10 *)
  emit_word (enc_r 1 t6 t4 4 t4 0x33);                  (* div t4, t4, 10 *)
  emit_word (enc_i 48 t5 0 t5 0x13);                    (* + '0' *)
  emit_word (enc_s 0 t5 t2 0 0x23);                     (* sb t5, 0(t2) *)
  emit_word (enc_i (-1) t2 0 t2 0x13);
  emit (Branch (1, t4, zero, ".si_loop"));              (* bne t4, x0 *)
  emit (Branch (0, t3, zero, ".si_nosign"));            (* beq t3, x0 *)
  emit_word (enc_i 45 zero 0 t5 0x13);                  (* '-' *)
  emit_word (enc_s 0 t5 t2 0 0x23);
  emit_word (enc_i (-1) t2 0 t2 0x13);
  emit (Label ".si_nosign");
  emit_word (enc_i 1 t2 0 t0 0x13);                     (* t0 = start = cursor+1 *)
  emit_word (enc_u 0x60 t1 0x37);                       (* t1 = 0x60000 *)
  emit_word (enc_i 63 t1 0 t1 0x13);                    (* t1 = END = 0x6003F *)
  emit_word (enc_r 0x20 t2 t1 0 t1 0x33);               (* t1 = END - cursor = len *)
  emit_word (enc_i 0 gp 0 t3 0x13);                     (* t3 = result = gp *)
  emit_word (enc_s 0 t1 t3 2 0x23);                     (* sw len, 0(t3) *)
  emit_word (enc_i 3 t1 0 t4 0x13);                     (* round4(len)+4 *)
  emit_word (enc_i (-4) t4 7 t4 0x13);
  emit_word (enc_i 4 t4 0 t4 0x13);
  emit_word (enc_r 0 t4 t3 0 gp 0x33);                  (* gp = t3 + words *)
  emit_word (enc_i 4 t3 0 t5 0x13);                     (* dst = t3+4 *)
  emit (Label ".si_copy");
  emit (Branch (0, t1, zero, ".si_cdone"));             (* beq t1, x0 *)
  emit_word (enc_i 0 t0 0 t6 0x03);                     (* lb t6, 0(t0) *)
  emit_word (enc_s 0 t6 t5 0 0x23);                     (* sb t6, 0(t5) *)
  emit_word (enc_i 1 t0 0 t0 0x13);
  emit_word (enc_i 1 t5 0 t5 0x13);
  emit_word (enc_i (-1) t1 0 t1 0x13);
  emit (Jal (zero, ".si_copy"));
  emit (Label ".si_cdone");
  emit_word (enc_i 0 t3 0 a0 0x13);                     (* mv a0, t3 *)
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* ret *)

(* __substring(a0=s, a1=start, a2=end) -> a0 = heap [len][bytes], len=end-start.
   Matches the interpreter's substring(s, start, end) (end exclusive). Leaf. *)
let emit_substring () =
  emit (Label "__substring");
  emit_word (enc_r 0x20 a1 a2 0 a2 0x33);               (* sub a2, a2, a1 — len = end - start *)
  emit_word (enc_i 0 gp 0 t0 0x13);                     (* t0 = result = gp *)
  emit_word (enc_s 0 a2 t0 2 0x23);                     (* sw len, 0(t0) *)
  emit_word (enc_i 3 a2 0 t1 0x13);                     (* round4(len)+4 *)
  emit_word (enc_i (-4) t1 7 t1 0x13);
  emit_word (enc_i 4 t1 0 t1 0x13);
  emit_word (enc_r 0 t1 t0 0 gp 0x33);                  (* gp = t0 + words *)
  emit_word (enc_r 0 a1 a0 0 t2 0x33);                  (* t2 = s + start *)
  emit_word (enc_i 4 t2 0 t2 0x13);                     (* src = s+4+start *)
  emit_word (enc_i 4 t0 0 t3 0x13);                     (* dst = t0+4 *)
  emit_word (enc_i 0 a2 0 t4 0x13);                     (* t4 = count *)
  emit (Label ".ss_loop");
  emit (Branch (0, t4, zero, ".ss_done"));
  emit_word (enc_i 0 t2 0 t5 0x03);                     (* lb t5, 0(t2) *)
  emit_word (enc_s 0 t5 t3 0 0x23);                     (* sb t5, 0(t3) *)
  emit_word (enc_i 1 t2 0 t2 0x13);
  emit_word (enc_i 1 t3 0 t3 0x13);
  emit_word (enc_i (-1) t4 0 t4 0x13);
  emit (Jal (zero, ".ss_loop"));
  emit (Label ".ss_done");
  emit_word (enc_i 0 t0 0 a0 0x13);                     (* mv a0, t0 *)
  emit_word (enc_i 0 ra 0 zero 0x67)                    (* ret *)

(* --- two-pass assembly: assign addresses, then encode ------------------- *)
let assemble (prog : item list) : string =
  (* pass 1: label -> byte address *)
  let labels : (string, int) Hashtbl.t = Hashtbl.create 64 in
  let addr = ref 0 in
  List.iter (fun it ->
    match it with
    | Label name -> Hashtbl.replace labels name !addr
    | Word _ | Jal _ | Branch _ -> addr := !addr + 4
    | LoadAddr _ -> addr := !addr + 8
    | Bytes b -> addr := !addr + String.length b
  ) prog;
  let target name here =
    match Hashtbl.find_opt labels name with
    | Some a -> a - here
    | None -> failwith ("codegen_riscv: undefined label " ^ name)
  in
  let abs name =
    match Hashtbl.find_opt labels name with
    | Some a -> a
    | None -> failwith ("codegen_riscv: undefined label " ^ name)
  in
  (* pass 2: encode *)
  let buf = Buffer.create (!addr) in
  let put_word w =
    Buffer.add_char buf (Char.chr (w land 0xFF));
    Buffer.add_char buf (Char.chr ((w lsr 8) land 0xFF));
    Buffer.add_char buf (Char.chr ((w lsr 16) land 0xFF));
    Buffer.add_char buf (Char.chr ((w lsr 24) land 0xFF))
  in
  let here = ref 0 in
  List.iter (fun it ->
    match it with
    | Label _ -> ()
    | Word w -> put_word (w land 0xFFFFFFFF); here := !here + 4
    | Jal (rd, name) -> put_word (enc_j (target name !here) rd 0x6F); here := !here + 4
    | Branch (f3, rs1, rs2, name) ->
      put_word (enc_b (target name !here) rs2 rs1 f3 0x63); here := !here + 4
    | LoadAddr (rd, name) ->
      let a = abs name in
      let hi = (a + 0x800) asr 12 in
      let lo = a - (hi lsl 12) in
      put_word (enc_u (hi land 0xFFFFF) rd 0x37);        (* lui  rd, hi *)
      put_word (enc_i lo rd 0 rd 0x13);                  (* addi rd, rd, lo *)
      here := !here + 8
    | Bytes b -> Buffer.add_string buf b; here := !here + String.length b
  ) prog;
  Buffer.contents buf

(* --- assembly listing: a human-readable view of the emitted code --------- *)
let listing (prog : item list) : string =
  let labels : (string, int) Hashtbl.t = Hashtbl.create 64 in
  let addr = ref 0 in
  List.iter (fun it -> match it with
    | Label name -> Hashtbl.replace labels name !addr
    | Word _ | Jal _ | Branch _ -> addr := !addr + 4
    | LoadAddr _ -> addr := !addr + 8
    | Bytes b -> addr := !addr + String.length b) prog;
  let buf = Buffer.create 4096 in
  let here = ref 0 in
  List.iter (fun it ->
    match it with
    | Label name -> Buffer.add_string buf (Printf.sprintf "%s:\n" name)
    | Word w ->
      Buffer.add_string buf
        (Printf.sprintf "  %6x:  %08x  %s\n" !here w (Riscv_disasm.disasm_word ~pc:!here w));
      here := !here + 4
    | Jal (rd, name) ->
      let off = (try Hashtbl.find labels name with Not_found -> !here) - !here in
      let w = enc_j off rd 0x6F in
      let mn = if rd = 0 then Printf.sprintf "j %s" name
               else Printf.sprintf "jal %s, %s" (Riscv_disasm.r rd) name in
      Buffer.add_string buf (Printf.sprintf "  %6x:  %08x  %s\n" !here w mn);
      here := !here + 4
    | Branch (f3, rs1, rs2, name) ->
      let off = (try Hashtbl.find labels name with Not_found -> !here) - !here in
      let w = enc_b off rs2 rs1 f3 0x63 in
      let m = [| "beq"; "bne"; "?"; "?"; "blt"; "bge"; "bltu"; "bgeu" |].(f3) in
      let mn =
        if rs2 = 0 && f3 = 0 then Printf.sprintf "beqz %s, %s" (Riscv_disasm.r rs1) name
        else if rs2 = 0 && f3 = 1 then Printf.sprintf "bnez %s, %s" (Riscv_disasm.r rs1) name
        else Printf.sprintf "%s %s, %s, %s" m (Riscv_disasm.r rs1) (Riscv_disasm.r rs2) name in
      Buffer.add_string buf (Printf.sprintf "  %6x:  %08x  %s\n" !here w mn);
      here := !here + 4
    | LoadAddr (rd, name) ->
      Buffer.add_string buf (Printf.sprintf "  %6x:  (la)      la %s, %s\n" !here (Riscv_disasm.r rd) name);
      here := !here + 8
    | Bytes b ->
      Buffer.add_string buf (Printf.sprintf "  %6x:  .bytes %d\n" !here (String.length b));
      here := !here + String.length b
  ) prog;
  Buffer.contents buf

(* --- entry point --------------------------------------------------------- *)

(* build the symbolic item list for a program (shared by emit_program /
   emit_listing) *)
let build_items (prog : Ast.program) : item list =
  items := [];
  lbl_counter := 0;
  string_data := [];
  lambdas := [];
  Hashtbl.reset tops;
  Hashtbl.reset variant_tags;
  (* record constructor tags (index within each type) from Top_type decls *)
  List.iter (fun decl ->
    match decl with
    | Ast.Top_type (_, _, variants) ->
      List.iteri (fun i (cname, _) -> Hashtbl.replace variant_tags cname i) variants
    | _ -> ()
  ) prog.Ast.decls;
  let full = Ast.desugar_program prog in
  let main_body = split_tops full in
  (* reachability: which top-level fns does the program actually use? *)
  let reachable : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let rec visit name =
    if not (Hashtbl.mem reachable name) then begin
      Hashtbl.replace reachable name ();
      match Hashtbl.find_opt tops name with
      | Some (_, body) -> List.iter visit (vars_in body [])
      | None -> ()
    end
  in
  List.iter visit (vars_in main_body []);
  (* layout: _start, runtime, main, reachable fns, then string rodata *)
  emit_start ();
  emit_print_int ();
  emit_str_concat ();
  emit_str_eq ();
  emit_str_cmp ();
  emit_str_of_int ();
  emit_substring ();
  emit_function ~label:"__main" ~params:[] ~body:main_body;
  Hashtbl.iter (fun name (params, body) ->
    if Hashtbl.mem reachable name then
      emit_function ~label:("u_" ^ name) ~params ~body
  ) tops;
  (* drain the lambda worklist — emitting a lambda may enqueue more *)
  let rec drain () =
    match !lambdas with
    | [] -> ()
    | (label, captures, param, body) :: rest ->
      lambdas := rest;
      emit_lambda ~label ~captures ~param ~body;
      drain ()
  in
  drain ();
  (* string literals collected during compilation, placed after the code *)
  List.iter (fun (label, bytes) -> emit (Label label); emit (Bytes bytes)) !string_data;
  List.rev !items

let emit_program ~main_ty (prog : Ast.program) : string =
  ignore main_ty;
  assemble (build_items prog)

let emit_listing ~main_ty (prog : Ast.program) : string =
  ignore main_ty;
  listing (build_items prog)
