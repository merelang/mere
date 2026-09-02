(* riscv_disasm.ml — an RV32IM disassembler: one 32-bit word -> a readable
   mnemonic. The decode mirrors the emulator's imm_* decoders (and the
   inverse of codegen_riscv's enc_* encoders). Used by `mere -rvs` (assembly
   listing of the compiler's own output) and `mere -rvd` (disassemble a flat
   binary). Common pseudo-instructions (mv / li / ret / j / nop) are
   recognised so the listing reads the way a human wrote it. *)

let regs = [|
  "zero"; "ra"; "sp"; "gp"; "tp"; "t0"; "t1"; "t2";
  "fp";   "s1"; "a0"; "a1"; "a2"; "a3"; "a4"; "a5";
  "a6";   "a7"; "s2"; "s3"; "s4"; "s5"; "s6"; "s7";
  "s8";   "s9"; "s10"; "s11"; "t3"; "t4"; "t5"; "t6" |]

let r n = regs.(n land 31)

let sext v bits =
  let v = v land ((1 lsl bits) - 1) in
  if v land (1 lsl (bits - 1)) <> 0 then v - (1 lsl bits) else v

let imm_i inst = sext ((inst lsr 20) land 0xFFF) 12
let imm_s inst = sext ((((inst lsr 25) land 0x7F) lsl 5) lor ((inst lsr 7) land 0x1F)) 12
let imm_b inst =
  let b12 = (inst lsr 31) land 1 in
  let b11 = (inst lsr 7) land 1 in
  let b10_5 = (inst lsr 25) land 0x3F in
  let b4_1 = (inst lsr 8) land 0xF in
  sext ((b12 lsl 12) lor (b11 lsl 11) lor (b10_5 lsl 5) lor (b4_1 lsl 1)) 13
let imm_u inst = inst land 0xFFFFF000
let imm_j inst =
  let b20 = (inst lsr 31) land 1 in
  let b19_12 = (inst lsr 12) land 0xFF in
  let b11 = (inst lsr 20) land 1 in
  let b10_1 = (inst lsr 21) land 0x3FF in
  sext ((b20 lsl 20) lor (b19_12 lsl 12) lor (b11 lsl 11) lor (b10_1 lsl 1)) 21

let sp = Printf.sprintf

(* decode one instruction; pc is its byte address (for branch/jump targets) *)
let disasm_word ~pc (inst : int) : string =
  let inst = inst land 0xFFFFFFFF in
  if inst = 0x13 then "nop" else
  if inst = 0 then ".word 0x00000000" else
  let op = inst land 0x7F in
  let rd = (inst lsr 7) land 0x1F in
  let f3 = (inst lsr 12) land 7 in
  let rs1 = (inst lsr 15) land 0x1F in
  let rs2 = (inst lsr 20) land 0x1F in
  let f7 = (inst lsr 25) land 0x7F in
  match op with
  | 0x37 -> sp "lui %s, 0x%x" (r rd) ((imm_u inst) lsr 12)
  | 0x17 -> sp "auipc %s, 0x%x" (r rd) ((imm_u inst) lsr 12)
  | 0x6F ->
    let t = pc + imm_j inst in
    if rd = 0 then sp "j 0x%x" t else sp "jal %s, 0x%x" (r rd) t
  | 0x67 ->
    let i = imm_i inst in
    if rd = 0 && rs1 = 1 && i = 0 then "ret"
    else sp "jalr %s, %d(%s)" (r rd) i (r rs1)
  | 0x63 ->
    let t = pc + imm_b inst in
    let m = [| "beq"; "bne"; "?"; "?"; "blt"; "bge"; "bltu"; "bgeu" |].(f3) in
    (* beqz / bnez pseudo when comparing against zero *)
    if rs2 = 0 && f3 = 0 then sp "beqz %s, 0x%x" (r rs1) t
    else if rs2 = 0 && f3 = 1 then sp "bnez %s, 0x%x" (r rs1) t
    else sp "%s %s, %s, 0x%x" m (r rs1) (r rs2) t
  | 0x03 ->
    (* f3=3 and f3=6 are RV64's LD and LWU. They read as "?" until -rv64
       existed, and then they were most of the binary: every slot, cell and
       field access on the wide target is one of these two, so a listing of
       RV64 output was mostly question marks -- which is what the width bug in
       the try_or record's save area had to be read around. *)
    let m = [| "lb"; "lh"; "lw"; "ld"; "lbu"; "lhu"; "lwu"; "?" |].(f3) in
    sp "%s %s, %d(%s)" m (r rd) (imm_i inst) (r rs1)
  | 0x23 ->
    let m = [| "sb"; "sh"; "sw"; "sd"; "?"; "?"; "?"; "?" |].(f3) in
    sp "%s %s, %d(%s)" m (r rs2) (imm_s inst) (r rs1)
  | 0x13 ->
    let i = imm_i inst in
    (match f3 with
     | 0 ->
       if rs1 = 0 then sp "li %s, %d" (r rd) i
       else if i = 0 then sp "mv %s, %s" (r rd) (r rs1)
       else sp "addi %s, %s, %d" (r rd) (r rs1) i
     | 2 -> sp "slti %s, %s, %d" (r rd) (r rs1) i
     | 3 -> sp "sltiu %s, %s, %d" (r rd) (r rs1) i
     | 4 -> sp "xori %s, %s, %d" (r rd) (r rs1) i
     | 6 -> sp "ori %s, %s, %d" (r rd) (r rs1) i
     | 7 -> sp "andi %s, %s, %d" (r rd) (r rs1) i
     (* shamt is 6 bits on RV64 and 5 on RV32; reading 6 is right for both,
        because a legal RV32 encoding leaves bit 25 clear. And srli/srai is
        told apart by bit 30 -- NOT by f7 = 0, which on RV64 is part of the
        shift amount: `srli x, y, 32` has f7 = 1 and used to print as `srai`. *)
     | 1 -> sp "slli %s, %s, %d" (r rd) (r rs1) ((inst lsr 20) land 0x3F)
     | 5 -> if (inst lsr 30) land 1 = 0
            then sp "srli %s, %s, %d" (r rd) (r rs1) ((inst lsr 20) land 0x3F)
            else sp "srai %s, %s, %d" (r rd) (r rs1) ((inst lsr 20) land 0x3F)
     | _ -> sp ".word 0x%08x" inst)
  (* RV64's 32-bit-result forms. Neither opcode was decoded at all, so every
     addiw/addw/mulw/divw in the output fell through to `.word` -- and the
     backend emits them for every narrowing arithmetic op on the wide target. *)
  | 0x1B ->
    (match f3 with
     | 0 -> sp "addiw %s, %s, %d" (r rd) (r rs1) (imm_i inst)
     | 1 -> sp "slliw %s, %s, %d" (r rd) (r rs1) rs2
     | 5 -> if (inst lsr 30) land 1 = 0
            then sp "srliw %s, %s, %d" (r rd) (r rs1) rs2
            else sp "sraiw %s, %s, %d" (r rd) (r rs1) rs2
     | _ -> sp ".word 0x%08x" inst)
  | 0x3B when f7 = 1 ->
    let m = [| "mulw"; "?"; "?"; "?"; "divw"; "divuw"; "remw"; "remuw" |].(f3) in
    sp "%s %s, %s, %s" m (r rd) (r rs1) (r rs2)
  | 0x3B ->
    (match f3 with
     | 0 -> if f7 = 0 then sp "addw %s, %s, %s" (r rd) (r rs1) (r rs2)
            else if rs1 = 0 then sp "negw %s, %s" (r rd) (r rs2)
            else sp "subw %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 1 -> sp "sllw %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 5 -> if f7 = 0 then sp "srlw %s, %s, %s" (r rd) (r rs1) (r rs2)
            else sp "sraw %s, %s, %s" (r rd) (r rs1) (r rs2)
     | _ -> sp ".word 0x%08x" inst)
  | 0x33 when f7 = 1 ->
    let m = [| "mul"; "mulh"; "mulhsu"; "mulhu"; "div"; "divu"; "rem"; "remu" |].(f3) in
    sp "%s %s, %s, %s" m (r rd) (r rs1) (r rs2)
  | 0x33 ->
    (match f3 with
     | 0 -> if f7 = 0 then sp "add %s, %s, %s" (r rd) (r rs1) (r rs2)
            else if rs1 = 0 then sp "neg %s, %s" (r rd) (r rs2)
            else sp "sub %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 1 -> sp "sll %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 2 -> sp "slt %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 3 -> if rs1 = 0 then sp "snez %s, %s" (r rd) (r rs2)
            else sp "sltu %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 4 -> sp "xor %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 5 -> if f7 = 0 then sp "srl %s, %s, %s" (r rd) (r rs1) (r rs2)
            else sp "sra %s, %s, %s" (r rd) (r rs1) (r rs2)
     | 6 -> sp "or %s, %s, %s" (r rd) (r rs1) (r rs2)
     | _ -> sp "and %s, %s, %s" (r rd) (r rs1) (r rs2))
  | 0x73 ->
    (* SYSTEM: the CSR instructions carry the register number in the immediate
       field, so without this every one of them read as "ebreak" *)
    let csr = (inst lsr 20) land 0xFFF in
    let m = [| ""; "csrrw"; "csrrs"; "csrrc"; ""; "csrrwi"; "csrrsi"; "csrrci" |].(f3) in
    if f3 = 1 || f3 = 2 || f3 = 3 then
      sp "%s %s, 0x%x, %s" m (r rd) csr (r rs1)
    else if f3 = 5 || f3 = 6 || f3 = 7 then
      sp "%s %s, 0x%x, %d" m (r rd) csr rs1        (* rs1 field is the immediate *)
    else if inst = 0x30200073 then "mret"
    else if inst = 0x10500073 then "wfi"
    else if inst = 0x73 then "ecall"
    else "ebreak"
  | 0x0F -> "fence"
  | _ -> sp ".word 0x%08x" inst

(* disassemble a whole flat binary: `addr: word  mnemonic` per line *)
let disasm_binary (bytes : string) : string =
  let n = String.length bytes in
  let buf = Buffer.create (n * 4) in
  let word i =
    (Char.code bytes.[i])
    lor (Char.code bytes.[i + 1] lsl 8)
    lor (Char.code bytes.[i + 2] lsl 16)
    lor (Char.code bytes.[i + 3] lsl 24)
  in
  let i = ref 0 in
  while !i + 4 <= n do
    let w = word !i in
    Buffer.add_string buf (sp "%6x:  %08x  %s\n" !i w (disasm_word ~pc:!i w));
    i := !i + 4
  done;
  Buffer.contents buf
