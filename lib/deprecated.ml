(* Names the compiler ships and would rather you stopped using.

   WHY THIS IS NOT AN ATTRIBUTE. Gleam marks a deprecation on the definition
   (`@deprecated("use x instead")`), which is the right design for a language
   whose users write libraries for each other. Mere has no attribute syntax, and
   adding one costs two parsers — this one and the self-hosted one in
   `contrib/parser` — for a feature whose whole current population is names this
   compiler itself hands out. So the deprecation lives here, in a table, and
   costs no grammar at all. The day a user needs to deprecate something in their
   own code is the day to weigh an attribute against its second implementation.

   WHY THE TABLE IS EMPTY. Because Mere has not deprecated anything yet. That
   was checked rather than assumed: all 281 entries of `Typer.initial_env` were
   listed and compared for the pairs a rename leaves behind (`str_len` /
   `str_length`, `f_add` / `float_add`, an `_of` beside its bare name), and
   there are none — the only near-pair, `str_of_int` and `float_of_int`, is two
   different functions. An empty table is the honest state, and the mechanism is
   here so that the first rename can be carried to every user instead of being
   announced in a changelog nobody re-reads.

   HOW TO ADD ONE. Append a row. The name is matched only where it resolves to
   the BUILTIN — a user who binds `str_len` themselves gets no warning about
   their own name, which is the difference between this and a grep. The warning
   carries a fix that rewrites the name, so an editor can apply it, and
   `test/test_basic.ml` drives the whole path through `table` without the
   production table needing a row in it. *)

type row = {
  dp_name : string;         (* the builtin being retired *)
  dp_replacement : string;  (* what to write instead *)
  dp_since : string;        (* the version that deprecated it *)
  dp_why : string;          (* one clause, printed after the comma *)
}

(* Mutable so that the tests can install a row: the mechanism has to be
   exercised end to end even while nothing real is deprecated, and a mechanism
   whose only test is "the empty table warns about nothing" is not tested. *)
let table : row list ref = ref []

let lookup (name : string) : row option =
  List.find_opt (fun r -> r.dp_name = name) !table

(* Uses seen during one check, drained by the pipeline. A ref for the same
   reason the exhaustiveness checker keeps one: the alternative is threading an
   accumulator through inference to answer a question two callers ask. *)
let seen : (row * Loc.t) list ref = ref []

let reset () = seen := []

let note (r : row) (loc : Loc.t) =
  (* One report per position. Inference visits a declaration's body twice (once
     as a declaration, once inside the desugared program), and the same name at
     the same place is one use of it. *)
  if not (List.exists (fun (r', l) -> r' == r && l = loc) !seen) then
    seen := (r, loc) :: !seen

let take () = let s = List.rev !seen in seen := []; s
