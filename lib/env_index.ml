(* v0.1.581: AN INDEX ON THE SHARED PART OF A BIG GROUP'S ENVIRONMENT.
   An environment is an association list, and a variable is found by walking it.
   Inside a `let rec ... and` group of a thousand members (mere-ruby's
   interpreter) the environment is every binding of the program so far plus the
   group, and each lookup of a name bound before the group walks past all of it:
   the walk was most of the whole type check. So while such a group is visited
   its environment is indexed once into a table, and a lookup walks only the
   bindings consed in front of it (the parameters and lets of the member being
   visited) until it reaches that list -- the physical one -- and asks the table.
   A lookup in a list that does not contain it walks to the end, as before.
   Same answers: the table keeps each name's FIRST binding, which is the one a
   walk finds. One index per kind of environment ([create]). *)

type 'a t = { mutable stack : ((string * 'a) list * (string, 'a) Hashtbl.t) list }

let create () : 'a t = { stack = [] }

(* below this many members a walk is cheaper than building the table *)
let threshold = 32

let with_index (ix : 'a t) (e : (string * 'a) list) (f : unit -> 'b) : 'b =
  let tbl = Hashtbl.create 4096 in
  List.iter (fun (k, v) -> if not (Hashtbl.mem tbl k) then Hashtbl.add tbl k v) e;
  let saved = ix.stack in
  ix.stack <- (e, tbl) :: saved;
  Fun.protect ~finally:(fun () -> ix.stack <- saved) f

(* [with_index] only when the group is big enough to pay for it *)
let with_group (ix : 'a t) (members : int) (e : (string * 'a) list) (f : unit -> 'b) : 'b =
  if members >= threshold then with_index ix e f else f ()

let lookup (ix : 'a t) (name : string) (env : (string * 'a) list) : 'a option =
  match ix.stack with
  | [] -> List.assoc_opt name env
  | (fe, tbl) :: _ ->
    let rec go l =
      if l == fe then Hashtbl.find_opt tbl name
      else match l with
        | [] -> None
        | (k, v) :: r -> if String.equal k name then Some v else go r in
    go env
