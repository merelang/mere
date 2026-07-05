(module
  (type $cl (func (param i32) (param i32) (result i32)))
  (import "env" "puts" (func $puts (param i32)))
  (import "env" "__lang_str_of_float" (func $__lang_str_of_float (param f64) (result i32)))
  (import "env" "__lang_float_of_str" (func $__lang_float_of_str (param i32) (result f64)))
  (import "env" "__lang_sin" (func $__lang_sin (param f64) (result f64)))
  (import "env" "__lang_cos" (func $__lang_cos (param f64) (result f64)))
  (import "env" "__lang_tan" (func $__lang_tan (param f64) (result f64)))
  (import "env" "__lang_f_pow" (func $__lang_f_pow (param f64) (param f64) (result f64)))
  (import "env" "__lang_atan2" (func $__lang_atan2 (param f64) (param f64) (result f64)))
  (import "env" "gen_request_id" (func $gen_request_id (result i32)))
  (import "env" "cf_body" (func $cf_body (result i32)))
  (import "env" "cf_on_fetch" (func $cf_on_fetch (param i32)))
  (import "env" "cf_kv_lookup" (func $cf_kv_lookup (result i32)))
  (memory (export "memory") 1024)
  (table 35 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $handler_closure $resp_bad_request_closure $resp_not_found_closure $resp_snippet_found_closure $resp_share_created_closure $resp_landing_closure $json_esc_closure $_json_esc_walk_closure $json_str_field_closure $list_sort_closure $list_sort_by_closure $list_sort_insert_closure $list_min_closure $list_max_closure $list_product_closure $list_sum_closure $range_closure $list_fold_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 1357))
  (global $__lang_char_table i32 (i32.const 845))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (data (i32.const 16) "method\00")
  (data (i32.const 23) "path\00")
  (data (i32.const 28) "GET\00")
  (data (i32.const 32) "/\00")
  (data (i32.const 34) "POST\00")
  (data (i32.const 39) "/share\00")
  (data (i32.const 46) "empty body\0a\00")
  (data (i32.const 58) "/s/\00")
  (data (i32.const 62) "no such snippet\0a\00")
  (data (i32.const 79) "unknown path: \00")
  (data (i32.const 94) "\0a\00")
  (data (i32.const 96) "{\22status\22:400,\00")
  (data (i32.const 111) "\22headers\22:{\22content-type\22:\22text/plain\22},\00")
  (data (i32.const 152) "\22body\22:\22\00")
  (data (i32.const 161) "\22}\00")
  (data (i32.const 164) "{\22status\22:404,\00")
  (data (i32.const 179) "\22headers\22:{\22content-type\22:\22text/plain\22},\00")
  (data (i32.const 220) "\22body\22:\22\00")
  (data (i32.const 229) "\22}\00")
  (data (i32.const 232) "{\22status\22:200,\00")
  (data (i32.const 247) "\22headers\22:{\22content-type\22:\22text/plain; charset=utf-8\22},\00")
  (data (i32.const 303) "\22body\22:\22\00")
  (data (i32.const 312) "\22}\00")
  (data (i32.const 315) "{\22status\22:200,\00")
  (data (i32.const 330) "\22headers\22:{\22content-type\22:\22text/html; charset=utf-8\22},\00")
  (data (i32.const 385) "\22body\22:\22\00")
  (data (i32.const 394) "<!doctype html><title>mere snippet share</title>\00")
  (data (i32.const 443) "<h1>mere snippet share</h1>\00")
  (data (i32.const 471) "<p>POST raw text to <code>/share</code>, get a <code>/s/:id</code> URL back.</p>\00")
  (data (i32.const 552) "<pre>curl -X POST --data-binary 'let x = 1 in x' https://this-worker/share</pre>\00")
  (data (i32.const 633) "\22}\00")
  (data (i32.const 636) "list_min: empty list\00")
  (data (i32.const 657) "list_max: empty list\00")
  (data (i32.const 678) "\22\00")
  (data (i32.const 680) "\22:\22\00")
  (data (i32.const 684) "\00")
  (data (i32.const 685) "\22\00")
  (data (i32.const 687) "\00")
  (data (i32.const 688) "\5c\00")
  (data (i32.const 690) "\5c\5c\00")
  (data (i32.const 693) "\22\00")
  (data (i32.const 695) "\5c\22\00")
  (data (i32.const 698) "\0a\00")
  (data (i32.const 700) "\5cn\00")
  (data (i32.const 703) "\0d\00")
  (data (i32.const 705) "\5cr\00")
  (data (i32.const 708) "\09\00")
  (data (i32.const 710) "\5ct\00")
  (data (i32.const 713) "{\22status\22:201,\00")
  (data (i32.const 728) "\22headers\22:{\22content-type\22:\22application/json\22},\00")
  (data (i32.const 775) "\22body\22:\22\00")
  (data (i32.const 784) "{\22id\22:\22\00")
  (data (i32.const 792) "\22,\22url\22:\22/s/\00")
  (data (i32.const 805) "\22}\00")
  (data (i32.const 808) "\22,\00")
  (data (i32.const 811) "\22kv_put\22:{\22key\22:\22\00")
  (data (i32.const 829) "\22,\22value\22:\22\00")
  (data (i32.const 841) "\22}}\00")

  (func $__lang_strlen (param $s i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (i32.load8_u (i32.add (local.get $s) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $i))
  (func $__lang_str_concat (param $a i32) (param $b i32) (result i32)
    (local $la i32) (local $lb i32) (local $r i32) (local $i i32)
    (local.set $la (call $__lang_strlen (local.get $a)))
    (local.set $lb (call $__lang_strlen (local.get $b)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $la)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $lb)))
        (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $i))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
               (i32.const 1)))
    (local.get $r))
  (func $__lang_streq (param $a i32) (param $b i32) (result i32)
    (local $ba i32) (local $bb i32)
    (block $not_eq
      (loop $lp
        (local.set $ba (i32.load8_u (local.get $a)))
        (local.set $bb (i32.load8_u (local.get $b)))
        (br_if $not_eq (i32.ne (local.get $ba) (local.get $bb)))
        (if (i32.eqz (local.get $ba))
          (then (return (i32.const 1))))
        (local.set $a (i32.add (local.get $a) (i32.const 1)))
        (local.set $b (i32.add (local.get $b) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  ;; Phase 31.0: str_compare — returns -1 / 0 / 1 (sign-normalized, matches
  ;; interp's `compare s t` from OCaml stdlib).
  (func $__lang_str_compare (param $a i32) (param $b i32) (result i32)
    (local $ba i32) (local $bb i32)
    (loop $lp
      (local.set $ba (i32.load8_u (local.get $a)))
      (local.set $bb (i32.load8_u (local.get $b)))
      (if (i32.lt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const -1))))
      (if (i32.gt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const 1))))
      (if (i32.eqz (local.get $ba))
        (then (return (i32.const 0))))
      (local.set $a (i32.add (local.get $a) (i32.const 1)))
      (local.set $b (i32.add (local.get $b) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 19.1.1: str_index_of — returns position of needle in haystack,
  ;; -1 if not found. Empty needle returns 0.
  (func $__lang_str_index_of (param $h i32) (param $n i32) (result i32)
    (local $hlen i32) (local $nlen i32) (local $i i32) (local $j i32)
    (local $match i32)
    (local.set $hlen (call $__lang_strlen (local.get $h)))
    (local.set $nlen (call $__lang_strlen (local.get $n)))
    (if (i32.eqz (local.get $nlen)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        ;; if i + nlen > hlen → not found
        (br_if $end_outer
               (i32.gt_s (i32.add (local.get $i) (local.get $nlen))
                         (local.get $hlen)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nlen)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $h)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match) (then (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.const -1))
  ;; Phase 36: __lang_is_ws — ASCII whitespace test (space/tab/lf/cr/ff)
  (func $__lang_is_ws (param $c i32) (result i32)
    (i32.or
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32))
                (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10))
                (i32.eq (local.get $c) (i32.const 13))))
      (i32.eq (local.get $c) (i32.const 12))))
  ;; Phase 36: str_starts_with — bool (i32 0/1)
  (func $__lang_str_starts_with (param $s i32) (param $p i32) (result i32)
    (local $i i32) (local $cs i32) (local $cp i32)
    (local.set $i (i32.const 0))
    (loop $lp
      (local.set $cp (i32.load8_u (i32.add (local.get $p) (local.get $i))))
      (if (i32.eqz (local.get $cp)) (then (return (i32.const 1))))
      (local.set $cs (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.ne (local.get $cs) (local.get $cp)) (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_trim — strip leading + trailing whitespace
  (func $__lang_str_trim (param $s i32) (result i32)
    (local $p i32) (local $len i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $p (local.get $s))
    ;; skip leading whitespace
    (block $end_lead
      (loop $lp_lead
        (local.set $c (i32.load8_u (local.get $p)))
        (br_if $end_lead (i32.eqz (local.get $c)))
        (br_if $end_lead (i32.eqz (call $__lang_is_ws (local.get $c))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $lp_lead)))
    ;; compute remaining length
    (local.set $len (call $__lang_strlen (local.get $p)))
    ;; trim trailing
    (block $end_trail
      (loop $lp_trail
        (br_if $end_trail (i32.eqz (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $p)
                                            (i32.sub (local.get $len) (i32.const 1)))))
        (br_if $end_trail (i32.eqz (call $__lang_is_ws (local.get $c))))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $lp_trail)))
    ;; copy [p, p+len) to bump
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_copy
      (loop $lp_copy
        (br_if $end_copy (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_copy)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: str_ends_with — bool (i32 0/1)
  (func $__lang_str_ends_with (param $s i32) (param $p i32) (result i32)
    (local $sl i32) (local $pl i32) (local $i i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $pl (call $__lang_strlen (local.get $p)))
    (if (i32.gt_s (local.get $pl) (local.get $sl)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (loop $lp
      (if (i32.eq (local.get $i) (local.get $pl)) (then (return (i32.const 1))))
      (if (i32.ne
            (i32.load8_u (i32.add (i32.add (local.get $s)
                                           (i32.sub (local.get $sl) (local.get $pl)))
                                  (local.get $i)))
            (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_repeat s n
  (func $__lang_str_repeat (param $s i32) (param $n i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $j i32)
    (if (i32.le_s (local.get $n) (i32.const 0))
      (then
        (local.set $r (global.get $__lang_bump))
        (i32.store8 (local.get $r) (i32.const 0))
        (global.set $__lang_bump (i32.add (local.get $r) (i32.const 1)))
        (return (local.get $r))))
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.eq (local.get $i) (local.get $n)))
        (local.set $j (i32.const 0))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $sl)))
            (i32.store8 (i32.add (local.get $r)
                                 (i32.add (i32.mul (local.get $i) (local.get $sl))
                                          (local.get $j)))
                        (i32.load8_u (i32.add (local.get $s) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
               (i32.const 1)))
    (local.get $r))
  ;; Phase 36: str_rev
  (func $__lang_str_rev (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.sub (i32.sub (local.get $sl) (local.get $i))
                                                   (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: chr n — return char_table entry pointer for byte n
  (func $__lang_char_at_chr (param $n i32) (result i32)
    (call $__lang_char_at_setup)
    (i32.add (global.get $__lang_char_table) (i32.mul (local.get $n) (i32.const 2))))
  ;; Phase 36: abs / min / max / clamp
  (func $__lang_abs (param $n i32) (result i32)
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (return (i32.sub (i32.const 0) (local.get $n)))))
    (local.get $n))
  (func $__lang_min (param $a i32) (param $b i32) (result i32)
    (if (i32.lt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_max (param $a i32) (param $b i32) (result i32)
    (if (i32.gt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_clamp (param $lo i32) (param $hi i32) (param $x i32) (result i32)
    (if (i32.lt_s (local.get $x) (local.get $lo))
      (then (return (local.get $lo))))
    (if (i32.gt_s (local.get $x) (local.get $hi))
      (then (return (local.get $hi))))
    (local.get $x))
  ;; Phase 36: to_upper / to_lower — ASCII case conversion
  (func $__lang_to_upper (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97))
                     (i32.le_u (local.get $c) (i32.const 122)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  (func $__lang_to_lower (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 65))
                     (i32.le_u (local.get $c) (i32.const 90)))
          (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: gcd via iterative Euclid on |a|, |b|
  (func $__lang_gcd (param $a0 i32) (param $b0 i32) (result i32)
    (local $a i32) (local $b i32) (local $t i32)
    (local.set $a (local.get $a0))
    (local.set $b (local.get $b0))
    (if (i32.lt_s (local.get $a) (i32.const 0))
      (then (local.set $a (i32.sub (i32.const 0) (local.get $a)))))
    (if (i32.lt_s (local.get $b) (i32.const 0))
      (then (local.set $b (i32.sub (i32.const 0) (local.get $b)))))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (local.get $b)))
        (local.set $t (local.get $b))
        (local.set $b (i32.rem_s (local.get $a) (local.get $b)))
        (local.set $a (local.get $t))
        (br $lp)))
    (local.get $a))
  ;; Phase 36: bool_of_str — "true" → 1, otherwise → 0
  (func $__lang_bool_of_str (param $s i32) (result i32)
    (if (i32.ne (i32.load8_u (local.get $s)) (i32.const 116)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.const 114)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.const 117)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 3))) (i32.const 101)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 4))) (i32.const 0)) (then (return (i32.const 0))))
    (i32.const 1))
  ;; Phase 36: str_replace s old new — replace all non-overlapping occurrences
  (func $__lang_str_replace (param $s i32) (param $old i32) (param $new i32) (result i32)
    (local $slen i32) (local $olen i32) (local $nlen i32)
    (local $r i32) (local $bi i32) (local $i i32) (local $j i32) (local $match i32)
    (local.set $olen (call $__lang_strlen (local.get $old)))
    (if (i32.eqz (local.get $olen)) (then (return (local.get $s))))
    (local.set $slen (call $__lang_strlen (local.get $s)))
    (local.set $nlen (call $__lang_strlen (local.get $new)))
    (local.set $r (global.get $__lang_bump))
    (local.set $bi (i32.const 0))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $slen)))
        ;; check if remainder fits old
        (if (i32.le_s (i32.add (local.get $i) (local.get $olen)) (local.get $slen))
          (then
            (local.set $j (i32.const 0))
            (local.set $match (i32.const 1))
            (block $end_inner
              (loop $lp_inner
                (br_if $end_inner (i32.eq (local.get $j) (local.get $olen)))
                (if (i32.ne (i32.load8_u (i32.add (local.get $s)
                                                  (i32.add (local.get $i) (local.get $j))))
                            (i32.load8_u (i32.add (local.get $old) (local.get $j))))
                  (then (local.set $match (i32.const 0)) (br $end_inner)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $lp_inner)))
            (if (local.get $match)
              (then
                ;; copy new
                (local.set $j (i32.const 0))
                (block $end_cn
                  (loop $lp_cn
                    (br_if $end_cn (i32.eq (local.get $j) (local.get $nlen)))
                    (i32.store8 (i32.add (local.get $r) (i32.add (local.get $bi) (local.get $j)))
                                (i32.load8_u (i32.add (local.get $new) (local.get $j))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $lp_cn)))
                (local.set $bi (i32.add (local.get $bi) (local.get $nlen)))
                (local.set $i (i32.add (local.get $i) (local.get $olen)))
                (br $lp_outer)))))
        ;; no match — copy one char
        (i32.store8 (i32.add (local.get $r) (local.get $bi))
                    (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $bi (i32.add (local.get $bi) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (local.get $bi)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $bi)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.1/26.2: fail msg — if a try_or scope is active, set the
  ;; failure flag and return 0 (the caller's expected result type is i32
  ;; for everything in Wasm). Otherwise print + trap. The flag /
  ;; active-counter globals are declared at module level.
  (func $__lang_fail (param $msg i32) (result i32)
    (if (global.get $__lang_fail_active)
      (then
        (global.set $__lang_fail_flag (i32.const 1))
        (return (i32.const 0))))
    (call $puts (local.get $msg))
    (unreachable))
  ;; Phase 26.1: char_at s i — return pointer to a single-byte string
  ;; (preallocated 256-entry static char_table). Mirrors C/LLVM.
  ;; The table itself is set up at module-init by storing 256 pairs of
  ;; (char, \0) starting at the global offset $__lang_char_table.
  (func $__lang_char_at_setup
    (local $k i32) (local $base i32)
    (if (i32.eqz (global.get $__lang_char_table_initialized))
      (then
        (global.set $__lang_char_table_initialized (i32.const 1))
        (local.set $base (global.get $__lang_char_table))
        (local.set $k (i32.const 0))
        (block $end
          (loop $lp
            (br_if $end (i32.eq (local.get $k) (i32.const 256)))
            (i32.store8 (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2)))
                        (local.get $k))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2))) (i32.const 1))
                        (i32.const 0))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $lp))))))
  (func $__lang_char_at (param $s i32) (param $i i32) (result i32)
    (call $__lang_char_at_setup)
    (i32.add (global.get $__lang_char_table)
             (i32.mul (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 2))))
  (func $__lang_is_digit (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.and (i32.ge_s (local.get $c) (i32.const 48))
             (i32.le_s (local.get $c) (i32.const 57))))
  (func $__lang_is_alpha (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.or
      (i32.and (i32.ge_s (local.get $c) (i32.const 97))
               (i32.le_s (local.get $c) (i32.const 122)))
      (i32.and (i32.ge_s (local.get $c) (i32.const 65))
               (i32.le_s (local.get $c) (i32.const 90)))))
  (func $__lang_is_space (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.or
      (i32.or (i32.eq (local.get $c) (i32.const 32))
              (i32.eq (local.get $c) (i32.const 9)))
      (i32.or (i32.eq (local.get $c) (i32.const 10))
              (i32.eq (local.get $c) (i32.const 13)))))
  ;; Phase 26.1: substring s start end_ — region alloc + memcpy.
  (func $__lang_substring (param $s i32) (param $start i32) (param $end_ i32) (result i32)
    (local $len i32) (local $r i32) (local $i i32)
    (local.set $len (i32.sub (local.get $end_) (local.get $start)))
    (if (i32.lt_s (local.get $len) (i32.const 0))
      (then (local.set $len (i32.const 0))))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.add (local.get $start) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.1: int_of_str s — parse leading sign + digits. Stops at
  ;; first non-digit byte. Mirrors atoi semantics.
  (func $__lang_int_of_str (param $s i32) (result i32)
    (local $i i32) (local $sign i32) (local $acc i32) (local $c i32)
    (local.set $i (i32.const 0))
    (local.set $sign (i32.const 1))
    (local.set $acc (i32.const 0))
    (local.set $c (i32.load8_u (local.get $s)))
    (if (i32.eq (local.get $c) (i32.const 45))  ;; '-'
      (then
        (local.set $sign (i32.const -1))
        (local.set $i (i32.const 1))))
    (block $end
      (loop $lp
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $end (i32.eqz (local.get $c)))
        (br_if $end (i32.or
          (i32.lt_s (local.get $c) (i32.const 48))
          (i32.gt_s (local.get $c) (i32.const 57))))
        (local.set $acc (i32.add
          (i32.mul (local.get $acc) (i32.const 10))
          (i32.sub (local.get $c) (i32.const 48))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.mul (local.get $acc) (local.get $sign)))
  ;; Phase 26.1: str_unescape s — replace backslash-escape sequences
  ;; (\n, \t, \r, \\ , \", \/) with the actual byte. Region-allocated.
  (func $__lang_str_unescape (param $s i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32)
    (local $c i32) (local $ec i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and
              (i32.eq (local.get $c) (i32.const 92))  ;; '\\'
              (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)))
          (then
            (local.set $ec (i32.load8_u (i32.add (local.get $s) (i32.add (local.get $i) (i32.const 1)))))
            (if (i32.eq (local.get $ec) (i32.const 110))      ;; 'n'
              (then (local.set $ec (i32.const 10)))
              (else (if (i32.eq (local.get $ec) (i32.const 116))  ;; 't'
                (then (local.set $ec (i32.const 9)))
                (else (if (i32.eq (local.get $ec) (i32.const 114))  ;; 'r'
                  (then (local.set $ec (i32.const 13))))))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec))
            (local.set $i (i32.add (local.get $i) (i32.const 2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.6: str_escape s — backslash-escape newline / tab / cr / backslash
  ;; / quote. show_str pipes through this so output matches interp. Worst-case
  ;; 2x byte expansion, region-allocated.
  (func $__lang_str_escape (param $s i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32) (local $c i32) (local $ec i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        ;; if c is special (10/9/13/92/34), emit backslash + replacement
        (if (i32.or
              (i32.or (i32.eq (local.get $c) (i32.const 10))
                      (i32.eq (local.get $c) (i32.const 9)))
              (i32.or (i32.or (i32.eq (local.get $c) (i32.const 13))
                              (i32.eq (local.get $c) (i32.const 92)))
                      (i32.eq (local.get $c) (i32.const 34))))
          (then
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (local.set $ec (local.get $c))
            (if (i32.eq (local.get $c) (i32.const 10))
              (then (local.set $ec (i32.const 110))))
            (if (i32.eq (local.get $c) (i32.const 9))
              (then (local.set $ec (i32.const 116))))
            (if (i32.eq (local.get $c) (i32.const 13))
              (then (local.set $ec (i32.const 114))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec)))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (local.get $r))
  (func $mere_strbuf_new (result i32)
    (local $sb i32) (local $buf i32)
    (local.set $sb (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $sb) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $sb) (local.get $buf))
    (i32.store offset=4 (local.get $sb) (i32.const 0))
    (i32.store offset=8 (local.get $sb) (i32.const 16))
    (local.get $sb))
  (func $mere_strbuf_push (param $sb i32) (param $s i32) (result i32)
    (local $slen i32) (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local.set $slen (call $__lang_strlen (local.get $s)))
    (block $resize_end
      (loop $resize_lp
        (local.set $len (i32.load offset=4 (local.get $sb)))
        (local.set $cap (i32.load offset=8 (local.get $sb)))
        (br_if $resize_end
          (i32.le_s (i32.add (local.get $len) (local.get $slen))
                    (local.get $cap)))
        ;; grow
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf) (local.get $cap)))
        (local.set $buf (i32.load offset=0 (local.get $sb)))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store8
              (i32.add (local.get $new_buf) (local.get $i))
              (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $sb) (local.get $new_buf))
        (i32.store offset=8 (local.get $sb) (local.get $cap))
        (br $resize_lp)))
    ;; copy s into the buffer at offset len
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $i (i32.const 0))
    (block $cp2_end
      (loop $cp2_lp
        (br_if $cp2_end (i32.eq (local.get $i) (local.get $slen)))
        (i32.store8
          (i32.add (i32.add (local.get $buf) (local.get $len)) (local.get $i))
          (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp2_lp)))
    (i32.store offset=4 (local.get $sb)
      (i32.add (local.get $len) (local.get $slen)))
    (i32.const 0))
  (func $mere_strbuf_to_str (param $sb i32) (result i32)
    (local $len i32) (local $out i32) (local $buf i32) (local $i i32)
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    (local.set $out (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (local.get $out) (i32.add (local.get $len) (i32.const 1))))
    (local.set $i (i32.const 0))
    (block $cp_end
      (loop $cp_lp
        (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (local.get $out) (local.get $i))
          (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp_lp)))
    (i32.store8 (i32.add (local.get $out) (local.get $len)) (i32.const 0))
    (local.get $out))
  (func $mere_strbuf_len (param $sb i32) (result i32)
    (i32.load offset=4 (local.get $sb)))  (func $handler (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    call $json_str_field
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 16
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 0
    call $json_str_field
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 23
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 1
    i32.const 28
    call $__lang_streq
    local.get 3
    i32.const 32
    call $__lang_streq
    i32.and
    if (result i32)
    i32.const 0
    return_call $resp_landing
    else
    local.get 1
    i32.const 34
    call $__lang_streq
    local.get 3
    i32.const 39
    call $__lang_streq
    i32.and
    if (result i32)
    call $cf_body
    local.set 5
    local.get 5
    call $__lang_strlen
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 46
    return_call $resp_bad_request
    else
    call $gen_request_id
    i32.const 0
    i32.const 8
    call $__lang_substring
    local.set 6
    local.get 6
    call $resp_share_created
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 5
    local.get 7
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    else
    local.get 3
    i32.const 58
    call $__lang_str_starts_with
    if (result i32)
    call $cf_kv_lookup
    local.set 8
    local.get 8
    call $__lang_strlen
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 62
    return_call $resp_not_found
    else
    local.get 8
    return_call $resp_snippet_found
    end
    else
    i32.const 79
    local.get 3
    call $__lang_str_concat
    i32.const 94
    call $__lang_str_concat
    return_call $resp_not_found
    end
    end
    end)
  (func $resp_bad_request (param i32) (result i32)
    i32.const 96
    i32.const 111
    call $__lang_str_concat
    i32.const 152
    call $__lang_str_concat
    local.get 0
    call $json_esc
    call $__lang_str_concat
    i32.const 161
    call $__lang_str_concat)
  (func $resp_not_found (param i32) (result i32)
    i32.const 164
    i32.const 179
    call $__lang_str_concat
    i32.const 220
    call $__lang_str_concat
    local.get 0
    call $json_esc
    call $__lang_str_concat
    i32.const 229
    call $__lang_str_concat)
  (func $resp_snippet_found (param i32) (result i32)
    i32.const 232
    i32.const 247
    call $__lang_str_concat
    i32.const 303
    call $__lang_str_concat
    local.get 0
    call $json_esc
    call $__lang_str_concat
    i32.const 312
    call $__lang_str_concat)
  (func $resp_share_created (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 18
    i32.store offset=4
    local.get 2)
  (func $resp_landing (param i32) (result i32)
    i32.const 315
    i32.const 330
    call $__lang_str_concat
    i32.const 385
    call $__lang_str_concat
    i32.const 394
    i32.const 443
    call $__lang_str_concat
    i32.const 471
    call $__lang_str_concat
    i32.const 552
    call $__lang_str_concat
    call $json_esc
    call $__lang_str_concat
    i32.const 633
    call $__lang_str_concat)
  (func $json_esc (param i32) (result i32)
    (local i32 i32 i32 i32)
    call $mere_strbuf_new
    local.set 1
    local.get 0
    call $_json_esc_walk
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.load offset=0
    local.get 0
    call $__lang_strlen
    local.get 2
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_json_esc_walk (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 19
    i32.store offset=4
    local.get 2)
  (func $json_str_field (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 20
    i32.store offset=4
    local.get 2)
  (func $list_sort (param i32) (result i32)
    (local i32 i32 i32)
    i32.const 0
    local.set 2
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i32.store offset=0
    local.get 3
    i32.const 21
    i32.store offset=4
    local.get 3
    call $list_sort_by
    local.set 1
    local.get 1
    i32.load offset=0
    local.get 0
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $list_sort_by (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 22
    i32.store offset=4
    local.get 2)
  (func $list_sort_insert (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 23
    i32.store offset=4
    local.get 2)
  (func $list_min (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 2
    local.get 2
    if (result i32)
    i32.const 636
    call $__lang_fail
    else
    local.get 1
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 3
    local.get 3
    if (result i32)
    local.get 1
    i32.load offset=4
    local.set 4
    local.get 4
    i32.load offset=0
    local.set 6
    i32.const 1
    local.set 7
    local.get 4
    i32.load offset=4
    local.set 8
    i32.const 1
    local.set 9
    i32.const 1
    local.set 10
    local.get 10
    local.get 7
    i32.and
    local.set 11
    local.get 11
    local.get 9
    i32.and
    local.set 12
    local.get 12
    else
    i32.const 0
    end
    local.set 5
    local.get 5
    if (result i32)
    local.get 8
    local.set 13
    local.get 13
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 14
    local.get 14
    if (result i32)
    local.get 6
    else
    local.get 13
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 15
    local.get 15
    if (result i32)
    local.get 13
    i32.load offset=4
    local.set 16
    i32.const 1
    local.set 18
    local.get 18
    else
    i32.const 0
    end
    local.set 17
    local.get 17
    if (result i32)
    local.get 8
    call $list_min
    local.set 19
    local.get 6
    local.get 19
    i32.lt_s
    if (result i32)
    local.get 6
    else
    local.get 19
    end
    else
    unreachable
    end
    end
    else
    unreachable
    end
    end)
  (func $list_max (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 2
    local.get 2
    if (result i32)
    i32.const 657
    call $__lang_fail
    else
    local.get 1
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 3
    local.get 3
    if (result i32)
    local.get 1
    i32.load offset=4
    local.set 4
    local.get 4
    i32.load offset=0
    local.set 6
    i32.const 1
    local.set 7
    local.get 4
    i32.load offset=4
    local.set 8
    i32.const 1
    local.set 9
    i32.const 1
    local.set 10
    local.get 10
    local.get 7
    i32.and
    local.set 11
    local.get 11
    local.get 9
    i32.and
    local.set 12
    local.get 12
    else
    i32.const 0
    end
    local.set 5
    local.get 5
    if (result i32)
    local.get 8
    local.set 13
    local.get 13
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 14
    local.get 14
    if (result i32)
    local.get 6
    else
    local.get 13
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 15
    local.get 15
    if (result i32)
    local.get 13
    i32.load offset=4
    local.set 16
    i32.const 1
    local.set 18
    local.get 18
    else
    i32.const 0
    end
    local.set 17
    local.get 17
    if (result i32)
    local.get 8
    call $list_max
    local.set 19
    local.get 6
    local.get 19
    i32.gt_s
    if (result i32)
    local.get 6
    else
    local.get 19
    end
    else
    unreachable
    end
    end
    else
    unreachable
    end
    end)
  (func $list_product (param i32) (result i32)
    (local i32 i32 i32 i32)
    local.get 0
    call $list_fold
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 1
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    local.set 3
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 3
    i32.store offset=0
    local.get 4
    i32.const 24
    i32.store offset=4
    local.get 4
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $list_sum (param i32) (result i32)
    (local i32 i32 i32 i32)
    local.get 0
    call $list_fold
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 0
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    local.set 3
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 3
    i32.store offset=0
    local.get 4
    i32.const 25
    i32.store offset=4
    local.get 4
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $range (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 26
    i32.store offset=4
    local.get 2)
  (func $list_fold (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    local.get 2
    i32.const 27
    i32.store offset=4
    local.get 2)
  (func $handler_closure (param i32) (param i32) (result i32)
    local.get 1
    call $handler)
  (func $resp_bad_request_closure (param i32) (param i32) (result i32)
    local.get 1
    call $resp_bad_request)
  (func $resp_not_found_closure (param i32) (param i32) (result i32)
    local.get 1
    call $resp_not_found)
  (func $resp_snippet_found_closure (param i32) (param i32) (result i32)
    local.get 1
    call $resp_snippet_found)
  (func $resp_share_created_closure (param i32) (param i32) (result i32)
    local.get 1
    call $resp_share_created)
  (func $resp_landing_closure (param i32) (param i32) (result i32)
    local.get 1
    call $resp_landing)
  (func $json_esc_closure (param i32) (param i32) (result i32)
    local.get 1
    call $json_esc)
  (func $_json_esc_walk_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_json_esc_walk)
  (func $json_str_field_closure (param i32) (param i32) (result i32)
    local.get 1
    call $json_str_field)
  (func $list_sort_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_sort)
  (func $list_sort_by_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_sort_by)
  (func $list_sort_insert_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_sort_insert)
  (func $list_min_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_min)
  (func $list_max_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_max)
  (func $list_product_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_product)
  (func $list_sum_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_sum)
  (func $range_closure (param i32) (param i32) (result i32)
    local.get 1
    call $range)
  (func $list_fold_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_fold)
  (func $anon_9_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i32.store offset=0
    local.get 3
    local.get 1
    i32.store offset=4
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 3
    i32.store offset=0
    local.get 4
    i32.const 28
    i32.store offset=4
    local.get 4)
  (func $anon_10_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 5
    local.get 5
    if (result i32)
    local.get 3
    else
    local.get 4
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 6
    local.get 6
    if (result i32)
    local.get 4
    i32.load offset=4
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 9
    i32.const 1
    local.set 10
    local.get 7
    i32.load offset=4
    local.set 11
    i32.const 1
    local.set 12
    i32.const 1
    local.set 13
    local.get 13
    local.get 10
    i32.and
    local.set 14
    local.get 14
    local.get 12
    i32.and
    local.set 15
    local.get 15
    else
    i32.const 0
    end
    local.set 8
    local.get 8
    if (result i32)
    local.get 11
    call $list_fold
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 1
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 3
    local.get 19
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.load offset=0
    local.get 9
    local.get 18
    i32.load offset=4
    call_indirect (type $cl)
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.load offset=0
    local.get 1
    local.get 16
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_8_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.gt_s
    if (result i32)
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    i32.const 0
    i32.store offset=0
    local.get 3
    else
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    i32.const 1
    i32.store offset=0
    local.get 4
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 2
    i32.store offset=0
    local.get 5
    local.get 2
    i32.const 1
    i32.add
    call $range
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 1
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=4
    local.get 5
    i32.store offset=4
    local.get 4
    end)
  (func $anon_7_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i32.store offset=0
    local.get 3
    i32.const 29
    i32.store offset=4
    local.get 3)
  (func $anon_11_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.add)
  (func $anon_6_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i32.store offset=0
    local.get 3
    i32.const 30
    i32.store offset=4
    local.get 3)
  (func $anon_12_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.mul)
  (func $anon_5_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i32.store offset=0
    local.get 3
    local.get 2
    i32.store offset=4
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 3
    i32.store offset=0
    local.get 4
    i32.const 31
    i32.store offset=4
    local.get 4)
  (func $anon_13_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 5
    local.get 5
    if (result i32)
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 6
    i32.const 1
    i32.store offset=0
    local.get 6
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 1
    i32.store offset=0
    local.get 7
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 8
    i32.const 0
    i32.store offset=0
    local.get 8
    i32.store offset=4
    local.get 7
    i32.store offset=4
    local.get 6
    else
    local.get 4
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 9
    local.get 9
    if (result i32)
    local.get 4
    i32.load offset=4
    local.set 10
    local.get 10
    i32.load offset=0
    local.set 12
    i32.const 1
    local.set 13
    local.get 10
    i32.load offset=4
    local.set 14
    i32.const 1
    local.set 15
    i32.const 1
    local.set 16
    local.get 16
    local.get 13
    i32.and
    local.set 17
    local.get 17
    local.get 15
    i32.and
    local.set 18
    local.get 18
    else
    i32.const 0
    end
    local.set 11
    local.get 11
    if (result i32)
    local.get 3
    local.set 20
    local.get 20
    i32.load offset=0
    local.get 1
    local.get 20
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 12
    local.get 19
    i32.load offset=4
    call_indirect (type $cl)
    if (result i32)
    global.get $__lang_bump
    local.set 21
    local.get 21
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 21
    i32.const 1
    i32.store offset=0
    local.get 21
    global.get $__lang_bump
    local.set 22
    local.get 22
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 22
    local.get 1
    i32.store offset=0
    local.get 22
    local.get 2
    i32.store offset=4
    local.get 22
    i32.store offset=4
    local.get 21
    else
    global.get $__lang_bump
    local.set 23
    local.get 23
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 23
    i32.const 1
    i32.store offset=0
    local.get 23
    global.get $__lang_bump
    local.set 24
    local.get 24
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 24
    local.get 12
    i32.store offset=0
    local.get 24
    local.get 3
    call $list_sort_insert
    local.set 26
    local.get 26
    i32.load offset=0
    local.get 14
    local.get 26
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.load offset=0
    local.get 1
    local.get 25
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=4
    local.get 24
    i32.store offset=4
    local.get 23
    end
    else
    unreachable
    end
    end)
  (func $anon_4_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 4
    local.get 4
    if (result i32)
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 5
    i32.const 0
    i32.store offset=0
    local.get 5
    else
    local.get 3
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 6
    local.get 6
    if (result i32)
    local.get 3
    i32.load offset=4
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 9
    i32.const 1
    local.set 10
    local.get 7
    i32.load offset=4
    local.set 11
    i32.const 1
    local.set 12
    i32.const 1
    local.set 13
    local.get 13
    local.get 10
    i32.and
    local.set 14
    local.get 14
    local.get 12
    i32.and
    local.set 15
    local.get 15
    else
    i32.const 0
    end
    local.set 8
    local.get 8
    if (result i32)
    local.get 2
    call $list_sort_insert
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 2
    call $list_sort_by
    local.set 18
    local.get 18
    i32.load offset=0
    local.get 11
    local.get 18
    i32.load offset=4
    call_indirect (type $cl)
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.load offset=0
    local.get 9
    local.get 16
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_3_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 4
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i32.store offset=0
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i32.store offset=0
    local.get 3
    i32.const 32
    i32.store offset=4
    local.get 3)
  (func $anon_14_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.lt_s)
  (func $anon_2_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    i32.const 678
    local.get 1
    call $__lang_str_concat
    i32.const 680
    call $__lang_str_concat
    local.set 3
    local.get 2
    local.get 3
    call $__lang_str_index_of
    local.set 4
    local.get 4
    i32.const 0
    i32.lt_s
    if (result i32)
    i32.const 684
    else
    local.get 2
    local.get 4
    local.get 3
    call $__lang_strlen
    i32.add
    local.get 2
    call $__lang_strlen
    call $__lang_substring
    local.set 5
    local.get 5
    i32.const 685
    call $__lang_str_index_of
    local.set 6
    local.get 6
    i32.const 0
    i32.lt_s
    if (result i32)
    i32.const 687
    else
    local.get 5
    i32.const 0
    local.get 6
    call $__lang_substring
    end
    end)
  (func $anon_1_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i32.store offset=0
    local.get 3
    local.get 2
    i32.store offset=4
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 3
    i32.store offset=0
    local.get 4
    i32.const 33
    i32.store offset=4
    local.get 4)
  (func $anon_15_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 1
    i32.store offset=0
    local.get 4
    local.get 2
    i32.store offset=4
    local.get 4
    local.get 3
    i32.store offset=8
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 4
    i32.store offset=0
    local.get 5
    i32.const 34
    i32.store offset=4
    local.get 5)
  (func $anon_16_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    local.get 2
    local.get 1
    i32.ge_s
    if (result i32)
    local.get 3
    call $mere_strbuf_to_str
    else
    local.get 4
    local.get 2
    call $__lang_char_at
    local.set 5
    local.get 5
    i32.const 688
    call $__lang_streq
    if (result i32)
    local.get 3
    i32.const 690
    call $mere_strbuf_push
    drop
    i32.const 0
    else
    local.get 5
    i32.const 693
    call $__lang_streq
    if (result i32)
    local.get 3
    i32.const 695
    call $mere_strbuf_push
    drop
    i32.const 0
    else
    local.get 5
    i32.const 698
    call $__lang_streq
    if (result i32)
    local.get 3
    i32.const 700
    call $mere_strbuf_push
    drop
    i32.const 0
    else
    local.get 5
    i32.const 703
    call $__lang_streq
    if (result i32)
    local.get 3
    i32.const 705
    call $mere_strbuf_push
    drop
    i32.const 0
    else
    local.get 5
    i32.const 708
    call $__lang_streq
    if (result i32)
    local.get 3
    i32.const 710
    call $mere_strbuf_push
    drop
    i32.const 0
    else
    local.get 3
    local.get 5
    call $mere_strbuf_push
    drop
    i32.const 0
    end
    end
    end
    end
    end
    drop
    local.get 4
    call $_json_esc_walk
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 3
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 1
    local.get 6
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
  (func $anon_0_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    i32.const 713
    i32.const 728
    call $__lang_str_concat
    i32.const 775
    call $__lang_str_concat
    i32.const 784
    local.get 2
    call $__lang_str_concat
    i32.const 792
    call $__lang_str_concat
    local.get 2
    call $__lang_str_concat
    i32.const 805
    call $__lang_str_concat
    call $json_esc
    call $__lang_str_concat
    i32.const 808
    call $__lang_str_concat
    i32.const 811
    call $__lang_str_concat
    local.get 2
    call $__lang_str_concat
    i32.const 829
    call $__lang_str_concat
    local.get 1
    call $json_esc
    call $__lang_str_concat
    i32.const 841
    call $__lang_str_concat)
  (func $show_int (param $n i32) (result i32)
    (local $buf i32) (local $i i32) (local $abs i32) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 16)))
    (local.set $i (i32.const 15))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $abs (i32.sub (i32.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i32.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (i32.add (local.get $buf) (local.get $i)))))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48) (i32.rem_u (local.get $abs) (i32.const 10))))
        (local.set $abs (i32.div_u (local.get $abs) (i32.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (i32.add (local.get $buf) (local.get $i)))
  (func $main (export "main") (result i32)
    (local i32)
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 0
    local.get 0
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 0
    i32.const 0
    i32.store offset=0
    local.get 0
    i32.const 0
    i32.store offset=4
    local.get 0
    call $cf_on_fetch
    i32.const 0
    drop
    i32.const 0
    call $show_int
    call $puts
    i32.const 0)
)

