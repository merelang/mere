#!/usr/bin/env python3
"""Compare StrBuf ownership with C on RV32 and RV64."""
import argparse
import subprocess

from rv_builder_owner_check import PREFIX, run_suite


def fixtures():
    cases = {}
    for seed in ("empty", "full"):
        initial = "()" if seed == "empty" else 'strbuf_push b "abc"'
        setup = PREFIX + f"let mk = fn () -> let b = strbuf_new () in let _ = {initial} in b;\nlet b = mk ();\n"
        state = 'let _ = print_int (strbuf_len b); print (strbuf_to_str b)\n'
        for op, expr in {"push": 'strbuf_push b "x"', "empty_push": 'strbuf_push b ""',
                         "growth": 'strbuf_push b (str_repeat "xy" 40)', "utf8": 'strbuf_push b "あ🦊"'}.items():
            catch = f'try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)'
            cases[f"foreign_{seed}_{op}"] = setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({catch}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = strbuf_push b "owner" in "owner-ok") "owner-blocked");
""" + state
            cases[f"shared_{seed}_{op}"] = setup + f"""let h = launch (fn () -> let _ = strbuf_len b in ());
let _ = join h;
let _ = print ({catch});
""" + state
        for op, expr in {"len": "strbuf_len b", "generic_len": "len b", "snapshot": "strbuf_to_str b"}.items():
            cases[f"read_{seed}_{op}"] = setup + f"""let h = launch (fn () -> let _ = {expr} in ());
let _ = join h;
let _ = print (try_or_msg (fn () -> let _ = strbuf_push b "x" in "allowed") (fn msg -> msg));
""" + state
    cases["snapshot"] = PREFIX + """let b = strbuf_new ();
let _ = strbuf_push b "あ🦊";
let snapshot = strbuf_to_str b;
let results = channel_new ();
let h = launch (fn () -> channel_send results (str_len snapshot));
let _ = join h;
let _ = strbuf_push b (str_repeat "x" 40);
let _ = print snapshot;
print_int (strbuf_len b + channel_recv results)
"""
    cases["local_growth"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let b = strbuf_new () in
  let rec fill = fn (i: int) -> if i == 40 then () else let _ = strbuf_push b (str_of_int i ++ "|") in fill (i + 1) in
  let _ = fill 0 in let _ = strbuf_push b "あ🦊" in
  strbuf_to_str b;
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
let _ = print own;
print (channel_recv results)
"""
    cases["nested"] = PREFIX + """let results = channel_new ();
let a = launch (fn () ->
  let b = strbuf_new () in let _ = strbuf_push b "kept" in
  let child = launch (fn () -> channel_send results (try_or (fn () -> let _ = strbuf_push b "bad" in 0) 7)) in
  let _ = join child in let _ = strbuf_push b "-again" in channel_send results (strbuf_len b));
let _ = join a;
print_int (channel_recv results + channel_recv results)
"""
    cases["identities"] = PREFIX + """let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = launch (fn () ->
  let b = strbuf_new () in let _ = strbuf_push b "kept" in
  let _ = channel_send callbacks (fn () -> strbuf_len b) in
  let _ = channel_recv ready in
  channel_send results (try_or (fn () -> let _ = strbuf_push b "bad" in 0) 7));
let c = launch (fn () -> let read = channel_recv callbacks in let _ = read () in channel_send ready ());
let _ = join a;
let _ = join c;
print_int (channel_recv results)
"""
    cases["par_map"] = """let b = strbuf_new ();
let _ = strbuf_push b "x";
let run = fn (f: int -> int) -> par_map f [1, 2];
let xs = run (fn x -> let _ = strbuf_to_str b in x);
let failed = try_or (fn () -> let _ = strbuf_push b "bad" in 0) 7;
print_int (list_sum xs + failed)
"""
    cases["aliases"] = PREFIX + """let mk = fn () -> let b = strbuf_new () in (b, b);
let (b, alias) = mk ();
let h = launch (fn () -> let _ = strbuf_to_str alias in ());
let _ = join h;
print (try_or_msg (fn () -> let _ = strbuf_push b "bad" in "allowed") (fn msg -> msg))
"""
    cases["region_growth"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let b = strbuf_new () in
  let _ = region R { strbuf_push b (str_repeat "x" 80) } in
  let _ = region Q { str_len (str_repeat "z" 4096) } in
  let _ = strbuf_push b "again" in strbuf_to_str b;
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
let _ = print own;
print (channel_recv results)
"""
    cases["coroutine"] = """let b = strbuf_new ();
let h = spawn (fn () -> ());
let _ = join h;
let c = coro_new (fn _me -> fn (_u: unit) -> let _ = strbuf_push b "coro" in coro_exit (coro_root ()) ());
let _ = coro_switch c;
let _ = strbuf_push b "-main";
print (strbuf_to_str b)
"""
    cases["internal_builders"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let v = vec_new () in let _ = vec_push v 65 in
  let bytes = bytes_of_vec v in
  str_repeat "ab" 40 ++ to_upper "private" ++ show v ++ str_of_bytes bytes;
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
let _ = print own;
print (channel_recv results)
"""
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    assert len(cases) == 31, "fixture catalogue changed"
    run_suite("rv_strbuf_owner", cases, [
        ("foreign_full_push", ["__sb_write"]),
        ("read_empty_len", ["__sb_read"]),
        ("read_full_snapshot", ["__sb_read"]),
        ("foreign_full_push", ["__sb_track"]),
    ], 'let b = strbuf_new (); let _ = strbuf_push b "x"; print (strbuf_to_str b)\n',
        ["__sb_track", "__sb_read", "__sb_write"], args.poison)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"rv_strbuf_owner: FAIL {error}")
