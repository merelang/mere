(* Which version of the compiler a program needs, and who says so.

   Two different questions live here, and keeping them apart is the point:

   1. THE DECLARED FLOOR. `mere.toml` may say `mere = ">= 0.1.480"`. That is a
      claim about what the package needs, and it is checked against the compiler
      that is actually running. Before this existed, running a package that
      needed newer syntax on an older compiler produced a PARSE ERROR pointing
      at a line of somebody else's code — true, useless, and impossible to act
      on without knowing the language's history.

   2. THE REQUIRED FLOOR. What the source in hand actually uses. Accumulated
      while parsing, from the sites where a feature is recognised, and reported
      by `mere fix` so that the declared floor can be made true rather than
      guessed.

   The two are not the same and must not be derived from each other: a declared
   floor is a promise to whoever installs the package, and a required floor is a
   measurement of the code. `mere fix` is the one place they meet, and it moves
   the promise to match the measurement — never the other way.

   ON THE TABLE BELOW. Every row's `ft_since` is read off `docs/changelog.md`:
   the version whose section first mentions the feature. That is evidence, not
   memory, and `scripts/version_floor_check.sh` re-derives each one so that a
   row invented by hand fails. The table is deliberately short — a row is worth
   having only for a feature old compilers in the wild do not have, and a floor
   of 0.1.0 excludes nobody. New syntax should add a row on the day it lands;
   that is cheap here and impossible to reconstruct later. *)

type feature = {
  ft_name : string;    (* what to call it in a sentence *)
  ft_since : string;   (* the first version that compiled it *)
  (* The word to look for in `docs/changelog.md`. `ft_since` is supposed to be
     the version of the section that first mentions it, and this is what makes
     that claim checkable rather than remembered: `scripts/version_floor_check.sh`
     re-derives every row from the changelog and fails when a row disagrees
     with the record it came from. *)
  ft_probe : string;
}

let bytes_api  = { ft_name = "the `bytes` type"; ft_since = "0.1.278";
                   ft_probe = "bytes_get" }
let simd_128   = { ft_name = "128-bit SIMD lane types (`f64x2` / `u8x16`)";
                   ft_since = "0.1.422"; ft_probe = "f64x2" }
let simd_f32x4 = { ft_name = "the `f32x4` lane type"; ft_since = "0.1.445";
                   ft_probe = "f32x4" }

let try_or_msg = { ft_name = "`try_or_msg` (the reason a catch was given)";
                   ft_since = "0.1.510"; ft_probe = "try_or_msg" }

let all = [ bytes_api; simd_128; simd_f32x4; try_or_msg ]

(* --- versions -------------------------------------------------------------

   Three numbers, compared as numbers. "0.1.9" is below "0.1.10", which string
   comparison gets backwards, and getting it backwards here means refusing a
   compiler that would have worked. *)

type v = int * int * int

let parse_version (s : string) : v option =
  match String.split_on_char '.' (String.trim s) with
  | [ a; b; c ] ->
    (match int_of_string_opt a, int_of_string_opt b, int_of_string_opt c with
     | Some a, Some b, Some c -> Some (a, b, c)
     | _ -> None)
  | _ -> None

let compare_v (a : v) (b : v) = compare a b

let string_of_v ((a, b, c) : v) = Printf.sprintf "%d.%d.%d" a b c

(* A constraint as it is written in `mere.toml`. Only `>= x.y.z` is understood,
   and a bare `x.y.z` means the same thing: a floor, which is the only question
   this answers. Anything else is refused by name rather than ignored — a
   constraint nobody reads is worse than no constraint, because it looks like
   one. *)
type constraint_parse =
  | Floor of v
  | Unreadable of string

let parse_constraint (s : string) : constraint_parse =
  let s = String.trim s in
  let body =
    if String.length s >= 2 && String.sub s 0 2 = ">=" then
      String.trim (String.sub s 2 (String.length s - 2))
    else s
  in
  match parse_version body with
  | Some v -> Floor v
  | None -> Unreadable s

(* --- the required floor ---------------------------------------------------

   A parse fills this in. It is a ref for the same reason `Exhaustive.deferred`
   is one: threading an accumulator through every parser entry point would touch
   every caller to answer a question only two of them ask. *)

let required : (feature * Loc.t) list ref = ref []

let reset () = required := []

let require (f : feature) (loc : Loc.t) =
  (* Positions from an imported file are kept: the floor is about the program
     being built, and an import is part of it. *)
  required := (f, loc) :: !required

(* The names that imply a feature.

   A type annotation is not the only way to use `f64x2`: most SIMD code names
   the operations and never writes the type. The operations all begin with the
   type's name, and `bytes` is the same shape, so the rule is a prefix on an
   identifier — deliberately conservative in one direction only. Someone who
   defines their own `bytes_slurp` gets a floor one release too high, which is
   a wrong number that says which feature it came from; missing the prefix
   would give a floor that is too LOW, and that is the kind that reaches a user
   as a parse error in someone else's file.

   Exact type names are handled at the parser's type sites, where there is no
   guessing at all. *)
let prefixes = [ ("bytes_", bytes_api); ("f64x2_", simd_128); ("u8x16_", simd_128);
                 ("f32x4_", simd_f32x4);
                 (* The whole name, which this mechanism reads as a prefix that
                    happens to have nothing after it: `try_or` is old and must
                    not pick up a floor, and it is one character short of
                    matching. Erring high is the safe direction here (a user
                    binding called `try_or_msg_anything` gets the floor too),
                    which is the same trade every row above makes. *)
                 ("try_or_msg", try_or_msg) ]

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

let note_ident (name : string) (loc : Loc.t) =
  List.iter (fun (p, f) -> if starts_with p name then require f loc) prefixes

(* The highest version anything in the parsed source needs, with the feature
   that needs it — because "you need 0.1.445" is a number and "`f32x4` needs
   0.1.445" is an answer. `None` when nothing in the table was used, which is
   the common case and means any version will do.
   The prelude is excluded by the caller, which knows what it is called: it is
   prepended to every program, it uses `bytes` itself, and a floor every file
   in the language shares is a floor about the compiler rather than about the
   code anyone wrote. *)
let floor ?(ignore_file = fun (_ : string) -> false) () : (v * feature) option =
  List.fold_left (fun acc ((f : feature), (loc : Loc.t)) ->
    match loc.Loc.file with
    | Some p when ignore_file p -> acc
    | _ ->
      (match parse_version f.ft_since with
       | None -> acc
       | Some v ->
         (match acc with
          | Some (best, _) when compare_v v best <= 0 -> acc
          | _ -> Some (v, f))))
    None !required
