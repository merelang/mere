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
  (import "env" "dom_canvas_fill_style" (func $dom_canvas_fill_style (param i32) (param i32)))
  (import "env" "dom_on_frame" (func $dom_on_frame (param i32)))
  (import "env" "dom_canvas_fill_rect" (func $dom_canvas_fill_rect (param i32) (param i32) (param i32) (param i32) (param i32)))
  (import "env" "dom_on_key" (func $dom_on_key (param i32)))
  (import "env" "dom_on_click" (func $dom_on_click (param i32) (param i32)))
  (import "env" "dom_set_text" (func $dom_set_text (param i32) (param i32)))
  (memory (export "memory") 1024)
  (table 66 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $handle_key_closure $frame_closure $render_closure $step_closure $rng_next_closure $draw_closure $seti_closure $geti_closure $blit_bytes_closure $new_vec_closure $mask12_closure $mask8_closure $pad_left_closure $pad_right_closure $utf8_width_closure $_u8w_go_closure $_eaw_width_closure $utf8_rev_closure $_u8_rev_join_closure $utf8_sub_closure $_u8_slice_closure $utf8_at_closure $_u8_nth_closure $list_product_closure $list_sum_closure $range_closure $_range_down_closure $list_fold_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn $anon_17_fn $anon_18_fn $anon_19_fn $anon_20_fn $anon_21_fn $anon_22_fn $anon_23_fn $anon_24_fn $anon_25_fn $anon_26_fn $anon_27_fn $anon_28_fn $anon_29_fn $anon_30_fn $anon_31_fn $anon_32_fn $anon_33_fn $anon_34_fn $anon_35_fn $anon_36_fn $anon_37_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 816))
(global $__rgn_tmp (mut i32) (i32.const 0))
  (global $__lang_char_table i32 (i32.const 304))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (global $mem (mut i32) (i32.const 0))
  (global $v (mut i32) (i32.const 0))
  (global $reg (mut i32) (i32.const 0))
  (global $stack (mut i32) (i32.const 0))
  (global $disp (mut i32) (i32.const 0))
  (global $rng (mut i32) (i32.const 0))
  (global $keys (mut i32) (i32.const 0))
  (global $screen (mut i32) (i32.const 0))
  (global $scale (mut i32) (i32.const 0))
  (data (i32.const 16) "1\00")
  (data (i32.const 18) "2\00")
  (data (i32.const 20) "3\00")
  (data (i32.const 22) "4\00")
  (data (i32.const 24) "q\00")
  (data (i32.const 26) "w\00")
  (data (i32.const 28) "e\00")
  (data (i32.const 30) "r\00")
  (data (i32.const 32) "a\00")
  (data (i32.const 34) "s\00")
  (data (i32.const 36) "d\00")
  (data (i32.const 38) "f\00")
  (data (i32.const 40) "z\00")
  (data (i32.const 42) "x\00")
  (data (i32.const 44) "c\00")
  (data (i32.const 46) "v\00")
  (data (i32.const 48) "#0b0f14\00")
  (data (i32.const 56) "#7ee787\00")
  (data (i32.const 64) "\00")
  (data (i32.const 65) "()\00")
  (data (i32.const 68) "F0909090F02060202070F010F080F0F010F010F09090F01010F080F010F0\00")
  (data (i32.const 129) "F080F090F0F010204040F090F090F0F090F010F0F090F09090E090E090E0F0808080F0E0909090E0F080F080F0F080F08080\00")
  (data (i32.const 230) "6c0f600000e0f029611a620dd1256a08fa15fb073b001212700180c21204\00")
  (data (i32.const 291) "screen\00")
  (data (i32.const 298) "\00")
  (data (i32.const 299) "\00")
  (data (i32.const 300) " \00")
  (data (i32.const 302) " \00")

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
  ;; v0.1.37: deep-copy a NUL-terminated str into fresh bump space.
  ;; Region blocks copy their result out before releasing the block's
  ;; allocations (the safe version of the save/restore that Phase 16.4
  ;; removed as unsound).
  (func $__mcopy_str (param $s i32) (result i32)
    (local $l i32) (local $r i32) (local $i i32)
    (local.set $l (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.gt_s (local.get $i) (local.get $l)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $l)) (i32.const 1)))
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
  ;; v0.1.60: int_of_str s msg — strict decimal parse
  ;; (WS* [+-]? DIGIT+ WS*); anything else calls $__lang_fail with the
  ;; interned msg (try_or-able), matching the interpreter instead of the
  ;; old atoi semantics that silently returned 0 / a partial prefix.
  (func $__lang_int_of_str (param $s i32) (param $msg i32) (result i32)
    (local $i i32) (local $sign i32) (local $acc i32) (local $c i32)
    (local $nd i32)
    (local.set $i (i32.const 0))
    (local.set $sign (i32.const 1))
    (local.set $acc (i32.const 0))
    (local.set $nd (i32.const 0))
    (block $lead_done                       ;; skip leading whitespace
      (loop $lead
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $lead_done (i32.eqz (i32.or (i32.or
          (i32.eq (local.get $c) (i32.const 32))
          (i32.eq (local.get $c) (i32.const 9)))
          (i32.or
            (i32.eq (local.get $c) (i32.const 13))
            (i32.eq (local.get $c) (i32.const 10))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lead)))
    (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
    (if (i32.eq (local.get $c) (i32.const 45))  ;; '-'
      (then
        (local.set $sign (i32.const -1))
        (local.set $i (i32.add (local.get $i) (i32.const 1))))
      (else
        (if (i32.eq (local.get $c) (i32.const 43))  ;; '+'
          (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))))
    (block $end
      (loop $lp
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $end (i32.or
          (i32.lt_s (local.get $c) (i32.const 48))
          (i32.gt_s (local.get $c) (i32.const 57))))
        (local.set $acc (i32.add
          (i32.mul (local.get $acc) (i32.const 10))
          (i32.sub (local.get $c) (i32.const 48))))
        (local.set $nd (i32.add (local.get $nd) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (block $trail_done                      ;; skip trailing whitespace
      (loop $trail
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $trail_done (i32.eqz (i32.or (i32.or
          (i32.eq (local.get $c) (i32.const 32))
          (i32.eq (local.get $c) (i32.const 9)))
          (i32.or
            (i32.eq (local.get $c) (i32.const 13))
            (i32.eq (local.get $c) (i32.const 10))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $trail)))
    (if (i32.or
          (i32.eqz (local.get $nd))          ;; no digits
          (i32.ne (local.get $c) (i32.const 0)))  ;; junk after
      (then
        (call $__lang_fail (local.get $msg))
        (drop)
        (return (i32.const 0))))
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
  (func $__lang_list_str_nil (result i32)
    (local $p i32)
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))
    (i32.store offset=0 (local.get $p) (i32.const 0))
    (local.get $p))
  (func $__lang_list_str_cons (param $head i32) (param $tail i32) (result i32)
    (local $p i32) (local $box i32)
    ;; Tuple payload box: 8 bytes (str_ptr + list_str_ptr).
    (local.set $box (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $box) (i32.const 8)))
    (i32.store offset=0 (local.get $box) (local.get $head))
    (i32.store offset=4 (local.get $box) (local.get $tail))
    ;; Cons cell: 8 bytes (tag=1 + payload_ptr).
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))
    (i32.store offset=0 (local.get $p) (i32.const 1))
    (i32.store offset=4 (local.get $p) (local.get $box))
    (local.get $p))
  ;; v0.1.38 (Unicode): codepoint view. Walk lead bytes; build the char
  ;; list back-to-front by scanning for sequence starts from the end.
  (func $__lang_utf8_len (param $s i32) (result i32)
    (local $n i32) (local $i i32) (local $c i32) (local $b i32) (local $l i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $i (i32.const 0))
    (local.set $c (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $l
          (if (result i32) (i32.lt_u (local.get $b) (i32.const 128))
            (then (i32.const 1))
            (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 192)) (i32.le_u (local.get $b) (i32.const 223)))
              (then (i32.const 2))
              (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 224)) (i32.le_u (local.get $b) (i32.const 239)))
                (then (i32.const 3))
                (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 240)) (i32.le_u (local.get $b) (i32.const 247)))
                  (then (i32.const 4))
                  (else (i32.const 1))))))))))
        (if (i32.gt_s (local.get $l) (i32.sub (local.get $n) (local.get $i)))
          (then (local.set $l (i32.sub (local.get $n) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (local.get $l)))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br $lp)))
    (local.get $c))
  (func $__lang_utf8_chars (param $s i32) (result i32)
    (local $n i32) (local $end i32) (local $st i32) (local $l i32)
    (local $tok i32) (local $j i32) (local $acc i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $acc (call $__lang_list_str_nil))
    (local.set $end (local.get $n))
    (block $done
      (loop $outer
        (br_if $done (i32.le_s (local.get $end) (i32.const 0)))
        ;; scan backward to this character's lead byte
        (local.set $st (i32.sub (local.get $end) (i32.const 1)))
        (block $found
          (loop $back
            (br_if $found (i32.le_s (local.get $st) (i32.const 0)))
            (br_if $found
              (i32.ne (i32.and (i32.load8_u (i32.add (local.get $s) (local.get $st))) (i32.const 192))
                      (i32.const 128)))
            (local.set $st (i32.sub (local.get $st) (i32.const 1)))
            (br $back)))
        (local.set $l (i32.sub (local.get $end) (local.get $st)))
        ;; copy the char bytes into a fresh NUL-terminated str
        (local.set $tok (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (i32.add (local.get $tok) (local.get $l)) (i32.const 1)))
        (local.set $j (i32.const 0))
        (block $cend
          (loop $clp
            (br_if $cend (i32.ge_s (local.get $j) (local.get $l)))
            (i32.store8 (i32.add (local.get $tok) (local.get $j))
                        (i32.load8_u (i32.add (i32.add (local.get $s) (local.get $st)) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $clp)))
        (i32.store8 (i32.add (local.get $tok) (local.get $l)) (i32.const 0))
        (local.set $acc (call $__lang_list_str_cons (local.get $tok) (local.get $acc)))
        (local.set $end (local.get $st))
        (br $outer)))
    (local.get $acc))
  ;; str_split s delim — 2-pass: count tokens, then build list back-to-front.
  (func $__lang_str_split (param $s i32) (param $delim i32) (result i32)
    (local $sl i32) (local $dl i32) (local $i i32) (local $cnt i32)
    (local $starts i32) (local $lens i32) (local $tstart i32) (local $tidx i32)
    (local $tlen i32) (local $tk i32) (local $j i32) (local $match i32)
    (local $nil i32) (local $tail i32) (local $bi i32) (local $b_off i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $dl (call $__lang_strlen (local.get $delim)))
    ;; Empty delim: return Cons(s, Nil) (matches interp / C / LLVM).
    (if (i32.eqz (local.get $dl))
      (then
        (local.set $nil (call $__lang_list_str_nil))
        (return (call $__lang_list_str_cons (local.get $s) (local.get $nil)))))
    ;; Pass 1: count delim occurrences (non-overlapping).
    (local.set $i (i32.const 0))
    (local.set $cnt (i32.const 0))
    (block $end_c
      (loop $lp_c
        (br_if $end_c
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        ;; Compare delim bytes.
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_c)))
    ;; Allocate parallel (start, len) arrays — n = cnt + 1 tokens.
    (local.set $starts (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    (local.set $lens (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    ;; Pass 2: extract tokens into (start, len) arrays.
    (local.set $i (i32.const 0))
    (local.set $tstart (i32.const 0))
    (local.set $tidx (i32.const 0))
    (block $end_f
      (loop $lp_f
        (br_if $end_f
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner2
          (loop $lp_inner2
            (br_if $end_inner2 (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner2)))
        (if (local.get $match)
          (then
            (i32.store
              (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
              (local.get $tstart))
            (i32.store
              (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
              (i32.sub (local.get $i) (local.get $tstart)))
            (local.set $tidx (i32.add (local.get $tidx) (i32.const 1)))
            (local.set $tstart (i32.add (local.get $i) (local.get $dl)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_f)))
    ;; Last token: (tstart, sl - tstart) at index $tidx.
    (i32.store
      (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
      (local.get $tstart))
    (i32.store
      (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
      (i32.sub (local.get $sl) (local.get $tstart)))
    ;; Build Cons list back-to-front from index $cnt down to 0.
    (local.set $nil (call $__lang_list_str_nil))
    (local.set $tail (local.get $nil))
    (local.set $bi (local.get $cnt))
    (block $end_b
      (loop $lp_b
        (local.set $b_off (i32.mul (local.get $bi) (i32.const 4)))
        (local.set $tstart (i32.load (i32.add (local.get $starts) (local.get $b_off))))
        (local.set $tlen (i32.load (i32.add (local.get $lens) (local.get $b_off))))
        (local.set $tk (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $tk) (i32.add (local.get $tlen) (i32.const 1))))
        ;; memcpy
        (local.set $j (i32.const 0))
        (block $end_cp
          (loop $lp_cp
            (br_if $end_cp (i32.eq (local.get $j) (local.get $tlen)))
            (i32.store8
              (i32.add (local.get $tk) (local.get $j))
              (i32.load8_u (i32.add (local.get $s)
                                    (i32.add (local.get $tstart) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_cp)))
        (i32.store8 (i32.add (local.get $tk) (local.get $tlen)) (i32.const 0))
        (local.set $tail (call $__lang_list_str_cons (local.get $tk) (local.get $tail)))
        (br_if $end_b (i32.eqz (local.get $bi)))
        (local.set $bi (i32.sub (local.get $bi) (i32.const 1)))
        (br $lp_b)))
    (local.get $tail))
  ;; str_join sep xs — walk list_str, concat with sep.
  (func $__lang_str_join (param $sep i32) (param $xs i32) (result i32)
    (local $sl i32) (local $cur i32) (local $box i32) (local $head i32)
    (local $total i32) (local $first i32) (local $r i32) (local $pos i32)
    (local $hl i32)
    (local.set $sl (call $__lang_strlen (local.get $sep)))
    ;; Pass 1: total length.
    (local.set $cur (local.get $xs))
    (local.set $total (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_len
      (loop $lp_len
        (br_if $end_len (i32.eqz (i32.load offset=0 (local.get $cur))))
        (local.set $box (i32.load offset=4 (local.get $cur)))
        (local.set $head (i32.load offset=0 (local.get $box)))
        (if (i32.eqz (local.get $first))
          (then (local.set $total (i32.add (local.get $total) (local.get $sl)))))
        (local.set $total
          (i32.add (local.get $total)
                   (call $__lang_strlen (local.get $head))))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.load offset=4 (local.get $box)))
        (br $lp_len)))
    ;; Allocate result + null terminator.
    (local.set $r (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (local.get $r) (i32.add (local.get $total) (i32.const 1))))
    ;; Pass 2: write.
    (local.set $cur (local.get $xs))
    (local.set $pos (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_w
      (loop $lp_w
        (br_if $end_w (i32.eqz (i32.load offset=0 (local.get $cur))))
        (local.set $box (i32.load offset=4 (local.get $cur)))
        (local.set $head (i32.load offset=0 (local.get $box)))
        (if (i32.eqz (local.get $first))
          (then
            ;; memcpy sep.
            (local.set $hl (i32.const 0))
            (block $end_cs
              (loop $lp_cs
                (br_if $end_cs (i32.eq (local.get $hl) (local.get $sl)))
                (i32.store8
                  (i32.add (local.get $r) (i32.add (local.get $pos) (local.get $hl)))
                  (i32.load8_u (i32.add (local.get $sep) (local.get $hl))))
                (local.set $hl (i32.add (local.get $hl) (i32.const 1)))
                (br $lp_cs)))
            (local.set $pos (i32.add (local.get $pos) (local.get $sl)))))
        ;; memcpy head.
        (local.set $hl (call $__lang_strlen (local.get $head)))
        (local.set $first (i32.const 0))
        (block $end_ch
          (local.set $first (i32.const 0))
          (loop $lp_ch
            (local.tee $first (i32.const 0))
            (drop)
            (br_if $end_ch (i32.eqz (local.get $hl)))
            (i32.store8
              (i32.add (local.get $r) (local.get $pos))
              (i32.load8_u (local.get $head)))
            (local.set $head (i32.add (local.get $head) (i32.const 1)))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (local.set $hl (i32.sub (local.get $hl) (i32.const 1)))
            (br $lp_ch)))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.load offset=4 (local.get $box)))
        (br $lp_w)))
    (i32.store8 (i32.add (local.get $r) (local.get $total)) (i32.const 0))
    (local.get $r))
  ;; str_count s n — non-overlapping count of n in s.
  (func $__lang_str_count (param $s i32) (param $n i32) (result i32)
    (local $sl i32) (local $nl i32) (local $i i32) (local $j i32)
    (local $acc i32) (local $match i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $nl (call $__lang_strlen (local.get $n)))
    (if (i32.eqz (local.get $nl)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (local.set $acc (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end
               (i32.gt_s (i32.add (local.get $i) (local.get $nl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $acc (i32.add (local.get $acc) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $nl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp)))
    (local.get $acc))
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
    (local.get $new))
  (func $__lang_bytes_alloc (param $len i32) (result i32)
    (local $b i32)
    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 3)) (i32.const -4)))
    (local.set $b (global.get $__lang_bump))
    (i32.store (local.get $b) (local.get $len))
    (global.set $__lang_bump (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $len)))
    (local.get $b))
  (func $__lang_bytes_get (param $b i32) (param $i i32) (result i32)
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (i32.load (local.get $b))))
      (then (unreachable)))
    (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
  (func $__lang_bytes_of_str (param $s i32) (result i32)
    (local $n i32) (local $b i32) (local $i i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $b (call $__lang_bytes_alloc (local.get $n)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $b))
  (func $__lang_str_of_bytes (param $b i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32)
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (local.get $r) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $n)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $n)) (i32.const 1)))
    (local.get $r))
  (func $__lang_hexchar (param $d i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $d) (i32.const 10))
      (then (i32.add (local.get $d) (i32.const 48)))
      (else (i32.add (local.get $d) (i32.const 87)))))
  (func $__lang_hex_of_bytes (param $b i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32) (local $byte i32)
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (local.set $byte (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2)))
                  (call $__lang_hexchar (i32.shr_u (local.get $byte) (i32.const 4))))
      (i32.store8 (i32.add (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2))) (i32.const 1))
                  (call $__lang_hexchar (i32.and (local.get $byte) (i32.const 15))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 1)))
    (local.get $r))
  (func $__lang_hexval (param $c i32) (result i32)
    (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 48)) (i32.le_s (local.get $c) (i32.const 57)))
      (then (i32.sub (local.get $c) (i32.const 48)))
      (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 97)) (i32.le_s (local.get $c) (i32.const 102)))
        (then (i32.sub (local.get $c) (i32.const 87)))
        (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 65)) (i32.le_s (local.get $c) (i32.const 70)))
          (then (i32.sub (local.get $c) (i32.const 55)))
          (else (unreachable))))))))
  (func $__lang_bytes_of_hex (param $h i32) (result i32)
    (local $half i32) (local $b i32) (local $i i32)
    (local.set $half (i32.div_u (call $__lang_strlen (local.get $h)) (i32.const 2)))
    (local.set $b (call $__lang_bytes_alloc (local.get $half)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $half)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
        (i32.add
          (i32.mul (call $__lang_hexval (i32.load8_u (i32.add (local.get $h) (i32.mul (local.get $i) (i32.const 2))))) (i32.const 16))
          (call $__lang_hexval (i32.load8_u (i32.add (local.get $h) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $b))
  (func $__lang_bytes_slice (param $b i32) (param $start i32) (param $len i32) (result i32)
    (local $o i32) (local $i i32)
    (local.set $o (call $__lang_bytes_alloc (local.get $len)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $start)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.get $o))
  (func $__lang_bytes_concat (param $a i32) (param $b i32) (result i32)
    (local $alen i32) (local $blen i32) (local $o i32) (local $i i32)
    (local.set $alen (i32.load (local.get $a)))
    (local.set $blen (i32.load (local.get $b)))
    (local.set $o (call $__lang_bytes_alloc (i32.add (local.get $alen) (local.get $blen))))
    (local.set $i (i32.const 0))
    (block $ea (loop $la
      (br_if $ea (i32.eq (local.get $i) (local.get $alen)))
      (i32.store8 (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $a) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $la)))
    (local.set $i (i32.const 0))
    (block $eb (loop $lb
      (br_if $eb (i32.eq (local.get $i) (local.get $blen)))
      (i32.store8 (i32.add (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $alen)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lb)))
    (local.get $o))
  (func $handle_key (param i32) (result i32)
    (local i32)
    local.get 0
    i32.const 16
    call $__lang_streq
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 18
    call $__lang_streq
    if (result i32)
    i32.const 2
    else
    local.get 0
    i32.const 20
    call $__lang_streq
    if (result i32)
    i32.const 3
    else
    local.get 0
    i32.const 22
    call $__lang_streq
    if (result i32)
    i32.const 12
    else
    local.get 0
    i32.const 24
    call $__lang_streq
    if (result i32)
    i32.const 4
    else
    local.get 0
    i32.const 26
    call $__lang_streq
    if (result i32)
    i32.const 5
    else
    local.get 0
    i32.const 28
    call $__lang_streq
    if (result i32)
    i32.const 6
    else
    local.get 0
    i32.const 30
    call $__lang_streq
    if (result i32)
    i32.const 13
    else
    local.get 0
    i32.const 32
    call $__lang_streq
    if (result i32)
    i32.const 7
    else
    local.get 0
    i32.const 34
    call $__lang_streq
    if (result i32)
    i32.const 8
    else
    local.get 0
    i32.const 36
    call $__lang_streq
    if (result i32)
    i32.const 9
    else
    local.get 0
    i32.const 38
    call $__lang_streq
    if (result i32)
    i32.const 14
    else
    local.get 0
    i32.const 40
    call $__lang_streq
    if (result i32)
    i32.const 10
    else
    local.get 0
    i32.const 42
    call $__lang_streq
    if (result i32)
    i32.const 0
    else
    local.get 0
    i32.const 44
    call $__lang_streq
    if (result i32)
    i32.const 11
    else
    local.get 0
    i32.const 46
    call $__lang_streq
    if (result i32)
    i32.const 15
    else
    i32.const 0
    i32.const 1
    i32.sub
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    local.set 1
    local.get 1
    i32.const 0
    i32.ge_s
    if (result i32)
    global.get $keys
    local.get 1
    i32.const 1
    call $mere_vec_set
    else
    i32.const 0
    end)
  (func $frame (param i32) (result i32)
    (local i32)
    global.get $mem
    global.get $v
    global.get $reg
    global.get $stack
    global.get $disp
    global.get $rng
    global.get $keys
    i32.const 12
    call $__lifted_run_0
    drop
    global.get $reg
    i32.const 3
    call $mere_vec_get
    local.set 1
    local.get 1
    i32.const 0
    i32.gt_s
    if (result i32)
    global.get $reg
    i32.const 3
    local.get 1
    i32.const 1
    i32.sub
    call $mere_vec_set
    else
    i32.const 0
    end
    drop
    i32.const 0
    return_call $render)
  (func $render (param i32) (result i32)
    global.get $screen
    i32.const 48
    call $dom_canvas_fill_style
    i32.const 0
    drop
    global.get $screen
    i32.const 0
    i32.const 0
    i32.const 512
    i32.const 256
    call $dom_canvas_fill_rect
    i32.const 0
    drop
    global.get $screen
    i32.const 56
    call $dom_canvas_fill_style
    i32.const 0
    drop
    global.get $disp
    global.get $screen
    global.get $scale
    i32.const 0
    return_call $__lifted_go_1)
  (func $step (param i32) (result i32)
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
    i32.const 28
    i32.store offset=4
    local.get 2)
  (func $rng_next (param i32) (result i32)
    (local i32)
    local.get 0
    i32.const 0
    call $mere_vec_get
    i32.const 25173
    i32.mul
    i32.const 13849
    i32.add
    i32.const 65535
    i32.and
    local.set 1
    local.get 0
    i32.const 0
    local.get 1
    call $mere_vec_set
    drop
    local.get 1
    i32.const 8
    i32.shr_s
    i32.const 255
    i32.and)
  (func $draw (param i32) (result i32)
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
    i32.const 29
    i32.store offset=4
    local.get 2)
  (func $seti (param i32) (result i32)
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
    i32.const 30
    i32.store offset=4
    local.get 2)
  (func $geti (param i32) (result i32)
    local.get 0
    i32.const 1
    call $mere_vec_get)
  (func $blit_bytes (param i32) (result i32)
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
    i32.const 31
    i32.store offset=4
    local.get 2)
  (func $new_vec (param i32) (result i32)
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
    i32.const 32
    i32.store offset=4
    local.get 2)
  (func $mask12 (param i32) (result i32)
    local.get 0
    i32.const 4095
    i32.and)
  (func $mask8 (param i32) (result i32)
    local.get 0
    i32.const 255
    i32.and)
  (func $pad_left (param i32) (result i32)
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
    i32.const 33
    i32.store offset=4
    local.get 2)
  (func $pad_right (param i32) (result i32)
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
    i32.const 34
    i32.store offset=4
    local.get 2)
  (func $utf8_width (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    call $_u8w_go
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
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_u8w_go (param i32) (result i32)
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
  (func $_eaw_width (param i32) (result i32)
    local.get 0
    i32.const 768
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 879
    i32.le_s
    else
    i32.const 0
    end
    if (result i32)
    i32.const 0
    else
    local.get 0
    i32.const 12351
    i32.eq
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 4352
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 4447
    i32.le_s
    else
    i32.const 0
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 11904
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 42191
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 43360
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 43391
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 44032
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 55203
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 63744
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 64255
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 65040
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 65049
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 65072
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 65135
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 65280
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 65376
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 65504
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 65510
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 127744
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 128767
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 129280
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 129535
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 1
    else
    local.get 0
    i32.const 131072
    i32.ge_s
    if (result i32)
    local.get 0
    i32.const 262141
    i32.le_s
    else
    i32.const 0
    end
    end
    if (result i32)
    i32.const 2
    else
    i32.const 1
    end
    end
    end)
  (func $utf8_rev (param i32) (result i32)
    (local i32)
    local.get 0
    call $__lang_utf8_chars
    call $_u8_rev_join
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 64
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_u8_rev_join (param i32) (result i32)
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
  (func $utf8_sub (param i32) (result i32)
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
  (func $_u8_slice (param i32) (result i32)
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
  (func $utf8_at (param i32) (result i32)
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
  (func $_u8_nth (param i32) (result i32)
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
    i32.const 41
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
    i32.const 42
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
    i32.const 43
    i32.store offset=4
    local.get 2)
  (func $_range_down (param i32) (result i32)
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
    i32.const 45
    i32.store offset=4
    local.get 2)
  (func $__lifted_go_7 (param i32) (param i32) (param i32) (param i32) (result i32)
    local.get 3
    local.get 0
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 1
    local.get 2
    call $mere_vec_push
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    i32.const 1
    i32.add
    return_call $__lifted_go_7
    end)
  (func $__lifted_go_6 (param i32) (param i32) (param i32) (param i32) (param i32) (result i32)
    local.get 4
    local.get 0
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 1
    local.get 2
    local.get 4
    i32.add
    local.get 3
    local.get 4
    call $__lang_bytes_get
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    i32.const 1
    i32.add
    return_call $__lifted_go_6
    end)
  (func $__lifted_col_5 (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 6
    i32.const 8
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 0
    i32.const 7
    local.get 6
    i32.sub
    i32.shr_s
    i32.const 1
    i32.and
    local.set 7
    local.get 7
    i32.const 0
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 1
    local.get 6
    i32.add
    i32.const 63
    i32.and
    local.set 8
    local.get 2
    local.get 3
    i32.add
    i32.const 31
    i32.and
    local.set 9
    local.get 9
    i32.const 64
    i32.mul
    local.get 8
    i32.add
    local.set 10
    local.get 4
    local.get 10
    call $mere_vec_get
    local.set 11
    local.get 11
    i32.const 1
    i32.eq
    if (result i32)
    local.get 5
    i32.const 15
    i32.const 1
    call $mere_vec_set
    else
    i32.const 0
    end
    drop
    local.get 4
    local.get 10
    local.get 11
    i32.const 1
    i32.xor
    call $mere_vec_set
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    local.get 6
    i32.const 1
    i32.add
    return_call $__lifted_col_5
    end)
  (func $__lifted_row_4 (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (result i32)
    (local i32)
    local.get 7
    local.get 0
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 1
    local.get 2
    local.get 7
    i32.add
    call $mere_vec_get
    local.set 8
    local.get 8
    local.get 3
    local.get 4
    local.get 7
    local.get 5
    local.get 6
    i32.const 0
    call $__lifted_col_5
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    local.get 6
    local.get 7
    i32.const 1
    i32.add
    return_call $__lifted_row_4
    end)
  (func $__lifted_cl_3 (param i32) (param i32) (result i32)
    local.get 1
    i32.const 2048
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 0
    local.get 1
    i32.const 0
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    i32.const 1
    i32.add
    return_call $__lifted_cl_3
    end)
  (func $__lifted_skip_2 (param i32) (param i32) (result i32)
    local.get 0
    i32.const 0
    local.get 0
    i32.const 0
    call $mere_vec_get
    i32.const 2
    i32.add
    call $mask12
    call $mere_vec_set)
  (func $__lifted_go_1 (param i32) (param i32) (param i32) (param i32) (result i32)
    local.get 3
    i32.const 2048
    i32.ge_s
    if (result i32)
    i32.const 0
    else
    local.get 0
    local.get 3
    call $mere_vec_get
    i32.const 1
    i32.eq
    if (result i32)
    local.get 1
    local.get 3
    i32.const 63
    i32.and
    local.get 2
    i32.mul
    local.get 3
    i32.const 64
    i32.div_s
    local.get 2
    i32.mul
    local.get 2
    local.get 2
    call $dom_canvas_fill_rect
    i32.const 0
    else
    i32.const 0
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    i32.const 1
    i32.add
    return_call $__lifted_go_1
    end)
  (func $__lifted_run_0 (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32)
    local.get 7
    i32.const 0
    i32.le_s
    if (result i32)
    i32.const 0
    else
    local.get 0
    call $step
    local.set 13
    local.get 13
    i32.load offset=0
    local.get 1
    local.get 13
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.load offset=0
    local.get 2
    local.get 12
    i32.load offset=4
    call_indirect (type $cl)
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
    local.get 5
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 6
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    local.get 6
    local.get 7
    i32.const 1
    i32.sub
    return_call $__lifted_run_0
    end)
  (func $handle_key_closure (param i32) (param i32) (result i32)
    local.get 1
    call $handle_key)
  (func $frame_closure (param i32) (param i32) (result i32)
    local.get 1
    call $frame)
  (func $render_closure (param i32) (param i32) (result i32)
    local.get 1
    call $render)
  (func $step_closure (param i32) (param i32) (result i32)
    local.get 1
    call $step)
  (func $rng_next_closure (param i32) (param i32) (result i32)
    local.get 1
    call $rng_next)
  (func $draw_closure (param i32) (param i32) (result i32)
    local.get 1
    call $draw)
  (func $seti_closure (param i32) (param i32) (result i32)
    local.get 1
    call $seti)
  (func $geti_closure (param i32) (param i32) (result i32)
    local.get 1
    call $geti)
  (func $blit_bytes_closure (param i32) (param i32) (result i32)
    local.get 1
    call $blit_bytes)
  (func $new_vec_closure (param i32) (param i32) (result i32)
    local.get 1
    call $new_vec)
  (func $mask12_closure (param i32) (param i32) (result i32)
    local.get 1
    call $mask12)
  (func $mask8_closure (param i32) (param i32) (result i32)
    local.get 1
    call $mask8)
  (func $pad_left_closure (param i32) (param i32) (result i32)
    local.get 1
    call $pad_left)
  (func $pad_right_closure (param i32) (param i32) (result i32)
    local.get 1
    call $pad_right)
  (func $utf8_width_closure (param i32) (param i32) (result i32)
    local.get 1
    call $utf8_width)
  (func $_u8w_go_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_u8w_go)
  (func $_eaw_width_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_eaw_width)
  (func $utf8_rev_closure (param i32) (param i32) (result i32)
    local.get 1
    call $utf8_rev)
  (func $_u8_rev_join_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_u8_rev_join)
  (func $utf8_sub_closure (param i32) (param i32) (result i32)
    local.get 1
    call $utf8_sub)
  (func $_u8_slice_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_u8_slice)
  (func $utf8_at_closure (param i32) (param i32) (result i32)
    local.get 1
    call $utf8_at)
  (func $_u8_nth_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_u8_nth)
  (func $list_product_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_product)
  (func $list_sum_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_sum)
  (func $range_closure (param i32) (param i32) (result i32)
    local.get 1
    call $range)
  (func $_range_down_closure (param i32) (param i32) (result i32)
    local.get 1
    call $_range_down)
  (func $list_fold_closure (param i32) (param i32) (result i32)
    local.get 1
    call $list_fold)
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
    i32.const 46
    i32.store offset=4
    local.get 4)
  (func $anon_18_fn (param i32) (param i32) (result i32)
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
  (func $anon_16_fn (param i32) (param i32) (result i32)
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
    i32.const 47
    i32.store offset=4
    local.get 4)
  (func $anon_19_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    local.get 3
    i32.lt_s
    if (result i32)
    local.get 1
    else
    local.get 3
    call $_range_down
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.sub
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.load offset=0
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
    local.get 2
    i32.store offset=0
    local.get 7
    local.get 1
    i32.store offset=4
    local.get 7
    i32.store offset=4
    local.get 6
    local.get 4
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
  (func $anon_15_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    call $_range_down
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
    local.get 3
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_14_fn (param i32) (param i32) (result i32)
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
    i32.const 48
    i32.store offset=4
    local.get 3)
  (func $anon_20_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.add)
  (func $anon_13_fn (param i32) (param i32) (result i32)
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
    i32.const 49
    i32.store offset=4
    local.get 3)
  (func $anon_21_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.mul)
  (func $anon_12_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    i32.const 298
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
    local.get 1
    i32.const 0
    i32.eq
    if (result i32)
    local.get 8
    else
    local.get 10
    call $_u8_nth
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 1
    i32.const 1
    i32.sub
    local.get 15
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    else
    unreachable
    end
    end)
  (func $anon_11_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    call $__lang_utf8_chars
    call $_u8_nth
    local.set 3
    local.get 3
    i32.load offset=0
    local.get 1
    local.get 3
    i32.load offset=4
    return_call_indirect (type $cl))
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
    i32.const 50
    i32.store offset=4
    local.get 4)
  (func $anon_22_fn (param i32) (param i32) (result i32)
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
    i32.const 51
    i32.store offset=4
    local.get 5)
  (func $anon_23_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    local.set 5
    local.get 5
    i32.load offset=0
    i32.const 0
    i32.eq
    local.set 6
    local.get 6
    if (result i32)
    local.get 1
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
    local.get 3
    i32.const 0
    i32.gt_s
    if (result i32)
    local.get 12
    call $_u8_slice
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 3
    i32.const 1
    i32.sub
    local.get 19
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.load offset=0
    local.get 4
    local.get 18
    i32.load offset=4
    call_indirect (type $cl)
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 1
    local.get 17
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 4
    i32.const 0
    i32.gt_s
    if (result i32)
    local.get 12
    call $_u8_slice
    local.set 22
    local.get 22
    i32.load offset=0
    i32.const 0
    local.get 22
    i32.load offset=4
    call_indirect (type $cl)
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 4
    i32.const 1
    i32.sub
    local.get 21
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.load offset=0
    local.get 1
    local.get 10
    call $__lang_str_concat
    local.get 20
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    end
    end
    else
    unreachable
    end
    end)
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
    i32.const 52
    i32.store offset=4
    local.get 4)
  (func $anon_24_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    call $__lang_utf8_chars
    call $_u8_slice
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 3
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 1
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 299
    local.get 4
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_8_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    call $_u8_rev_join
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 8
    local.get 1
    call $__lang_str_concat
    local.get 15
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_7_fn (param i32) (param i32) (result i32)
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
    i32.const 53
    i32.store offset=4
    local.get 4)
  (func $anon_25_fn (param i32) (param i32) (result i32)
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
    local.get 1
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
    i32.const 54
    i32.store offset=4
    local.get 5)
  (func $anon_26_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    local.get 3
    i32.ge_s
    if (result i32)
    local.get 1
    else
    local.get 4
    local.get 2
    call $__lang_char_at
    i32.load8_u
    local.set 5
    local.get 5
    i32.const 194
    i32.lt_s
    if (result i32)
    local.get 4
    call $_u8w_go
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
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
    local.get 1
    i32.const 1
    i32.add
    local.get 6
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 5
    i32.const 224
    i32.lt_s
    if (result i32)
    local.get 2
    i32.const 1
    i32.add
    local.get 3
    i32.lt_s
    if (result i32)
    local.get 4
    call $_u8w_go
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 2
    i32.const 2
    i32.add
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.load offset=0
    local.get 3
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 1
    local.get 5
    i32.const 32
    i32.rem_s
    i32.const 64
    i32.mul
    local.get 4
    local.get 2
    i32.const 1
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.add
    call $_eaw_width
    i32.add
    local.get 9
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i32.const 1
    i32.add
    end
    else
    local.get 5
    i32.const 240
    i32.lt_s
    if (result i32)
    local.get 2
    i32.const 2
    i32.add
    local.get 3
    i32.lt_s
    if (result i32)
    local.get 4
    call $_u8w_go
    local.set 14
    local.get 14
    i32.load offset=0
    local.get 2
    i32.const 3
    i32.add
    local.get 14
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.load offset=0
    local.get 3
    local.get 13
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.load offset=0
    local.get 1
    local.get 5
    i32.const 16
    i32.rem_s
    i32.const 4096
    i32.mul
    local.get 4
    local.get 2
    i32.const 1
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.const 64
    i32.mul
    i32.add
    local.get 4
    local.get 2
    i32.const 2
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.add
    call $_eaw_width
    i32.add
    local.get 12
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i32.const 1
    i32.add
    end
    else
    local.get 2
    i32.const 3
    i32.add
    local.get 3
    i32.lt_s
    if (result i32)
    local.get 4
    call $_u8w_go
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 2
    i32.const 4
    i32.add
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.load offset=0
    local.get 3
    local.get 16
    i32.load offset=4
    call_indirect (type $cl)
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 1
    local.get 5
    i32.const 8
    i32.rem_s
    i32.const 262144
    i32.mul
    local.get 4
    local.get 2
    i32.const 1
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.const 4096
    i32.mul
    i32.add
    local.get 4
    local.get 2
    i32.const 2
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.const 64
    i32.mul
    i32.add
    local.get 4
    local.get 2
    i32.const 3
    i32.add
    call $__lang_char_at
    i32.load8_u
    i32.const 64
    i32.rem_s
    i32.add
    call $_eaw_width
    i32.add
    local.get 15
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i32.const 1
    i32.add
    end
    end
    end
    end
    end)
  (func $anon_6_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    local.get 2
    call $utf8_width
    i32.sub
    local.set 3
    local.get 3
    i32.const 0
    i32.le_s
    if (result i32)
    local.get 2
    else
    local.get 2
    i32.const 300
    local.get 3
    call $__lang_str_repeat
    call $__lang_str_concat
    end)
  (func $anon_5_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 1
    local.get 2
    call $utf8_width
    i32.sub
    local.set 3
    local.get 3
    i32.const 0
    i32.le_s
    if (result i32)
    local.get 2
    else
    i32.const 302
    local.get 3
    call $__lang_str_repeat
    local.get 2
    call $__lang_str_concat
    end)
  (func $anon_4_fn (param i32) (param i32) (result i32)
    (local i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    call $mere_vec_new
    local.set 3
    local.get 2
    local.get 3
    local.get 1
    i32.const 0
    call $__lifted_go_7
    drop
    local.get 3)
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
    i32.const 55
    i32.store offset=4
    local.get 4)
  (func $anon_27_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 1
    i32.load
    local.set 4
    local.get 4
    local.get 2
    local.get 3
    local.get 1
    i32.const 0
    return_call $__lifted_go_6)
  (func $anon_2_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    i32.const 1
    local.get 1
    call $mask12
    call $mere_vec_set)
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
    i32.const 56
    i32.store offset=4
    local.get 4)
  (func $anon_28_fn (param i32) (param i32) (result i32)
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
    i32.const 57
    i32.store offset=4
    local.get 5)
  (func $anon_29_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 2
    i32.store offset=0
    local.get 5
    local.get 3
    i32.store offset=4
    local.get 5
    local.get 4
    i32.store offset=8
    local.get 5
    local.get 1
    i32.store offset=12
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 6
    local.get 5
    i32.store offset=0
    local.get 6
    i32.const 58
    i32.store offset=4
    local.get 6)
  (func $anon_30_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    local.get 0
    i32.load offset=12
    local.set 5
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 20
    i32.add
    global.set $__lang_bump
    local.get 6
    local.get 2
    i32.store offset=0
    local.get 6
    local.get 3
    i32.store offset=4
    local.get 6
    local.get 4
    i32.store offset=8
    local.get 6
    local.get 1
    i32.store offset=12
    local.get 6
    local.get 5
    i32.store offset=16
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 6
    i32.store offset=0
    local.get 7
    i32.const 59
    i32.store offset=4
    local.get 7)
  (func $anon_31_fn (param i32) (param i32) (result i32)
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
    local.get 0
    i32.load offset=12
    local.set 5
    local.get 0
    i32.load offset=16
    local.set 6
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 2
    i32.store offset=0
    local.get 7
    local.get 3
    i32.store offset=4
    local.get 7
    local.get 4
    i32.store offset=8
    local.get 7
    local.get 5
    i32.store offset=12
    local.get 7
    local.get 1
    i32.store offset=16
    local.get 7
    local.get 6
    i32.store offset=20
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 8
    local.get 7
    i32.store offset=0
    local.get 8
    i32.const 60
    i32.store offset=4
    local.get 8)
  (func $anon_32_fn (param i32) (param i32) (result i32)
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
    local.get 0
    i32.load offset=12
    local.set 5
    local.get 0
    i32.load offset=16
    local.set 6
    local.get 0
    i32.load offset=20
    local.set 7
    local.get 2
    call $geti
    local.set 8
    local.get 3
    i32.const 15
    i32.const 0
    call $mere_vec_set
    drop
    local.get 1
    local.get 4
    local.get 8
    local.get 5
    local.get 6
    local.get 7
    local.get 3
    i32.const 0
    return_call $__lifted_row_4)
  (func $anon_0_fn (param i32) (param i32) (result i32)
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
    i32.const 61
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
    i32.const 62
    i32.store offset=4
    local.get 5)
  (func $anon_34_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 2
    i32.store offset=0
    local.get 5
    local.get 3
    i32.store offset=4
    local.get 5
    local.get 4
    i32.store offset=8
    local.get 5
    local.get 1
    i32.store offset=12
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 6
    local.get 5
    i32.store offset=0
    local.get 6
    i32.const 63
    i32.store offset=4
    local.get 6)
  (func $anon_35_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    local.get 0
    i32.load offset=12
    local.set 5
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 20
    i32.add
    global.set $__lang_bump
    local.get 6
    local.get 2
    i32.store offset=0
    local.get 6
    local.get 3
    i32.store offset=4
    local.get 6
    local.get 4
    i32.store offset=8
    local.get 6
    local.get 5
    i32.store offset=12
    local.get 6
    local.get 1
    i32.store offset=16
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 6
    i32.store offset=0
    local.get 7
    i32.const 64
    i32.store offset=4
    local.get 7)
  (func $anon_36_fn (param i32) (param i32) (result i32)
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
    local.get 0
    i32.load offset=12
    local.set 5
    local.get 0
    i32.load offset=16
    local.set 6
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 2
    i32.store offset=0
    local.get 7
    local.get 3
    i32.store offset=4
    local.get 7
    local.get 4
    i32.store offset=8
    local.get 7
    local.get 5
    i32.store offset=12
    local.get 7
    local.get 6
    i32.store offset=16
    local.get 7
    local.get 1
    i32.store offset=20
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 8
    local.get 7
    i32.store offset=0
    local.get 8
    i32.const 65
    i32.store offset=4
    local.get 8)
  (func $anon_37_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 0
    i32.load offset=8
    local.set 4
    local.get 0
    i32.load offset=12
    local.set 5
    local.get 0
    i32.load offset=16
    local.set 6
    local.get 0
    i32.load offset=20
    local.set 7
    local.get 2
    i32.const 0
    call $mere_vec_get
    local.set 8
    local.get 3
    local.get 8
    call $mere_vec_get
    i32.const 8
    i32.shl
    local.get 3
    local.get 8
    i32.const 1
    i32.add
    call $mere_vec_get
    i32.or
    local.set 9
    local.get 9
    i32.const 12
    i32.shr_s
    i32.const 15
    i32.and
    local.set 10
    local.get 9
    i32.const 8
    i32.shr_s
    i32.const 15
    i32.and
    local.set 11
    local.get 9
    i32.const 4
    i32.shr_s
    i32.const 15
    i32.and
    local.set 12
    local.get 9
    i32.const 15
    i32.and
    local.set 13
    local.get 9
    i32.const 255
    i32.and
    local.set 14
    local.get 9
    i32.const 4095
    i32.and
    local.set 15
    local.get 4
    local.get 11
    call $mere_vec_get
    local.set 16
    local.get 4
    local.get 12
    call $mere_vec_get
    local.set 17
    local.get 2
    i32.const 0
    local.get 8
    i32.const 2
    i32.add
    call $mask12
    call $mere_vec_set
    drop
    local.get 10
    i32.const 0
    i32.eq
    if (result i32)
    local.get 9
    i32.const 238
    i32.eq
    if (result i32)
    local.get 2
    i32.const 2
    call $mere_vec_get
    i32.const 1
    i32.sub
    local.set 18
    local.get 2
    i32.const 2
    local.get 18
    call $mere_vec_set
    drop
    local.get 2
    i32.const 0
    local.get 5
    local.get 18
    call $mere_vec_get
    call $mere_vec_set
    else
    local.get 9
    i32.const 224
    i32.eq
    if (result i32)
    local.get 6
    i32.const 0
    return_call $__lifted_cl_3
    else
    i32.const 0
    end
    end
    else
    local.get 10
    i32.const 1
    i32.eq
    if (result i32)
    local.get 2
    i32.const 0
    local.get 15
    call $mere_vec_set
    else
    local.get 10
    i32.const 2
    i32.eq
    if (result i32)
    local.get 2
    i32.const 2
    call $mere_vec_get
    local.set 19
    local.get 5
    local.get 19
    local.get 2
    i32.const 0
    call $mere_vec_get
    call $mere_vec_set
    drop
    local.get 2
    i32.const 2
    local.get 19
    i32.const 1
    i32.add
    call $mere_vec_set
    drop
    local.get 2
    i32.const 0
    local.get 15
    call $mere_vec_set
    else
    local.get 10
    i32.const 3
    i32.eq
    if (result i32)
    local.get 16
    local.get 14
    i32.eq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    else
    i32.const 0
    end
    else
    local.get 10
    i32.const 4
    i32.eq
    if (result i32)
    local.get 16
    local.get 14
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    end
    else
    local.get 10
    i32.const 5
    i32.eq
    if (result i32)
    local.get 16
    local.get 17
    i32.eq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    else
    i32.const 0
    end
    else
    local.get 10
    i32.const 6
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 14
    call $mere_vec_set
    else
    local.get 10
    i32.const 7
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 16
    local.get 14
    i32.add
    call $mask8
    call $mere_vec_set
    else
    local.get 10
    i32.const 8
    i32.eq
    if (result i32)
    local.get 13
    i32.const 0
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 17
    call $mere_vec_set
    else
    local.get 13
    i32.const 1
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 16
    local.get 17
    i32.or
    call $mere_vec_set
    else
    local.get 13
    i32.const 2
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 16
    local.get 17
    i32.and
    call $mere_vec_set
    else
    local.get 13
    i32.const 3
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 16
    local.get 17
    i32.xor
    call $mere_vec_set
    else
    local.get 13
    i32.const 4
    i32.eq
    if (result i32)
    local.get 16
    local.get 17
    i32.add
    local.set 20
    local.get 4
    i32.const 15
    local.get 20
    i32.const 255
    i32.gt_s
    if (result i32)
    i32.const 1
    else
    i32.const 0
    end
    call $mere_vec_set
    drop
    local.get 4
    local.get 11
    local.get 20
    call $mask8
    call $mere_vec_set
    else
    local.get 13
    i32.const 5
    i32.eq
    if (result i32)
    local.get 4
    i32.const 15
    local.get 16
    local.get 17
    i32.ge_s
    if (result i32)
    i32.const 1
    else
    i32.const 0
    end
    call $mere_vec_set
    drop
    local.get 4
    local.get 11
    local.get 16
    local.get 17
    i32.sub
    call $mask8
    call $mere_vec_set
    else
    local.get 13
    i32.const 6
    i32.eq
    if (result i32)
    local.get 4
    i32.const 15
    local.get 16
    i32.const 1
    i32.and
    call $mere_vec_set
    drop
    local.get 4
    local.get 11
    local.get 16
    i32.const 1
    i32.shr_s
    call $mere_vec_set
    else
    local.get 13
    i32.const 7
    i32.eq
    if (result i32)
    local.get 4
    i32.const 15
    local.get 17
    local.get 16
    i32.ge_s
    if (result i32)
    i32.const 1
    else
    i32.const 0
    end
    call $mere_vec_set
    drop
    local.get 4
    local.get 11
    local.get 17
    local.get 16
    i32.sub
    call $mask8
    call $mere_vec_set
    else
    local.get 4
    i32.const 15
    local.get 16
    i32.const 7
    i32.shr_s
    i32.const 1
    i32.and
    call $mere_vec_set
    drop
    local.get 4
    local.get 11
    local.get 16
    i32.const 1
    i32.shl
    call $mask8
    call $mere_vec_set
    end
    end
    end
    end
    end
    end
    end
    end
    else
    local.get 10
    i32.const 9
    i32.eq
    if (result i32)
    local.get 16
    local.get 17
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    end
    else
    local.get 10
    i32.const 10
    i32.eq
    if (result i32)
    local.get 2
    call $seti
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 15
    local.get 21
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 10
    i32.const 11
    i32.eq
    if (result i32)
    local.get 2
    i32.const 0
    local.get 4
    i32.const 0
    call $mere_vec_get
    local.get 15
    i32.add
    call $mask12
    call $mere_vec_set
    else
    local.get 10
    i32.const 12
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 7
    call $rng_next
    local.get 14
    i32.and
    call $mere_vec_set
    else
    local.get 10
    i32.const 13
    i32.eq
    if (result i32)
    local.get 3
    call $draw
    local.set 27
    local.get 27
    i32.load offset=0
    local.get 4
    local.get 27
    i32.load offset=4
    call_indirect (type $cl)
    local.set 26
    local.get 26
    i32.load offset=0
    local.get 2
    local.get 26
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.load offset=0
    local.get 6
    local.get 25
    i32.load offset=4
    call_indirect (type $cl)
    local.set 24
    local.get 24
    i32.load offset=0
    local.get 16
    local.get 24
    i32.load offset=4
    call_indirect (type $cl)
    local.set 23
    local.get 23
    i32.load offset=0
    local.get 17
    local.get 23
    i32.load offset=4
    call_indirect (type $cl)
    local.set 22
    local.get 22
    i32.load offset=0
    local.get 13
    local.get 22
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 10
    i32.const 14
    i32.eq
    if (result i32)
    local.get 14
    i32.const 158
    i32.eq
    if (result i32)
    local.get 1
    local.get 16
    call $mere_vec_get
    i32.const 1
    i32.eq
    if (result i32)
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    else
    i32.const 0
    end
    else
    local.get 14
    i32.const 161
    i32.eq
    if (result i32)
    local.get 1
    local.get 16
    call $mere_vec_get
    i32.const 1
    i32.eq
    if (result i32)
    i32.const 0
    else
    local.get 2
    i32.const 0
    return_call $__lifted_skip_2
    end
    else
    i32.const 0
    end
    end
    else
    local.get 10
    i32.const 15
    i32.eq
    if (result i32)
    local.get 14
    i32.const 7
    i32.eq
    if (result i32)
    local.get 4
    local.get 11
    local.get 2
    i32.const 3
    call $mere_vec_get
    call $mere_vec_set
    else
    local.get 14
    i32.const 21
    i32.eq
    if (result i32)
    local.get 2
    i32.const 3
    local.get 16
    call $mere_vec_set
    else
    local.get 14
    i32.const 24
    i32.eq
    if (result i32)
    local.get 2
    i32.const 4
    local.get 16
    call $mere_vec_set
    else
    local.get 14
    i32.const 41
    i32.eq
    if (result i32)
    local.get 2
    call $seti
    local.set 28
    local.get 28
    i32.load offset=0
    local.get 16
    i32.const 5
    i32.mul
    local.get 28
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 14
    i32.const 30
    i32.eq
    if (result i32)
    local.get 2
    call $seti
    local.set 29
    local.get 29
    i32.load offset=0
    local.get 2
    call $geti
    local.get 16
    i32.add
    local.get 29
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    i32.const 0
    end
    end
    end
    end
    end
    else
    i32.const 0
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end
    end)
  (func $show_unit (param $u i32) (result i32)
    (i32.const 65))
  (func $main (export "main") (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    i32.const 4096
    call $new_vec
    local.set 0
    local.get 0
    i32.load offset=0
    i32.const 0
    local.get 0
    i32.load offset=4
    call_indirect (type $cl)
    global.set $mem
    i32.const 16
    call $new_vec
    local.set 1
    local.get 1
    i32.load offset=0
    i32.const 0
    local.get 1
    i32.load offset=4
    call_indirect (type $cl)
    global.set $v
    i32.const 5
    call $new_vec
    local.set 2
    local.get 2
    i32.load offset=0
    i32.const 0
    local.get 2
    i32.load offset=4
    call_indirect (type $cl)
    global.set $reg
    i32.const 16
    call $new_vec
    local.set 3
    local.get 3
    i32.load offset=0
    i32.const 0
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    global.set $stack
    i32.const 2048
    call $new_vec
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 0
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    global.set $disp
    i32.const 1
    call $new_vec
    local.set 5
    local.get 5
    i32.load offset=0
    i32.const 1
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    global.set $rng
    i32.const 16
    call $new_vec
    local.set 6
    local.get 6
    i32.load offset=0
    i32.const 0
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    global.set $keys
    i32.const 68
    i32.const 129
    call $__lang_str_concat
    call $__lang_bytes_of_hex
    local.set 7
    global.get $mem
    call $blit_bytes
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
    local.get 7
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    drop
    i32.const 230
    call $__lang_bytes_of_hex
    local.set 10
    global.get $mem
    call $blit_bytes
    local.set 12
    local.get 12
    i32.load offset=0
    i32.const 512
    local.get 12
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 10
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $reg
    i32.const 0
    i32.const 512
    call $mere_vec_set
    drop
    i32.const 291
    call $dom_get_by_id
    global.set $screen
    i32.const 8
    global.set $scale
    i32.const 0
    call $render
    drop
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 13
    local.get 13
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 13
    i32.const 0
    i32.store offset=0
    local.get 13
    i32.const 0
    i32.store offset=4
    local.get 13
    call $dom_on_key
    i32.const 0
    drop
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 14
    local.get 14
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 14
    i32.const 0
    i32.store offset=0
    local.get 14
    i32.const 1
    i32.store offset=4
    local.get 14
    call $dom_on_frame
    i32.const 0
    drop
    i32.const 65
    call $puts
    i32.const 0)
)

