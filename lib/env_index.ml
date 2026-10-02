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

(* v0.1.594: AND ON THE TOP-LEVEL CHAIN. A program is a chain of `let`s, each
   consing its names onto the environment of the one before, so the environment
   at the thousandth binding is a thousand cells long and a lookup of anything
   bound early walks all of them: checking N top-level bindings was O(N^2) (8,000
   `let g = map_new ()` took 5 s). A [Spine] frame is that environment as a
   persistent map, and a `let` whose environment is exactly the frame's extends
   it by its own names ([extend]) for its body instead of starting over. The
   declaration loop, which is iterative, moves one frame along instead
   ([track]). The answers are the same for the same reason as above: a lookup
   walks to the frame's list and asks the map, which holds each name's first
   binding there. *)
module SMap = Map.Make (String)

type 'a frame =
  | Table of (string * 'a) list * (string, 'a) Hashtbl.t
  | Spine of (string * 'a) list * 'a SMap.t

type 'a t = { mutable stack : 'a frame list }

let create () : 'a t = { stack = [] }

(* below this many members a walk is cheaper than building the table *)
let threshold = 32

let with_index (ix : 'a t) (e : (string * 'a) list) (f : unit -> 'b) : 'b =
  let tbl = Hashtbl.create 4096 in
  List.iter (fun (k, v) -> if not (Hashtbl.mem tbl k) then Hashtbl.add tbl k v) e;
  let saved = ix.stack in
  ix.stack <- Table (e, tbl) :: saved;
  Fun.protect ~finally:(fun () -> ix.stack <- saved) f

(* [with_index] only when the group is big enough to pay for it *)
let with_group (ix : 'a t) (members : int) (e : (string * 'a) list) (f : unit -> 'b) : 'b =
  if members >= threshold then with_index ix e f else f ()

let map_of (e : (string * 'a) list) : 'a SMap.t =
  List.fold_left (fun m (k, v) -> if SMap.mem k m then m else SMap.add k v m) SMap.empty e

(* the cells of [child] in front of [parent], or None if [parent] is not a tail of it *)
let prefix_to (parent : (string * 'a) list) (child : (string * 'a) list) =
  let rec go acc l =
    if l == parent then Some acc
    else match l with
      | [] -> None
      | c :: r -> go (c :: acc) r in
  go [] child

(* [cells] oldest first: each one shadows what the map had *)
let add_cells m cells = List.fold_left (fun m (k, v) -> SMap.add k v m) m cells

(* Make the bottom-most frame describe [env]: the declaration loop calls this
   before each declaration. Outside any group only. *)
let track (ix : 'a t) (env : (string * 'a) list) : unit =
  match ix.stack with
  | [] -> ix.stack <- [Spine (env, map_of env)]
  | [Spine (fe, m)] ->
    if fe != env then
      ix.stack <- [(match prefix_to fe env with
                    | Some cells -> Spine (env, add_cells m cells)
                    | None -> Spine (env, map_of env))]
  | _ -> ()

(* [f] (the body of a `let` that made [child] from [parent]) with the frame
   extended, when [parent] is the frame's own list -- the next link of the
   chain. Anywhere else (a `let` inside a function) the frame stays. *)
let extend (ix : 'a t) ~(parent : (string * 'a) list) (child : (string * 'a) list)
    (f : unit -> 'b) : 'b =
  match ix.stack with
  | Spine (fe, m) :: _ when fe == parent && child != parent ->
    (match prefix_to parent child with
     | Some cells ->
       let saved = ix.stack in
       ix.stack <- Spine (child, add_cells m cells) :: saved;
       Fun.protect ~finally:(fun () -> ix.stack <- saved) f
     | None -> f ())
  | _ -> f ()

let lookup (ix : 'a t) (name : string) (env : (string * 'a) list) : 'a option =
  match ix.stack with
  | [] -> List.assoc_opt name env
  | Table (fe, tbl) :: _ ->
    let rec go l =
      if l == fe then Hashtbl.find_opt tbl name
      else match l with
        | [] -> None
        | (k, v) :: r -> if String.equal k name then Some v else go r in
    go env
  | Spine (fe, m) :: _ ->
    let rec go l =
      if l == fe then SMap.find_opt name m
      else match l with
        | [] -> None
        | (k, v) :: r -> if String.equal k name then Some v else go r in
    go env
