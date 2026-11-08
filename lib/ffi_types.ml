(* An extern's outer arrows are its parameter list, not callback values. *)
let rec iter_signature_values f ty =
  match Ast.walk ty with
  | Ast.TyArrow (arg, rest) -> f arg; iter_signature_values f rest
  | result -> f result

let contains_callback ty =
  let rec visit seen ty =
    match Ast.walk ty with
    | Ast.TyArrow _ -> true
    | Ast.TyTuple ts -> List.exists (visit seen) ts
    | Ast.TyRef (_, _, inner) -> visit seen inner
    | Ast.TyCon (name, args) ->
      List.exists (visit seen) args ||
      (not (List.mem name seen) &&
       match Typer.nominal_contents name args with
       | Some fields -> List.exists (visit (name :: seen)) fields
       | None -> false)
    | _ -> false
  in
  visit [] ty

(* LLVM does not implement the host C ABI for closure aggregates. Reject
   before lowering, including callbacks hidden in nominal types or results. *)
let reject_callbacks ~backend ~reject (prog : Ast.program) =
  List.iter (function
    | Ast.Top_extern (name, ty) ->
      iter_signature_values (fun value ->
        if contains_callback value then
          reject (Printf.sprintf
            "extern `%s`: callback values are unsupported on the %s backend; use the C backend (-c)"
            name backend)) ty
    | _ -> ()) prog.decls

(* A header must stand alone. Do not print names whose representation it
   cannot define, even when they occur inside a callback or record field. *)
let check_header ~reject name ty =
  let unsupported ty = reject (Printf.sprintf
    "--ffi-header: extern `%s` uses unsupported type `%s`; supported values are scalars, bytes, monomorphic records and C-backend callbacks"
    name (Ast.pp_ty ty)) in
  let rec visit seen ty =
    match Ast.walk ty with
    | Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyBytes | Ast.TyUnit -> ()
    | Ast.TyArrow (a, b) -> visit seen a; visit seen b
    | Ast.TyCon (name, []) as t ->
      (match Hashtbl.find_opt Typer.records name with
       | Some info when info.Typer.r_params = [] ->
         if not (List.mem name seen) then
           List.iter (fun (_, field) -> visit (name :: seen) field) info.Typer.r_fields
       | _ -> unsupported t)
    | Ast.TyRef (_, _, Ast.TyUnit) as t -> unsupported t
    | Ast.TyRef (_, _, inner) -> visit seen inner
    | t -> unsupported t
  in
  iter_signature_values (visit []) ty
