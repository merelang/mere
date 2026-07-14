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
  (import "env" "dom_get_by_id" (func $dom_get_by_id (param i32) (result i32)))
  (import "env" "dom_input_value" (func $dom_input_value (param i32) (result i32)))
  (import "env" "dom_on_key" (func $dom_on_key (param i32)))
  (import "env" "dom_on_click" (func $dom_on_click (param i32) (param i32)))
  (import "env" "dom_set_text" (func $dom_set_text (param i32) (param i32)))
  (memory (export "memory") 1024)
  (table 71 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $init_closure $handle_closure $redraw_closure $render_closure $cell_closure $stuck_closure $any_adj_closure $has_val_closure $spawn_tile_closure $place_kth_closure $count_empty_closure $next_rand_closure $eq_list_closure $snap_closure $move_closure $do_line_closure $put_line_closure $get_line_closure $bset_closure $bget_closure $reverse_closure $rev_go_closure $slide_closure $pad_closure $merge_closure $compress_closure $list_sort_closure $list_sort_by_closure $list_sort_insert_closure $list_min_closure $list_max_closure $list_product_closure $list_sum_closure $range_closure $list_fold_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn $anon_17_fn $anon_18_fn $anon_19_fn $anon_20_fn $anon_21_fn $anon_22_fn $anon_23_fn $anon_24_fn $anon_25_fn $anon_26_fn $anon_27_fn $anon_28_fn $anon_29_fn $anon_30_fn $anon_31_fn $anon_32_fn $anon_33_fn $anon_34_fn $anon_35_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 702))
  (global $__lang_char_table i32 (i32.const 190))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (global $board (mut i32) (i32.const 0))
  (global $st (mut i32) (i32.const 0))
  (global $screen (mut i32) (i32.const 0))
  (data (i32.const 16) "ArrowLeft\00")
  (data (i32.const 26) "L\00")
  (data (i32.const 28) "ArrowRight\00")
  (data (i32.const 39) "R\00")
  (data (i32.const 41) "ArrowUp\00")
  (data (i32.const 49) "U\00")
  (data (i32.const 51) "ArrowDown\00")
  (data (i32.const 61) "D\00")
  (data (i32.const 63) "\00")
  (data (i32.const 64) "\00")
  (data (i32.const 65) "  *** you win! ***\00")
  (data (i32.const 84) "  --- game over ---\00")
  (data (i32.const 104) "  (arrow keys)\00")
  (data (i32.const 119) "\0a\00")
  (data (i32.const 121) "\0a\00")
  (data (i32.const 123) "\0a\00")
  (data (i32.const 125) "\0a\00")
  (data (i32.const 127) ".\00")
  (data (i32.const 129) "list_min: empty list\00")
  (data (i32.const 150) "list_max: empty list\00")
  (data (i32.const 171) " \00")
  (data (i32.const 173) "()\00")
  (data (i32.const 176) "board\00")
  (data (i32.const 182) "L\00")
  (data (i32.const 184) "R\00")
  (data (i32.const 186) "U\00")
  (data (i32.const 188) "D\00")

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
  ;; Phase 36: chr n — return char_table entry pointer for byte n.
  ;; Mask to a single byte (n & 0xFF) so out-of-range input can't index
  ;; past the 256-entry table into adjacent memory. Matches the C backend
  ;; ((unsigned char)n) and the self-host $chr (i32.store8 truncation).
  (func $__lang_char_at_chr (param $n i32) (result i32)
    (call $__lang_char_at_setup)
    (i32.add (global.get $__lang_char_table)
      (i32.mul (i32.and (local.get $n) (i32.const 255)) (i32.const 2))))
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
  (func $mere_vec_new (result i32)
    (local $v i32) (local $buf i32)
    (local.set $v (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $v) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $v) (local.get $buf))
    (i32.store offset=4 (local.get $v) (i32.const 0))
    (i32.store offset=8 (local.get $v) (i32.const 4))
    (local.get $v))
  (func $mere_vec_push (param $v i32) (param $x i32) (result i32)
    (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $cap (i32.load offset=8 (local.get $v)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $buf (i32.load offset=0 (local.get $v)))
        (local.set $i (i32.const 0))
        (block $copy_end
          (loop $copy_lp
            (br_if $copy_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_buf)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load
                (i32.add (local.get $buf)
                         (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $copy_lp)))
        (i32.store offset=0 (local.get $v) (local.get $new_buf))
        (i32.store offset=8 (local.get $v) (local.get $cap))))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.store
      (i32.add (local.get $buf)
               (i32.mul (local.get $len) (i32.const 4)))
      (local.get $x))
    (i32.store offset=4 (local.get $v) (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_vec_get (param $v i32) (param $i i32) (result i32)
    (local $len i32) (local $buf i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.load
      (i32.add (local.get $buf)
               (i32.mul (local.get $i) (i32.const 4)))))
  (func $mere_vec_len (param $v i32) (result i32)
    (i32.load offset=4 (local.get $v)))
  (func $mere_vec_set (param $v i32) (param $i i32) (param $x i32) (result i32)
    (local $len i32) (local $buf i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.store
      (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 4)))
      (local.get $x))
    (i32.const 0))
  ;; Phase 15.7: OwnedVec helpers — in Wasm all values are i32 and the
  ;; bump allocator is also shared, so the runtime representations of Vec
  ;; and OwnedVec are the same. owned_vec_* aliases as a thin wrapper to
  ;; $mere_vec_*. Deep copy (vec_to_owned / owned_vec_to_vec) uses $mere_vec_clone.
  (func $mere_vec_clone (param $src i32) (result i32)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local.set $new (call $mere_vec_new))
    (local.set $len (i32.load offset=4 (local.get $src)))
    (local.set $buf (i32.load offset=0 (local.get $src)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop (call $mere_vec_push
                 (local.get $new)
                 (i32.load (i32.add (local.get $buf)
                                    (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $new))
  ;; Phase 19.3: vec_reverse — in-place swap, returns 0 (unit).
  (func $mere_vec_reverse (param $v i32) (result i32)
    (local $lo i32) (local $hi i32) (local $buf i32) (local $tmp i32)
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $lo (i32.const 0))
    (local.set $hi (i32.sub (i32.load offset=4 (local.get $v)) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $lo) (local.get $hi)))
        (local.set $tmp (i32.load
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 4)))))
        (i32.store
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 4)))
          (i32.load (i32.add (local.get $buf)
                             (i32.mul (local.get $hi) (i32.const 4)))))
        (i32.store
          (i32.add (local.get $buf) (i32.mul (local.get $hi) (i32.const 4)))
          (local.get $tmp))
        (local.set $lo (i32.add (local.get $lo) (i32.const 1)))
        (local.set $hi (i32.sub (local.get $hi) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  ;; Phase 19.3: vec_sort — in-place insertion sort.
  ;; cmp: closure_T_(closure_T_int). outer_fn(env, a) → inner closure_T_int,
  ;; inner_fn(inner.env, b) → i32 (negative/0/positive).
  (func $mere_vec_sort (param $v i32) (param $cmp i32) (result i32)
    (local $i i32) (local $j i32) (local $len i32) (local $buf i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $key i32) (local $j_val i32)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32)
    (local $cmp_res i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (local.get $cmp)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cmp)))
    (local.set $i (i32.const 1))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $key (i32.load
          (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $j (i32.sub (local.get $i) (i32.const 1)))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.lt_s (local.get $j) (i32.const 0)))
            (local.set $j_val (i32.load
              (i32.add (local.get $buf) (i32.mul (local.get $j) (i32.const 4)))))
            (local.set $inner_cl
              (call_indirect (type $cl)
                (local.get $outer_env) (local.get $j_val) (local.get $outer_fn)))
            (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
            (local.set $inner_fn  (i32.load offset=4 (local.get $inner_cl)))
            (local.set $cmp_res
              (call_indirect (type $cl)
                (local.get $inner_env) (local.get $key) (local.get $inner_fn)))
            (br_if $end_inner (i32.le_s (local.get $cmp_res) (i32.const 0)))
            ;; shift: data[j+1] = data[j]
            (i32.store
              (i32.add (local.get $buf)
                       (i32.mul (i32.add (local.get $j) (i32.const 1))
                                (i32.const 4)))
              (local.get $j_val))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        ;; place key at j+1
        (i32.store
          (i32.add (local.get $buf)
                   (i32.mul (i32.add (local.get $j) (i32.const 1))
                            (i32.const 4)))
          (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.const 0))
  ;; Phase 19.3: vec_concat — new Vec, copy a then b.
  (func $mere_vec_concat (param $a i32) (param $b i32) (result i32)
    (local $new i32) (local $i i32) (local $alen i32) (local $blen i32)
    (local $abuf i32) (local $bbuf i32)
    (local.set $new (call $mere_vec_new))
    (local.set $alen (i32.load offset=4 (local.get $a)))
    (local.set $blen (i32.load offset=4 (local.get $b)))
    (local.set $abuf (i32.load offset=0 (local.get $a)))
    (local.set $bbuf (i32.load offset=0 (local.get $b)))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $alen)))
        (drop (call $mere_vec_push (local.get $new)
                (i32.load (i32.add (local.get $abuf)
                                   (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $blen)))
        (drop (call $mere_vec_push (local.get $new)
                (i32.load (i32.add (local.get $bbuf)
                                   (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (local.get $new))  (func $init (param i32) (result i32)
    local.get 0
    i32.const 16
    i32.eq
    if (result i32)
    i32.const 0
    else
    global.get $board
    i32.const 0
    call $mere_vec_push
    drop
    local.get 0
    i32.const 1
    i32.add
    return_call $init
    end)
  (func $handle (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.const 16
    call $__lang_streq
    if (result i32)
    i32.const 26
    else
    local.get 0
    i32.const 28
    call $__lang_streq
    if (result i32)
    i32.const 39
    else
    local.get 0
    i32.const 41
    call $__lang_streq
    if (result i32)
    i32.const 49
    else
    local.get 0
    i32.const 51
    call $__lang_streq
    if (result i32)
    i32.const 61
    else
    i32.const 63
    end
    end
    end
    end
    local.set 1
    local.get 1
    i32.const 64
    call $__lang_streq
    if (result i32)
    i32.const 0
    else
    global.get $board
    call $snap
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    global.get $board
    call $move
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $board
    call $snap
    local.set 6
    local.get 6
    i32.load offset=0
    i32.const 0
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 2
    call $eq_list
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 5
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    i32.eqz
    if (result i32)
    global.get $board
    call $spawn_tile
    local.set 8
    local.get 8
    i32.load offset=0
    global.get $st
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    else
    i32.const 0
    end
    drop
    i32.const 0
    return_call $redraw
    end)
  (func $redraw (param i32) (result i32)
    global.get $screen
    global.get $board
    call $render
    call $dom_set_text
    i32.const 0)
  (func $render (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    call $has_val
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
    i32.const 2048
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    if (result i32)
    i32.const 65
    else
    local.get 0
    call $stuck
    if (result i32)
    i32.const 84
    else
    i32.const 104
    end
    end
    local.set 1
    local.get 0
    i32.const 0
    call $__lifted_rrow_0
    i32.const 119
    call $__lang_str_concat
    local.get 0
    i32.const 1
    call $__lifted_rrow_0
    call $__lang_str_concat
    i32.const 121
    call $__lang_str_concat
    local.get 0
    i32.const 2
    call $__lifted_rrow_0
    call $__lang_str_concat
    i32.const 123
    call $__lang_str_concat
    local.get 0
    i32.const 3
    call $__lifted_rrow_0
    call $__lang_str_concat
    i32.const 125
    call $__lang_str_concat
    local.get 1
    call $__lang_str_concat)
  (func $cell (param i32) (result i32)
    (local i32)
    local.get 0
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 127
    else
    local.get 0
    call $show_int
    end
    local.set 1
    local.get 1
    return_call $__lifted_padl_1)
  (func $stuck (param i32) (result i32)
    (local i32 i32)
    local.get 0
    call $count_empty
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    local.get 1
    i32.load offset=4
    call_indirect (type $cl)
    i32.const 0
    i32.eq
    local.get 0
    call $any_adj
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 0
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    i32.eqz
    i32.and)
  (func $any_adj (param i32) (result i32)
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
    i32.const 35
    i32.store offset=4
    local.get 2)
  (func $has_val (param i32) (result i32)
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
    i32.const 36
    i32.store offset=4
    local.get 2)
  (func $spawn_tile (param i32) (result i32)
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
    i32.const 37
    i32.store offset=4
    local.get 2)
  (func $place_kth (param i32) (result i32)
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
    i32.const 38
    i32.store offset=4
    local.get 2)
  (func $count_empty (param i32) (result i32)
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
    i32.const 39
    i32.store offset=4
    local.get 2)
  (func $next_rand (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.const 0
    call $mere_vec_get
    local.set 1
    local.get 1
    i32.const 137
    i32.mul
    i32.const 187
    i32.add
    i32.const 30011
    i32.rem_s
    local.set 2
    local.get 0
    i32.const 0
    local.get 2
    call $mere_vec_set
    drop
    local.get 2)
  (func $eq_list (param i32) (result i32)
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
    i32.const 40
    i32.store offset=4
    local.get 2)
  (func $snap (param i32) (result i32)
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
    i32.const 41
    i32.store offset=4
    local.get 2)
  (func $move (param i32) (result i32)
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
    i32.const 42
    i32.store offset=4
    local.get 2)
  (func $do_line (param i32) (result i32)
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
    i32.const 43
    i32.store offset=4
    local.get 2)
  (func $put_line (param i32) (result i32)
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
    i32.const 44
    i32.store offset=4
    local.get 2)
  (func $get_line (param i32) (result i32)
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
    i32.const 45
    i32.store offset=4
    local.get 2)
  (func $bset (param i32) (result i32)
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
    i32.const 46
    i32.store offset=4
    local.get 2)
  (func $bget (param i32) (result i32)
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
    i32.const 47
    i32.store offset=4
    local.get 2)
  (func $reverse (param i32) (result i32)
    (local i32 i32)
    local.get 0
    call $rev_go
    local.set 1
    local.get 1
    i32.load offset=0
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    i32.const 0
    i32.store offset=0
    local.get 2
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $rev_go (param i32) (result i32)
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
    i32.const 48
    i32.store offset=4
    local.get 2)
  (func $slide (param i32) (result i32)
    (local i32)
    local.get 0
    call $compress
    call $merge
    call $pad
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 4
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $pad (param i32) (result i32)
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
    i32.const 49
    i32.store offset=4
    local.get 2)
  (func $merge (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 2
    local.get 2
    if (result i32)
    local.get 1
    i32.load offset=4
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 5
    i32.const 1
    local.set 6
    local.get 3
    i32.load offset=4
    local.set 7
    local.get 7
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 8
    local.get 8
    if (result i32)
    local.get 7
    i32.load offset=4
    local.set 9
    local.get 9
    i32.load offset=0
    local.set 11
    i32.const 1
    local.set 12
    local.get 9
    i32.load offset=4
    local.set 13
    i32.const 1
    local.set 14
    i32.const 1
    local.set 15
    local.get 15
    local.get 12
    i32.and
    local.set 16
    local.get 16
    local.get 14
    i32.and
    local.set 17
    local.get 17
    else
    i32.const 0
    end
    local.set 10
    i32.const 1
    local.set 18
    local.get 18
    local.get 6
    i32.and
    local.set 19
    local.get 19
    local.get 10
    i32.and
    local.set 20
    local.get 20
    else
    i32.const 0
    end
    local.set 4
    local.get 4
    if (result i32)
    local.get 5
    local.get 11
    i32.eq
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
    local.get 5
    local.get 11
    i32.add
    i32.store offset=0
    local.get 22
    local.get 13
    call $merge
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
    local.get 5
    i32.store offset=0
    local.get 24
    global.get $__lang_bump
    local.set 25
    local.get 25
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 25
    i32.const 1
    i32.store offset=0
    local.get 25
    global.get $__lang_bump
    local.set 26
    local.get 26
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 26
    local.get 11
    i32.store offset=0
    local.get 26
    local.get 13
    i32.store offset=4
    local.get 26
    i32.store offset=4
    local.get 25
    call $merge
    i32.store offset=4
    local.get 24
    i32.store offset=4
    local.get 23
    end
    else
    i32.const 1
    local.set 27
    local.get 27
    if (result i32)
    local.get 1
    else
    unreachable
    end
    end)
  (func $compress (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 2
    local.get 2
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
    local.get 1
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 4
    local.get 4
    if (result i32)
    local.get 1
    i32.load offset=4
    local.set 5
    local.get 5
    i32.load offset=0
    local.set 7
    i32.const 1
    local.set 8
    local.get 5
    i32.load offset=4
    local.set 9
    i32.const 1
    local.set 10
    i32.const 1
    local.set 11
    local.get 11
    local.get 8
    i32.and
    local.set 12
    local.get 12
    local.get 10
    i32.and
    local.set 13
    local.get 13
    else
    i32.const 0
    end
    local.set 6
    local.get 6
    if (result i32)
    local.get 7
    i32.const 0
    i32.eq
    if (result i32)
    local.get 9
    return_call $compress
    else
    global.get $__lang_bump
    local.set 14
    local.get 14
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 14
    i32.const 1
    i32.store offset=0
    local.get 14
    global.get $__lang_bump
    local.set 15
    local.get 15
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 15
    local.get 7
    i32.store offset=0
    local.get 15
    local.get 9
    call $compress
    i32.store offset=4
    local.get 15
    i32.store offset=4
    local.get 14
    end
    else
    unreachable
    end
    end)
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
    i32.const 50
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
    i32.const 51
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
    i32.const 52
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
    i32.const 129
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
    i32.const 150
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
    i32.const 53
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
    i32.const 54
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
    i32.const 55
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
    i32.const 56
    i32.store offset=4
    local.get 2)
  (func $__lifted_go_5 (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 1
    i32.const 4
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 0
    call $do_line
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
    i32.const 4
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 1
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 0
    local.get 1
    i32.const 1
    i32.add
    return_call $__lifted_go_5
    end)
  (func $__lifted_go_uq1_4 (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 1
    i32.const 4
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 0
    call $do_line
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
    i32.const 4
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 0
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 0
    local.get 1
    i32.const 1
    i32.add
    return_call $__lifted_go_uq1_4
    end)
  (func $__lifted_go_uq2_3 (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 1
    i32.const 4
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 0
    call $do_line
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 1
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 1
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 0
    local.get 1
    i32.const 1
    i32.add
    return_call $__lifted_go_uq2_3
    end)
  (func $__lifted_go_uq3_2 (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 1
    i32.const 4
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 0
    call $do_line
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 1
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 0
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 0
    local.get 1
    i32.const 1
    i32.add
    return_call $__lifted_go_uq3_2
    end)
  (func $__lifted_padl_1 (param i32) (result i32)
    local.get 0
    call $__lang_strlen
    i32.const 5
    i32.ge_s
    if (result i32)
    local.get 0
    else
    i32.const 171
    local.get 0
    call $__lang_str_concat
    return_call $__lifted_padl_1
    end)
  (func $__lifted_rrow_0 (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32)
    local.get 0
    call $bget
    local.set 2
    local.get 2
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    call $cell
    local.get 0
    call $bget
    local.set 3
    local.get 3
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    i32.const 1
    i32.add
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    call $cell
    call $__lang_str_concat
    local.get 0
    call $bget
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    i32.const 2
    i32.add
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    call $cell
    call $__lang_str_concat
    local.get 0
    call $bget
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.mul
    i32.const 3
    i32.add
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    call $cell
    call $__lang_str_concat)
  (func $init_closure (param i32) (param i32) (result i32)
    local.get 1
    call $init)
  (func $handle_closure (param i32) (param i32) (result i32)
    local.get 1
    call $handle)
  (func $redraw_closure (param i32) (param i32) (result i32)
    local.get 1
    call $redraw)
  (func $render_closure (param i32) (param i32) (result i32)
    local.get 1
    call $render)
  (func $cell_closure (param i32) (param i32) (result i32)
    local.get 1
    call $cell)
  (func $stuck_closure (param i32) (param i32) (result i32)
    local.get 1
    call $stuck)
  (func $any_adj_closure (param i32) (param i32) (result i32)
    local.get 1
    call $any_adj)
  (func $has_val_closure (param i32) (param i32) (result i32)
    local.get 1
    call $has_val)
  (func $spawn_tile_closure (param i32) (param i32) (result i32)
    local.get 1
    call $spawn_tile)
  (func $place_kth_closure (param i32) (param i32) (result i32)
    local.get 1
    call $place_kth)
  (func $count_empty_closure (param i32) (param i32) (result i32)
    local.get 1
    call $count_empty)
  (func $next_rand_closure (param i32) (param i32) (result i32)
    local.get 1
    call $next_rand)
  (func $eq_list_closure (param i32) (param i32) (result i32)
    local.get 1
    call $eq_list)
  (func $snap_closure (param i32) (param i32) (result i32)
    local.get 1
    call $snap)
  (func $move_closure (param i32) (param i32) (result i32)
    local.get 1
    call $move)
  (func $do_line_closure (param i32) (param i32) (result i32)
    local.get 1
    call $do_line)
  (func $put_line_closure (param i32) (param i32) (result i32)
    local.get 1
    call $put_line)
  (func $get_line_closure (param i32) (param i32) (result i32)
    local.get 1
    call $get_line)
  (func $bset_closure (param i32) (param i32) (result i32)
    local.get 1
    call $bset)
  (func $bget_closure (param i32) (param i32) (result i32)
    local.get 1
    call $bget)
  (func $reverse_closure (param i32) (param i32) (result i32)
    local.get 1
    call $reverse)
  (func $rev_go_closure (param i32) (param i32) (result i32)
    local.get 1
    call $rev_go)
  (func $slide_closure (param i32) (param i32) (result i32)
    local.get 1
    call $slide)
  (func $pad_closure (param i32) (param i32) (result i32)
    local.get 1
    call $pad)
  (func $merge_closure (param i32) (param i32) (result i32)
    local.get 1
    call $merge)
  (func $compress_closure (param i32) (param i32) (result i32)
    local.get 1
    call $compress)
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
  (func $anon_21_fn (param i32) (param i32) (result i32)
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
    i32.const 57
    i32.store offset=4
    local.get 4)
  (func $anon_22_fn (param i32) (param i32) (result i32)
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
  (func $anon_20_fn (param i32) (param i32) (result i32)
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
  (func $anon_19_fn (param i32) (param i32) (result i32)
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
    i32.const 58
    i32.store offset=4
    local.get 3)
  (func $anon_23_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.add)
  (func $anon_18_fn (param i32) (param i32) (result i32)
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
    i32.const 59
    i32.store offset=4
    local.get 3)
  (func $anon_24_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.mul)
  (func $anon_17_fn (param i32) (param i32) (result i32)
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
    i32.const 60
    i32.store offset=4
    local.get 4)
  (func $anon_25_fn (param i32) (param i32) (result i32)
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
  (func $anon_16_fn (param i32) (param i32) (result i32)
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
  (func $anon_15_fn (param i32) (param i32) (result i32)
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
    i32.const 61
    i32.store offset=4
    local.get 3)
  (func $anon_26_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.lt_s)
  (func $anon_14_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    i32.const 0
    i32.eq
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
    i32.const 0
    i32.store offset=0
    local.get 7
    global.get $__lang_bump
    local.set 9
    local.get 9
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 9
    i32.const 0
    i32.store offset=0
    local.get 9
    call $pad
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.sub
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=4
    local.get 7
    i32.store offset=4
    local.get 6
    else
    local.get 4
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 10
    local.get 10
    if (result i32)
    local.get 4
    i32.load offset=4
    local.set 11
    local.get 11
    i32.load offset=0
    local.set 13
    i32.const 1
    local.set 14
    local.get 11
    i32.load offset=4
    local.set 15
    i32.const 1
    local.set 16
    i32.const 1
    local.set 17
    local.get 17
    local.get 14
    i32.and
    local.set 18
    local.get 18
    local.get 16
    i32.and
    local.set 19
    local.get 19
    else
    i32.const 0
    end
    local.set 12
    local.get 12
    if (result i32)
    global.get $__lang_bump
    local.set 20
    local.get 20
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 20
    i32.const 1
    i32.store offset=0
    local.get 20
    global.get $__lang_bump
    local.set 21
    local.get 21
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 21
    local.get 13
    i32.store offset=0
    local.get 21
    local.get 15
    call $pad
    local.set 22
    local.get 22
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.sub
    local.get 22
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=4
    local.get 21
    i32.store offset=4
    local.get 20
    else
    unreachable
    end
    end
    end)
  (func $anon_13_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 4
    local.get 4
    if (result i32)
    local.get 1
    else
    local.get 3
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 5
    local.get 5
    if (result i32)
    local.get 3
    i32.load offset=4
    local.set 6
    local.get 6
    i32.load offset=0
    local.set 8
    i32.const 1
    local.set 9
    local.get 6
    i32.load offset=4
    local.set 10
    i32.const 1
    local.set 11
    i32.const 1
    local.set 12
    local.get 12
    local.get 9
    i32.and
    local.set 13
    local.get 13
    local.get 11
    i32.and
    local.set 14
    local.get 14
    else
    i32.const 0
    end
    local.set 7
    local.get 7
    if (result i32)
    local.get 10
    call $rev_go
    local.set 15
    local.get 15
    i32.load offset=0
    global.get $__lang_bump
    local.set 16
    local.get 16
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 16
    i32.const 1
    i32.store offset=0
    local.get 16
    global.get $__lang_bump
    local.set 17
    local.get 17
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 17
    local.get 8
    i32.store offset=0
    local.get 17
    local.get 1
    i32.store offset=4
    local.get 17
    i32.store offset=4
    local.get 16
    local.get 15
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_12_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    call $mere_vec_get)
  (func $anon_11_fn (param i32) (param i32) (result i32)
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
    i32.const 62
    i32.store offset=4
    local.get 4)
  (func $anon_27_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    local.get 3
    local.get 1
    call $mere_vec_set)
  (func $anon_10_fn (param i32) (param i32) (result i32)
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
    i32.const 63
    i32.store offset=4
    local.get 4)
  (func $anon_28_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
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
    call $bget
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 3
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=0
    local.get 5
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    i32.const 1
    i32.store offset=0
    local.get 7
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 8
    local.get 2
    call $bget
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 3
    local.get 1
    i32.add
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=0
    local.get 8
    global.get $__lang_bump
    local.set 10
    local.get 10
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 10
    i32.const 1
    i32.store offset=0
    local.get 10
    global.get $__lang_bump
    local.set 11
    local.get 11
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 11
    local.get 2
    call $bget
    local.set 12
    local.get 12
    i32.load offset=0
    local.get 3
    local.get 1
    i32.const 2
    i32.mul
    i32.add
    local.get 12
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=0
    local.get 11
    global.get $__lang_bump
    local.set 13
    local.get 13
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 13
    i32.const 1
    i32.store offset=0
    local.get 13
    global.get $__lang_bump
    local.set 14
    local.get 14
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 14
    local.get 2
    call $bget
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 3
    local.get 1
    i32.const 3
    i32.mul
    i32.add
    local.get 15
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=0
    local.get 14
    global.get $__lang_bump
    local.set 16
    local.get 16
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 16
    i32.const 0
    i32.store offset=0
    local.get 16
    i32.store offset=4
    local.get 14
    i32.store offset=4
    local.get 13
    i32.store offset=4
    local.get 11
    i32.store offset=4
    local.get 10
    i32.store offset=4
    local.get 8
    i32.store offset=4
    local.get 7
    i32.store offset=4
    local.get 5
    i32.store offset=4
    local.get 4)
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
    i32.const 64
    i32.store offset=4
    local.get 4)
  (func $anon_29_fn (param i32) (param i32) (result i32)
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
    local.get 2
    i32.store offset=0
    local.get 4
    local.get 3
    i32.store offset=4
    local.get 4
    local.get 1
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
    i32.const 65
    i32.store offset=4
    local.get 5)
  (func $anon_30_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    local.get 1
    local.set 5
    local.get 5
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 6
    local.get 6
    if (result i32)
    i32.const 0
    else
    local.get 5
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 7
    local.get 7
    if (result i32)
    local.get 5
    i32.load offset=4
    local.set 8
    local.get 8
    i32.load offset=0
    local.set 10
    i32.const 1
    local.set 11
    local.get 8
    i32.load offset=4
    local.set 12
    i32.const 1
    local.set 13
    i32.const 1
    local.set 14
    local.get 14
    local.get 11
    i32.and
    local.set 15
    local.get 15
    local.get 13
    i32.and
    local.set 16
    local.get 16
    else
    i32.const 0
    end
    local.set 9
    local.get 9
    if (result i32)
    local.get 2
    call $bset
    local.set 18
    local.get 18
    i32.load offset=0
    local.get 3
    local.get 18
    i32.load offset=4
    call_indirect (type $cl)
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 10
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    call $put_line
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 3
    local.get 4
    i32.add
    local.get 21
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.load offset=0
    local.get 4
    local.get 20
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 12
    local.get 19
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_8_fn (param i32) (param i32) (result i32)
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
    i32.const 66
    i32.store offset=4
    local.get 4)
  (func $anon_31_fn (param i32) (param i32) (result i32)
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
    local.get 2
    i32.store offset=0
    local.get 4
    local.get 3
    i32.store offset=4
    local.get 4
    local.get 1
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
    i32.const 67
    i32.store offset=4
    local.get 5)
  (func $anon_32_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    call $get_line
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 3
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 4
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 1
    if (result i32)
    local.get 5
    call $reverse
    call $slide
    call $reverse
    else
    local.get 5
    call $slide
    end
    local.set 8
    local.get 2
    call $put_line
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 3
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.load offset=0
    local.get 4
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 8
    local.get 9
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_7_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    i32.const 182
    call $__lang_streq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_go_uq3_2
    else
    local.get 1
    i32.const 184
    call $__lang_streq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_go_uq2_3
    else
    local.get 1
    i32.const 186
    call $__lang_streq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_go_uq1_4
    else
    local.get 1
    i32.const 188
    call $__lang_streq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_go_5
    else
    i32.const 0
    end
    end
    end
    end)
  (func $anon_6_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    i32.const 16
    i32.eq
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
    call $bget
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 1
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=0
    local.get 5
    local.get 2
    call $snap
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.add
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    i32.store offset=4
    local.get 5
    i32.store offset=4
    local.get 4
    end)
  (func $anon_5_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 4
    local.get 4
    if (result i32)
    local.get 1
    local.set 5
    local.get 5
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 6
    local.get 6
    if (result i32)
    i32.const 1
    else
    i32.const 1
    local.set 7
    local.get 7
    if (result i32)
    i32.const 0
    else
    unreachable
    end
    end
    else
    local.get 3
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 8
    local.get 8
    if (result i32)
    local.get 3
    i32.load offset=4
    local.set 9
    local.get 9
    i32.load offset=0
    local.set 11
    i32.const 1
    local.set 12
    local.get 9
    i32.load offset=4
    local.set 13
    i32.const 1
    local.set 14
    i32.const 1
    local.set 15
    local.get 15
    local.get 12
    i32.and
    local.set 16
    local.get 16
    local.get 14
    i32.and
    local.set 17
    local.get 17
    else
    i32.const 0
    end
    local.set 10
    local.get 10
    if (result i32)
    local.get 1
    local.set 18
    local.get 18
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 19
    local.get 19
    if (result i32)
    i32.const 0
    else
    local.get 18
    i32.load offset=0
    i32.const 1
    i32.eq
    local.set 20
    local.get 20
    if (result i32)
    local.get 18
    i32.load offset=4
    local.set 21
    local.get 21
    i32.load offset=0
    local.set 23
    i32.const 1
    local.set 24
    local.get 21
    i32.load offset=4
    local.set 25
    i32.const 1
    local.set 26
    i32.const 1
    local.set 27
    local.get 27
    local.get 24
    i32.and
    local.set 28
    local.get 28
    local.get 26
    i32.and
    local.set 29
    local.get 29
    else
    i32.const 0
    end
    local.set 22
    local.get 22
    if (result i32)
    local.get 11
    local.get 23
    i32.eq
    local.get 13
    call $eq_list
    local.set 30
    local.get 30
    i32.load offset=0
    local.get 25
    local.get 30
    i32.load offset=4
    call_indirect (type $cl)
    i32.and
    else
    unreachable
    end
    end
    else
    unreachable
    end
    end)
  (func $anon_4_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    i32.const 16
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 2
    call $bget
    local.set 3
    local.get 3
    i32.load offset=0
    local.get 1
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 1
    else
    i32.const 0
    end
    local.get 2
    call $count_empty
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.add
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    i32.add
    end)
  (func $anon_3_fn (param i32) (param i32) (result i32)
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
    i32.const 68
    i32.store offset=4
    local.get 4)
  (func $anon_33_fn (param i32) (param i32) (result i32)
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
    local.get 2
    i32.store offset=0
    local.get 4
    local.get 3
    i32.store offset=4
    local.get 4
    local.get 1
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
    i32.const 69
    i32.store offset=4
    local.get 5)
  (func $anon_34_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    i32.const 16
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 3
    call $bget
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 2
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    i32.const 0
    i32.eq
    if (result i32)
    local.get 4
    i32.const 0
    i32.eq
    if (result i32)
    local.get 3
    call $bset
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 2
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
    else
    local.get 3
    call $place_kth
    local.set 10
    local.get 10
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 4
    i32.const 1
    i32.sub
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 1
    local.get 8
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    else
    local.get 3
    call $place_kth
    local.set 13
    local.get 13
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 13
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.load offset=0
    local.get 4
    local.get 12
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 1
    local.get 11
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
  (func $anon_2_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    call $count_empty
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 0
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 1
    call $next_rand
    local.get 3
    i32.rem_s
    local.set 5
    local.get 1
    call $next_rand
    i32.const 10
    i32.rem_s
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 4
    else
    i32.const 2
    end
    local.set 6
    local.get 2
    call $place_kth
    local.set 9
    local.get 9
    i32.load offset=0
    i32.const 0
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 5
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 6
    local.get 7
    i32.load offset=4
    return_call_indirect (type $cl)
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
    i32.const 70
    i32.store offset=4
    local.get 4)
  (func $anon_35_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    i32.const 16
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 3
    call $bget
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 2
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.get 1
    i32.eq
    if (result i32)
    i32.const 1
    else
    local.get 3
    call $has_val
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 1
    local.get 5
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
  (func $anon_0_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    i32.const 16
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 1
    i32.const 4
    i32.div_s
    local.set 3
    local.get 1
    i32.const 4
    i32.rem_s
    local.set 4
    local.get 2
    call $bget
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 1
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 4
    i32.const 3
    i32.lt_s
    local.get 2
    call $bget
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.add
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    local.get 5
    i32.eq
    i32.and
    local.set 7
    local.get 3
    i32.const 3
    i32.lt_s
    local.get 2
    call $bget
    local.set 10
    local.get 10
    i32.load offset=0
    local.get 1
    i32.const 4
    i32.add
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.get 5
    i32.eq
    i32.and
    local.set 9
    local.get 7
    local.get 9
    i32.or
    if (result i32)
    i32.const 1
    else
    local.get 2
    call $any_adj
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.add
    local.get 11
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
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
  (func $show_unit (param $u i32) (result i32)
    (i32.const 173))
  (func $main (export "main") (result i32)
    (local i32 i32 i32)
    call $mere_vec_new
    global.set $board
    call $mere_vec_new
    global.set $st
    i32.const 176
    call $dom_get_by_id
    global.set $screen
    i32.const 0
    call $init
    drop
    global.get $st
    i32.const 12345
    call $mere_vec_push
    drop
    global.get $board
    call $spawn_tile
    local.set 0
    local.get 0
    i32.load offset=0
    global.get $st
    local.get 0
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $board
    call $spawn_tile
    local.set 1
    local.get 1
    i32.load offset=0
    global.get $st
    local.get 1
    i32.load offset=4
    call_indirect (type $cl)
    drop
    i32.const 0
    call $redraw
    drop
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
    i32.const 0
    i32.store offset=0
    local.get 2
    i32.const 1
    i32.store offset=4
    local.get 2
    call $dom_on_key
    i32.const 0
    drop
    i32.const 173
    call $puts
    i32.const 0)
)

