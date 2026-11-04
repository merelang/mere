#!/usr/bin/env python3
"""Compare exclusive OwnedVec access and spawn handoff with C at both widths."""
import argparse
import subprocess
from pathlib import Path

from rv_builder_owner_check import PREFIX, run_suite


def handoff_fixtures():
    cases = {}
    body = 'channel_send results (try_or_msg (fn () -> let _ = owned_vec_len g in "allowed") (fn msg -> msg))'
    forms = {
        "inline": f"let h = spawn (fn () -> {body});",
        "generic_inline": f"let h = spawn (fn () -> {body.replace('owned_vec_len g', 'len g')});",
        "parameter": f"let launch = fn (f: unit -> unit) -> spawn f; let h = launch (fn () -> {body});",
        "named": f"let jobs = channel_new (); let _ = channel_send jobs (fn () -> {body}); let task = channel_recv jobs; let h = spawn task;",
        "returned": f"let keep = fn (f: unit -> unit) -> f; let h = spawn (keep (fn () -> {body}));",
        "channel": f"let jobs = channel_new (); let _ = channel_send jobs (fn () -> {body}); let h = spawn (channel_recv jobs);",
        "annotated": f"let h = spawn ((fn () -> {body}): unit -> unit);",
        "builtin_alias": f"let start = spawn; let h = start (fn () -> {body});",
        "rebound_builtin": f"let spawn = spawn; let h = spawn (fn () -> {body});",
        "hidden_capture": 'let jobs = channel_new (); let _ = channel_send jobs (fn () -> owned_vec_len g); let read = channel_recv jobs; let h = spawn (fn () -> channel_send results (try_or_msg (fn () -> let _ = read () in "allowed") (fn msg -> msg)));',
    }
    for ctor, make in {"new": "owned_vec_new ()", "copy": "let v = vec_new () in vec_to_owned v"}.items():
        for form, launch in forms.items():
            cases[f"handoff_{ctor}_{form}"] = f"""let mk = fn () -> let g = {make} in let _ = owned_vec_push g 1 in g;
let g = mk ();
let parent = fn () -> let _ = owned_vec_push g 2 in owned_vec_len g;
let results = channel_new ();
{launch}
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> str_of_int (parent ())) "owner-blocked")
"""
    # Conversion produces an ordinary Vec: a foreign generic len must read
    # and freeze it, rather than apply OwnedVec's exclusive access rule.
    for ctor, make in {"new": "vec_new ()", "converted": "let g = owned_vec_new () in let _ = owned_vec_push g 9 in owned_vec_to_vec g"}.items():
        for seed in ("empty", "full"):
            initial = "()" if seed == "empty" else "vec_push v 1"
            cases[f"generic_vec_{ctor}_{seed}"] = PREFIX + f"""let mk = fn () -> let v = {make} in let _ = vec_recycle v in let _ = (if false then vec_push v 0 else ()) in let _ = {initial} in v;
let v = mk ();
let results = channel_new ();
let h = launch (fn () -> channel_send results (len v));
let _ = join h;
let _ = print_int (channel_recv results);
print (try_or (fn () -> let _ = vec_push v 2 in "allowed") "shared")
"""
    return cases


def fixtures():
    cases = handoff_fixtures()
    ops = {"push": "owned_vec_push g 9", "get": "owned_vec_get g 0",
           "get_negative": "owned_vec_get g (-1)", "get_past": "owned_vec_get g 999",
           "len": "owned_vec_len g", "generic_len": "len g", "to_vec": "owned_vec_to_vec g"}
    for ctor, make in {"new": "owned_vec_new ()", "copy": "let v = vec_new () in vec_to_owned v"}.items():
        for seed in ("empty", "full"):
            initial = "()" if seed == "empty" else "owned_vec_push g 1"
            setup = PREFIX + f"let mk = fn () -> let g = {make} in let _ = (if false then owned_vec_push g 0 else ()) in let _ = {initial} in g;\nlet g = mk ();\n"
            for op, expr in ops.items():
                cases[f"foreign_{ctor}_{seed}_{op}"] = setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = owned_vec_push g 2 in "owner-ok") "owner-blocked");
let _ = print_int (try_or (fn () -> owned_vec_len g) 99);
print_int (try_or (fn () -> owned_vec_get g 0) 100)
"""
            for op, expr in {"push": 'owned_vec_push g "bad"', "get": "owned_vec_get g 0", "to_vec": "owned_vec_to_vec g"}.items():
                cases[f"typed_{ctor}_{seed}_{op}"] = PREFIX + f"""let mk = fn () -> let g = {make} in let _ = (if false then owned_vec_push g "" else ()) in let _ = (if {str(seed == 'full').lower()} then owned_vec_push g "kept" else ()) in g;
let g = mk ();
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = owned_vec_push g "again";
let v = owned_vec_to_vec g;
print (show v)
"""
        for op, expr in ops.items():
            if op.startswith("get_"):
                continue
            cases[f"after_move_{ctor}_{op}"] = f"""let g = {make};
let _ = owned_vec_push g 1;
let retained = fn () -> let _ = {expr} in ();
let ready = channel_new ();
let finish = channel_new ();
let h = spawn (fn () -> let _ = owned_vec_len g in let _ = channel_send ready () in channel_recv finish);
let _ = channel_recv ready;
let result = try_or_msg (fn () -> let _ = retained () in "allowed") (fn msg -> msg);
let _ = channel_send finish ();
let _ = join h;
print result
"""
    for ctor, make in {"new": "owned_vec_new ()", "copy": "let v = vec_new () in vec_to_owned v"}.items():
        for seed in ("empty", "full"):
            initial = "()" if seed == "empty" else "owned_vec_push g 1"
            cases[f"conversion_claim_{ctor}_{seed}"] = f"""let g = {make};
let _ = (if false then owned_vec_push g 0 else ());
let _ = {initial};
let retained = fn () -> owned_vec_len g;
let ready = channel_new ();
let finish = channel_new ();
let h = spawn (fn () -> let v = owned_vec_to_vec g in let _ = channel_send ready (vec_len v) in channel_recv finish);
let size = channel_recv ready;
let result = try_or_msg (fn () -> let _ = retained () in "allowed") (fn msg -> msg);
let _ = channel_send finish ();
let _ = join h;
let _ = print result;
print_int size
"""
    root = Path(__file__).resolve().parent.parent
    cases["native_move"] = (root / "test/owner/ov_moved.mere").read_text()
    cases["local_move"] = """let results = channel_new ();
let ready = channel_new ();
let h = let g = owned_vec_new () in let _ = owned_vec_push g 1 in
  spawn (fn () -> let _ = channel_recv ready in let _ = owned_vec_push g 2 in channel_send results (owned_vec_len g));
let _ = channel_send ready ();
let _ = join h;
print_int (channel_recv results)
"""
    cases["nested_move"] = """let results = channel_new ();
let ready = channel_new ();
let a = spawn (fn () ->
  let b = let g = owned_vec_new () in let _ = owned_vec_push g 1 in
    spawn (fn () -> let _ = channel_recv ready in let _ = owned_vec_push g 2 in channel_send results (owned_vec_len g)) in
  let _ = channel_send ready () in join b);
let _ = join a;
print_int (channel_recv results)
"""
    cases["multiple_move"] = """let a = owned_vec_new ();
let b = owned_vec_new ();
let _ = owned_vec_push a 10;
let _ = owned_vec_push b 20;
let results = channel_new ();
let h = spawn (fn () -> let _ = owned_vec_push a 1 in let _ = owned_vec_push b 2 in channel_send results (owned_vec_get a 0 + owned_vec_get b 0 + owned_vec_len a + owned_vec_len b));
let _ = join h;
print_int (channel_recv results)
"""
    for first in ("parent", "unused"):
        worker = 'let _ = channel_recv ready in channel_send results (try_or_msg (fn () -> let _ = owned_vec_len g in "allowed") (fn msg -> msg))' if first == "parent" else 'let mode = channel_recv ready in let _ = (if mode == 1 then owned_vec_len g else 0) in ()'
        after = 'let _ = retained (); let _ = channel_send ready (); let _ = join h; print (channel_recv results)' if first == "parent" else 'let _ = channel_send ready 0; let _ = join h; print_int (retained ())'
        cases[f"claim_{first}"] = f"""let g = owned_vec_new ();
let _ = owned_vec_push g 1;
let retained = fn () -> owned_vec_len g;
let ready = channel_new ();
let results = channel_new ();
let h = spawn (fn () -> {worker});
{after}
"""
    cases["joined_owner"] = """let g = owned_vec_new ();
let _ = owned_vec_push g 1;
let retained = fn () -> owned_vec_len g;
let h = spawn (fn () -> let _ = owned_vec_len g in ());
let _ = join h;
print (try_or_msg (fn () -> let _ = retained () in "allowed") (fn msg -> msg))
"""
    cases["worker_identities"] = PREFIX + """let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = launch (fn () ->
  let g = owned_vec_new () in let _ = owned_vec_push g 1 in
  let _ = channel_send callbacks (fn () -> owned_vec_len g) in
  let _ = channel_recv ready in let _ = owned_vec_push g 2 in channel_send results (owned_vec_len g));
let b = launch (fn () -> let read = channel_recv callbacks in let r = try_or (fn () -> let _ = read () in 0) 7 in let _ = channel_send ready () in channel_send results r);
let _ = join a;
let _ = join b;
print_int (channel_recv results + channel_recv results)
"""
    cases["worker_reuse"] = PREFIX + """let g = owned_vec_new ();
let _ = owned_vec_push g 1;
let retained = fn () -> owned_vec_len g;
let a = spawn (fn () -> let _ = owned_vec_len g in ());
let _ = join a;
let results = channel_new ();
let b = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = retained () in "allowed") (fn msg -> msg)));
let _ = join b;
print (channel_recv results)
"""
    work = """let work = fn () ->
  let v = vec_new () in let _ = vec_push v "source" in
  let g = vec_to_owned v in
  let rec fill = fn (i: int) -> if i == 80 then () else let _ = owned_vec_push g (str_of_int i) in fill (i + 1) in
  let _ = fill 0 in
  let copy = owned_vec_to_vec g in let _ = vec_set copy 0 "independent" in
  let _ = vec_push v "original" in
  owned_vec_get g 0 ++ ":" ++ str_of_int (owned_vec_len g + vec_len copy + vec_len v);
"""
    cases["local_growth"] = PREFIX + work + """let results = channel_new ();
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
let _ = print own;
print (channel_recv results)
"""
    cases["plain_growth"] = work + 'print (work ())\n'
    cases["copy_survives_region"] = PREFIX + """let root = coro_root ();
let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());
let _ = coro_switch c;
let work = fn () ->
  let g = owned_vec_new () in let _ = owned_vec_push g (str_repeat "g" 9000) in
  let v = owned_vec_to_vec g in
  let _ = region R { vec_compact v } in
  let _ = region Q { let d = map_new () in let _ = map_compact d in let _ = map_set d "x" (str_repeat "x" 9000) in map_len d } in
  let _ = vec_set v 0 "copy" in str_of_int (str_len (owned_vec_get g 0)) ++ ":" ++ vec_get v 0;
let h = launch (fn () -> ());
let _ = join h;
print (work ())
"""
    cases["argument_once"] = PREFIX + """let g = owned_vec_new ();
let _ = owned_vec_push g 42;
let calls = vec_new ();
let _ = vec_push calls 0;
let source = fn () -> let _ = vec_set calls 0 (vec_get calls 0 + 1) in g;
let index = fn () -> let _ = vec_set calls 0 (vec_get calls 0 + 1) in 0;
let h = launch (fn () -> ());
let _ = join h;
let _ = print_int (owned_vec_get (source ()) (index ()));
let _ = print_int (vec_len (owned_vec_to_vec (source ())));
print_int (vec_get calls 0)
"""
    cases["opaque_par_map"] = """let g = owned_vec_new ();
let _ = owned_vec_push g 1;
let run = fn (f: int -> int) -> par_map f [1, 2];
let xs = run (fn x -> try_or (fn () -> owned_vec_len g) 7);
print_int (list_sum xs + owned_vec_len g)
"""
    cases["converted_vec_owner"] = PREFIX + """let results = channel_new ();
let h = launch (fn () ->
  let g = owned_vec_new () in let _ = owned_vec_push g 1 in
  let v = owned_vec_to_vec g in
  let child = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = vec_push v 9 in "allowed") (fn msg -> msg))) in
  let _ = join child in let _ = owned_vec_push g 2 in channel_send results (str_of_int (owned_vec_len g)));
let _ = join h;
let _ = print (channel_recv results);
print (channel_recv results)
"""
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    assert len(cases) == 93, "fixture catalogue changed"
    def poison_check(case, actual, expected):
        if case == "native_move":
            return actual[0] != 0 and b"an OwnedVec belongs to one thread" in actual[1] + actual[2]
        return actual[0] == 0 and b"allowed\n" in actual[1] and actual != expected
    run_suite("rv_ownedvec_owner", cases, [
        ("foreign_new_full_push", ["__ov_use_owned_vec_push", "__vec_write_vec_push"]),
        ("foreign_new_full_get", ["__ov_use_owned_vec_get"]),
        ("foreign_new_empty_len", ["__ov_use_owned_vec_len"]),
        ("foreign_new_empty_generic_len", ["__ov_use_owned_vec_len"]),
        ("foreign_new_full_to_vec", ["__ov_use_owned_vec_to_vec"]),
        ("foreign_new_empty_len", ["__vec_track"]),
        ("foreign_copy_empty_len", ["__vec_track"]),
        ("native_move", ["__ov_release"]),
        ("after_move_new_len", ["__ov_claim"]),
    ], cases["plain_growth"], ["__ov_use_", "__ov_release", "__ov_claim", "__vec_track"], args.poison, poison_check)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"rv_ownedvec_owner: FAIL {error}")
