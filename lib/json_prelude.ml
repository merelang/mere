(* json_prelude.ml -- the JSON parser of_json decodes with, in Mere: the C
   runtime's parser line for line, producing a generic tree of `__ojn` nodes
   that a per-type decoder walks. Shared by the backends that have no native
   one: RISC-V glues it in with its prelude (v0.1.654), LLVM adds it to a
   program that uses of_json (v0.1.665). An error does not unwind: the first
   one is kept, every later step answers a null node or 0, and the caller asks
   __oj_failed. *)

let core = {mere|type __ojn = { ojk: int, ojb: int, ojt: str, oji: __ojn Vec, ojkeys: str Vec };
let __oj_state = (vec_new () : int Vec);
let __oj_msgs = (vec_new () : str Vec);
let __oj_mk = fn (k: int) -> fn (b: int) -> fn (t: str) ->
  __ojn { ojk = k, ojb = b, ojt = t, oji = (vec_new () : __ojn Vec), ojkeys = (vec_new () : str Vec) };
let __oj_null = fn (u: unit) -> __oj_mk 0 0 "";
let __oj_failed = fn (u: unit) -> if vec_len __oj_state > 1 && vec_get __oj_state 1 == 1 then 1 else 0;
let __oj_die = fn (m: str) ->
  let _ = (if __oj_failed () == 1 then ()
           else (let _ = vec_set __oj_state 1 1 in
                 if vec_len __oj_msgs == 0 then vec_push __oj_msgs m else vec_set __oj_msgs 0 m)) in
  __oj_null ();
// the generated decoders' word for a shape they cannot take; 0
let __oj_fail = fn (m: str) -> let _ = __oj_die m in 0;
let __oj_reset = fn (u: unit) ->
  let _ = (if vec_len __oj_state == 0 then (let _ = vec_push __oj_state 0 in vec_push __oj_state 0) else ()) in
  let _ = vec_set __oj_state 0 0 in
  vec_set __oj_state 1 0;
let __oj_utf8_valid = fn (s: str) ->
  let n = str_len s in
  let b = bytes_of_str s in
  let at = fn (i: int) -> __bytes_get_unchecked b i in
  let rec go = fn (i: int) ->
    if i >= n then true
    else
      (let c = at i in
       if c < 128 then go (i + 1)
       else if c < 194 || c > 244 then false
       else
         (let need = if c < 224 then 1 else if c < 240 then 2 else 3 in
          let lo = if c == 224 then 160 else if c == 240 then 144 else 128 in
          let hi = if c == 237 then 159 else if c == 244 then 143 else 191 in
          if i + need >= n then false
          else if at (i + 1) < lo || at (i + 1) > hi then false
          else if need >= 2 && bit_and (at (i + 2)) 192 != 128 then false
          else if need >= 3 && bit_and (at (i + 3)) 192 != 128 then false
          else go (i + need + 1))) in
  go 0;
let __oj_ws = fn (s: str) ->
  let rec go = fn (u: unit) ->
    let p = vec_get __oj_state 0 in
    if p < str_len s && (let c = ord (char_at s p) in c == 32 || c == 9 || c == 10 || c == 13)
    then (let _ = vec_set __oj_state 0 (p + 1) in go ()) else () in
  go ();
let __oj_peek = fn (s: str) -> let p = vec_get __oj_state 0 in if p < str_len s then ord (char_at s p) else 0 - 1;
let __oj_adv = fn (k: int) -> vec_set __oj_state 0 (vec_get __oj_state 0 + k);
let __oj_pstr = fn (s: str) ->
  let _ = __oj_adv 1 in
  let sb = strbuf_new () in
  let rec go = fn (u: unit) ->
    let p = vec_get __oj_state 0 in
    if p >= str_len s then (let _ = __oj_die "unterminated string" in "")
    else
      (let c = ord (char_at s p) in
       if c == 34 then
         (let _ = __oj_adv 1 in
          let out = strbuf_to_str sb in
          if __oj_utf8_valid out then out else (let _ = __oj_die "invalid UTF-8 in string" in ""))
       else if c == 92 && p + 1 < str_len s then
         (let e = ord (char_at s (p + 1)) in
          let o = if e == 110 then 10 else if e == 116 then 9 else if e == 114 then 13
                  else if e == 98 then 8 else if e == 102 then 12 else e in
          let _ = strbuf_push sb (chr o) in
          let _ = __oj_adv 2 in
          go ())
       else (let _ = strbuf_push sb (chr c) in let _ = __oj_adv 1 in go ())) in
  go ();
let __oj_lit = fn (s: str) -> fn (w: str) ->
  let p = vec_get __oj_state 0 in
  p + str_len w <= str_len s && substring s p (p + str_len w) == w;
let rec __oj_val = fn (s: str) ->
  let _ = __oj_ws s in
  if __oj_failed () == 1 then __oj_null ()
  else
    (let c = __oj_peek s in
     if c < 0 then __oj_die "unexpected end of input"
     else if c == 123 then __oj_obj s
     else if c == 91 then __oj_arr s
     else if c == 34 then (let t = __oj_pstr s in __oj_mk 3 0 t)
     else if c == 116 then (if __oj_lit s "true" then (let _ = __oj_adv 4 in __oj_mk 1 1 "") else __oj_die "expected true")
     else if c == 102 then (if __oj_lit s "false" then (let _ = __oj_adv 5 in __oj_mk 1 0 "") else __oj_die "expected false")
     else if c == 110 then (if __oj_lit s "null" then (let _ = __oj_adv 4 in __oj_null ()) else __oj_die "expected null")
     else if c == 45 || (c >= 48 && c <= 57) then
       (let start = vec_get __oj_state 0 in
        let _ = (if c == 45 then __oj_adv 1 else ()) in
        let rec num = fn (u: unit) ->
          let d = __oj_peek s in
          if (d >= 48 && d <= 57) || d == 46 || d == 101 || d == 69 || d == 43 || d == 45
          then (let _ = __oj_adv 1 in num ()) else () in
        let _ = num () in
        __oj_mk 2 0 (substring s start (vec_get __oj_state 0)))
     else __oj_die "unexpected character")
and __oj_arr = fn (s: str) ->
  let _ = __oj_adv 1 in
  let _ = __oj_ws s in
  let node = __oj_mk 4 0 "" in
  if __oj_peek s == 93 then (let _ = __oj_adv 1 in node)
  else
    (let rec go = fn (u: unit) ->
       let v = __oj_val s in
       if __oj_failed () == 1 then node
       else
         (let _ = vec_push node.oji v in
          let _ = __oj_ws s in
          let c = __oj_peek s in
          if c == 44 then (let _ = __oj_adv 1 in let _ = __oj_ws s in go ())
          else if c == 93 then (let _ = __oj_adv 1 in node)
          else __oj_die "expected ',' or ']' in array") in
     go ())
and __oj_obj = fn (s: str) ->
  let _ = __oj_adv 1 in
  let _ = __oj_ws s in
  let node = __oj_mk 5 0 "" in
  if __oj_peek s == 125 then (let _ = __oj_adv 1 in node)
  else
    (let rec go = fn (u: unit) ->
       let _ = __oj_ws s in
       if __oj_peek s != 34 then __oj_die "expected object key"
       else
         (let k = __oj_pstr s in
          let _ = __oj_ws s in
          if __oj_failed () == 1 then node
          else if __oj_peek s != 58 then __oj_die "expected ':'"
          else
            (let _ = __oj_adv 1 in
             let v = __oj_val s in
             if __oj_failed () == 1 then node
             else
               (let rec dup = fn (i: int) -> if i >= vec_len node.ojkeys then false else if vec_get node.ojkeys i == k then true else dup (i + 1) in
                if dup 0 then __oj_die "duplicate object key"
                else
                  (let _ = vec_push node.ojkeys k in
                   let _ = vec_push node.oji v in
                   let _ = __oj_ws s in
                   let c = __oj_peek s in
                   if c == 44 then (let _ = __oj_adv 1 in go ())
                   else if c == 125 then (let _ = __oj_adv 1 in node)
                   else __oj_die "expected ',' or '}' in object")))) in
     go ());
// the entry: a fresh state, the document parsed (what follows it ignored, as C)
let __oj_parse = fn (s: str) ->
  let _ = __oj_reset () in
  let v = __oj_val s in
  let _ = __oj_ws s in
  v;
// what a decoder reads from a node (C reads a field it was not given as 0 / "")
let __oj_kind = fn (n: __ojn) -> n.ojk;
let __oj_bool = fn (n: __ojn) -> n.ojb;
let __oj_str = fn (n: __ojn) -> n.ojt;
let __oj_len = fn (n: __ojn) -> vec_len n.oji;
let __oj_item = fn (n: __ojn) -> fn (i: int) -> if i < vec_len n.oji then vec_get n.oji i else __oj_null ();
let __oj_key0 = fn (n: __ojn) -> if vec_len n.ojkeys > 0 then vec_get n.ojkeys 0 else "";
let __oj_field = fn (n: __ojn) -> fn (k: str) ->
  if n.ojk != 5 then __oj_die "expected a JSON object"
  else
    (let rec find = fn (i: int) ->
       if i >= vec_len n.ojkeys then __oj_die "missing object field"
       else if vec_get n.ojkeys i == k then vec_get n.oji i else find (i + 1) in
     find 0);
// strtoll(text, 0, 10): leading space, a sign, digits; 0 when there are none
let __oj_int = fn (n: __ojn) ->
  let t = n.ojt in
  let len = str_len t in
  let rec sp = fn (i: int) -> if i < len && (let c = ord (char_at t i) in c == 32 || (c >= 9 && c <= 13)) then sp (i + 1) else i in
  let i0 = sp 0 in
  let neg = i0 < len && char_at t i0 == "-" in
  let i1 = if i0 < len && (char_at t i0 == "-" || char_at t i0 == "+") then i0 + 1 else i0 in
  let rec dig = fn (i: int) -> fn (acc: int) ->
    if i < len && (let c = ord (char_at t i) in c >= 48 && c <= 57) then dig (i + 1) (acc * 10 + (ord (char_at t i) - 48)) else acc in
  let v = dig i1 0 in
  if neg then 0 - v else v;
// strtod(text, 0): the longest prefix that is a number, 0.0 when none is
let __oj_float = fn (n: __ojn) ->
  let t = n.ojt in
  let rec longest = fn (k: int) ->
    if k <= 0 then 0.0
    else try_or (fn (u: unit) -> float_of_str (substring t 0 k)) (longest (k - 1)) in
  try_or (fn (u: unit) -> float_of_str t) (longest (str_len t - 1));
// of_json's end: the error printed as C prints it, and exit 1
|mere}

(* v0.1.665: LLVM's ends, typed. The decoders codegen_llvm generates answer
   `T option` (None after a failure), and these finish of_json the way C does:
   of_json prints `of_json: <message>` and exits 1, of_json_opt answers None. *)
let llvm_glue = {mere|
let __ojx_die = fn (u: unit) ->
  let _ = print_err ("of_json: " ++ vec_get __oj_msgs 0) in exit 1;
let __ojx_get = fn r -> match r with
  | Some v -> if __oj_failed () == 1 then __ojx_die () else v
  | None -> __ojx_die ();
let __ojx_opt = fn r -> match r with
  | Some v -> if __oj_failed () == 1 then None else Some v
  | None -> None;
|mere}

let llvm_contents = core ^ llvm_glue
