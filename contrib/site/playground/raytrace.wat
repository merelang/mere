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
  (import "env" "dom_canvas_fill_rect" (func $dom_canvas_fill_rect (param i32) (param i32) (param i32) (param i32) (param i32)))
  (import "env" "dom_on_key" (func $dom_on_key (param i32)))
  (import "env" "dom_on_click" (func $dom_on_click (param i32) (param i32)))
  (import "env" "dom_set_text" (func $dom_set_text (param i32) (param i32)))
  (memory (export "memory") 1024)
  (table 93 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $main_page_closure $row_loop_closure $px_loop_closure $put_px_closure $quant_closure $clamp01_closure $ray_dir_closure $trace_closure $sky_closure $shade_closure $spec_pow32_closure $nearest_closure $sph_hit_closure $sph_mirror_closure $sph_albedo_closure $sph_radius_closure $sph_center_closure $v_reflect_closure $v_unit_closure $v_dot_closure $v_scale_closure $v_mulv_closure $v_sub_closure $v_add_closure $adler_byte_closure $pad_left_closure $pad_right_closure $utf8_width_closure $_u8w_go_closure $_eaw_width_closure $utf8_rev_closure $_u8_rev_join_closure $utf8_sub_closure $_u8_slice_closure $utf8_at_closure $_u8_nth_closure $list_product_closure $list_sum_closure $range_closure $_range_down_closure $list_fold_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn $anon_17_fn $anon_18_fn $anon_19_fn $anon_20_fn $anon_21_fn $anon_22_fn $anon_23_fn $anon_24_fn $anon_25_fn $anon_26_fn $anon_27_fn $anon_28_fn $anon_29_fn $anon_30_fn $anon_31_fn $anon_32_fn $anon_33_fn $anon_34_fn $anon_35_fn $anon_36_fn $anon_37_fn $anon_38_fn $anon_39_fn $anon_40_fn $anon_41_fn $anon_42_fn $anon_43_fn $anon_44_fn $anon_45_fn $anon_46_fn $anon_47_fn $anon_48_fn $anon_49_fn $anon_50_fn $anon_51_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 629))
(global $__rgn_tmp (mut i32) (i32.const 0))
  (global $__lang_char_table i32 (i32.const 117))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (global $img_w (mut i32) (i32.const 0))
  (global $img_h (mut i32) (i32.const 0))
  (global $light_dir (mut i32) (i32.const 0))
  (global $cam (mut i32) (i32.const 0))
  (data (i32.const 16) "rt\00")
  (data (i32.const 19) "status\00")
  (data (i32.const 26) "rendered \00")
  (data (i32.const 36) "x\00")
  (data (i32.const 38) " in Mere/Wasm \e2\80\94 adler=\00")
  (data (i32.const 63) "-\00")
  (data (i32.const 65) " (same as the native backends)\00")
  (data (i32.const 96) "\00")
  (data (i32.const 97) "()\00")
  (data (i32.const 100) "\00")
  (data (i32.const 101) "\00")
  (data (i32.const 102) " \00")
  (data (i32.const 104) " \00")
  (data (i32.const 106) "rgb(\00")
  (data (i32.const 111) ",\00")
  (data (i32.const 113) ",\00")
  (data (i32.const 115) ")\00")

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
    (local.get $acc))  (func $main_page (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32)
    i32.const 16
    call $dom_get_by_id
    local.set 1
    i32.const 19
    call $dom_get_by_id
    local.set 2
    local.get 1
    call $row_loop
    local.set 5
    local.get 5
    i32.load offset=0
    i32.const 0
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
    i32.const 0
    i32.store offset=4
    local.get 6
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 7
    local.get 3
    i32.load offset=4
    local.set 8
    local.get 2
    i32.const 26
    global.get $img_w
    call $show_int
    call $__lang_str_concat
    i32.const 36
    call $__lang_str_concat
    global.get $img_h
    call $show_int
    call $__lang_str_concat
    i32.const 38
    call $__lang_str_concat
    local.get 8
    call $show_int
    call $__lang_str_concat
    i32.const 63
    call $__lang_str_concat
    local.get 7
    call $show_int
    call $__lang_str_concat
    i32.const 65
    call $__lang_str_concat
    call $dom_set_text
    i32.const 0)
  (func $row_loop (param i32) (result i32)
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
  (func $px_loop (param i32) (result i32)
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
  (func $put_px (param i32) (result i32)
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
  (func $quant (param i32) (result i32)
    (local f64 f64)
    f64.const 255.999
    local.set 1
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 1
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 0
    call $clamp01
    f64.load offset=0 align=8
    f64.mul
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    i32.trunc_f64_s)
  (func $clamp01 (param i32) (result i32)
    (local f64 f64 f64 f64)
    local.get 0
    f64.load offset=0 align=8
    f64.const 0
    local.set 1
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 1
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.lt
    if (result i32)
    f64.const 0
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    local.get 0
    f64.load offset=0 align=8
    f64.const 1
    local.set 3
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 3
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.gt
    if (result i32)
    f64.const 1
    local.set 4
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 4
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    local.get 0
    end
    end)
  (func $ray_dir (param i32) (result i32)
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
  (func $trace (param i32) (result i32)
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
  (func $sky (param i32) (result i32)
    (local i32 i32 i32 i32 i32 f64 f64 f64 f64 i32 i32 i32 f64 f64 f64 f64 f64 i32 i32 f64 f64 f64)
    local.get 0
    local.set 1
    local.get 1
    i32.load offset=0
    local.set 2
    local.get 1
    i32.load offset=4
    local.set 3
    local.get 1
    i32.load offset=8
    local.set 4
    local.get 2
    drop
    local.get 4
    drop
    f64.const 0.5
    local.set 6
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 6
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 3
    f64.load offset=0 align=8
    f64.const 1
    local.set 7
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 7
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.mul
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 5
    global.get $__lang_bump
    local.set 12
    local.get 12
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 12
    f64.const 1
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 12
    f64.const 1
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 12
    f64.const 1
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 12
    call $v_scale
    local.set 11
    local.get 11
    i32.load offset=0
    f64.const 1
    local.set 16
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 16
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 5
    f64.load offset=0 align=8
    f64.sub
    local.set 17
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 17
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    call $v_add
    local.set 10
    local.get 10
    i32.load offset=0
    global.get $__lang_bump
    local.set 19
    local.get 19
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 19
    f64.const 0.5
    local.set 20
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 20
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 19
    f64.const 0.69999999999999996
    local.set 21
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 21
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 19
    f64.const 1
    local.set 22
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 22
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 19
    call $v_scale
    local.set 18
    local.get 18
    i32.load offset=0
    local.get 5
    local.get 18
    i32.load offset=4
    call_indirect (type $cl)
    local.get 10
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $shade (param i32) (result i32)
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
  (func $spec_pow32 (param i32) (result i32)
    (local i32 f64 f64 i32 f64 i32 f64 i32 f64 i32 f64 f64)
    local.get 0
    f64.load offset=0 align=8
    f64.const 0
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.lt
    if (result i32)
    f64.const 0
    local.set 3
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 3
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    local.get 0
    end
    local.set 1
    local.get 1
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.mul
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 4
    local.get 4
    f64.load offset=0 align=8
    local.get 4
    f64.load offset=0 align=8
    f64.mul
    local.set 7
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 7
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 6
    local.get 6
    f64.load offset=0 align=8
    local.get 6
    f64.load offset=0 align=8
    f64.mul
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 8
    local.get 8
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.mul
    local.set 11
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 11
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 10
    local.get 10
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.mul
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump)
  (func $nearest (param i32) (result i32)
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
  (func $sph_hit (param i32) (result i32)
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
  (func $sph_mirror (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.eq)
  (func $sph_albedo (param i32) (result i32)
    (local i32 f64 f64 f64 i32 f64 f64 f64 i32 f64 f64 f64 i32 f64 f64 f64)
    local.get 0
    i32.const 0
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 1
    f64.const 0.80000000000000004
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 1
    f64.const 0.80000000000000004
    local.set 3
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 3
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 1
    f64.const 0.20000000000000001
    local.set 4
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 4
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 1
    else
    local.get 0
    i32.const 1
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 5
    f64.const 0.69999999999999996
    local.set 6
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 6
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 5
    f64.const 0.29999999999999999
    local.set 7
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 7
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 5
    f64.const 0.29999999999999999
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 5
    else
    local.get 0
    i32.const 2
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 9
    local.get 9
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 9
    f64.const 0.90000000000000002
    local.set 10
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 10
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 9
    f64.const 0.90000000000000002
    local.set 11
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 11
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 9
    f64.const 0.90000000000000002
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 9
    else
    global.get $__lang_bump
    local.set 13
    local.get 13
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 13
    f64.const 0.29999999999999999
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 13
    f64.const 0.40000000000000002
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 13
    f64.const 0.80000000000000004
    local.set 16
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 16
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 13
    end
    end
    end)
  (func $sph_radius (param i32) (result i32)
    (local f64 f64)
    local.get 0
    i32.const 0
    i32.eq
    if (result i32)
    f64.const 100
    local.set 1
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 1
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    f64.const 0.5
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    end)
  (func $sph_center (param i32) (result i32)
    (local i32 f64 f64 f64 f64 f64 i32 f64 f64 f64 f64 i32 f64 f64 f64 f64 f64 i32 f64 f64 f64 f64)
    local.get 0
    i32.const 0
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 1
    f64.const 0
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 1
    f64.const 100.5
    local.set 3
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 3
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 4
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 4
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 1
    f64.const 1
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 6
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 6
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 1
    else
    local.get 0
    i32.const 1
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 7
    f64.const 0
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 7
    f64.const 0
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 7
    f64.const 1.2
    local.set 10
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 10
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 11
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 11
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 7
    else
    local.get 0
    i32.const 2
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 12
    local.get 12
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 12
    f64.const 1
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 12
    f64.const 0
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 12
    f64.const 1
    local.set 16
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 16
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 17
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 17
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 12
    else
    global.get $__lang_bump
    local.set 18
    local.get 18
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 18
    f64.const 1
    local.set 19
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 19
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 18
    f64.const 0
    local.set 20
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 20
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 18
    f64.const 1
    local.set 21
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 21
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.neg
    local.set 22
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 22
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 18
    end
    end
    end)
  (func $v_reflect (param i32) (result i32)
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
  (func $v_unit (param i32) (result i32)
    (local i32 f64 i32 f64 f64)
    local.get 0
    call $v_scale
    local.set 1
    local.get 1
    i32.load offset=0
    f64.const 1
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 0
    call $v_dot
    local.set 3
    local.get 3
    i32.load offset=0
    local.get 0
    local.get 3
    i32.load offset=4
    call_indirect (type $cl)
    f64.load offset=0 align=8
    f64.sqrt
    local.set 4
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 4
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.div
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $v_dot (param i32) (result i32)
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
    i32.const 50
    i32.store offset=4
    local.get 2)
  (func $v_scale (param i32) (result i32)
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
  (func $v_mulv (param i32) (result i32)
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
  (func $v_sub (param i32) (result i32)
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
    i32.const 53
    i32.store offset=4
    local.get 2)
  (func $v_add (param i32) (result i32)
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
    i32.const 54
    i32.store offset=4
    local.get 2)
  (func $adler_byte (param i32) (result i32)
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
    i32.const 56
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
    i32.const 57
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
    i32.const 58
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
    i32.const 96
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
    i32.const 59
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
    i32.const 60
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
    i32.const 61
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
    i32.const 62
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
    i32.const 63
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
    i32.const 64
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
    i32.const 65
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
    i32.const 66
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
    i32.const 67
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
    i32.const 68
    i32.store offset=4
    local.get 2)
  (func $main_page_closure (param i32) (param i32) (result i32)
    local.get 1
    call $main_page)
  (func $row_loop_closure (param i32) (param i32) (result i32)
    local.get 1
    call $row_loop)
  (func $px_loop_closure (param i32) (param i32) (result i32)
    local.get 1
    call $px_loop)
  (func $put_px_closure (param i32) (param i32) (result i32)
    local.get 1
    call $put_px)
  (func $quant_closure (param i32) (param i32) (result i32)
    local.get 1
    call $quant)
  (func $clamp01_closure (param i32) (param i32) (result i32)
    local.get 1
    call $clamp01)
  (func $ray_dir_closure (param i32) (param i32) (result i32)
    local.get 1
    call $ray_dir)
  (func $trace_closure (param i32) (param i32) (result i32)
    local.get 1
    call $trace)
  (func $sky_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sky)
  (func $shade_closure (param i32) (param i32) (result i32)
    local.get 1
    call $shade)
  (func $spec_pow32_closure (param i32) (param i32) (result i32)
    local.get 1
    call $spec_pow32)
  (func $nearest_closure (param i32) (param i32) (result i32)
    local.get 1
    call $nearest)
  (func $sph_hit_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sph_hit)
  (func $sph_mirror_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sph_mirror)
  (func $sph_albedo_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sph_albedo)
  (func $sph_radius_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sph_radius)
  (func $sph_center_closure (param i32) (param i32) (result i32)
    local.get 1
    call $sph_center)
  (func $v_reflect_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_reflect)
  (func $v_unit_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_unit)
  (func $v_dot_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_dot)
  (func $v_scale_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_scale)
  (func $v_mulv_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_mulv)
  (func $v_sub_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_sub)
  (func $v_add_closure (param i32) (param i32) (result i32)
    local.get 1
    call $v_add)
  (func $adler_byte_closure (param i32) (param i32) (result i32)
    local.get 1
    call $adler_byte)
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
  (func $anon_27_fn (param i32) (param i32) (result i32)
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
    i32.const 69
    i32.store offset=4
    local.get 4)
  (func $anon_28_fn (param i32) (param i32) (result i32)
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
  (func $anon_26_fn (param i32) (param i32) (result i32)
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
  (func $anon_29_fn (param i32) (param i32) (result i32)
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
  (func $anon_25_fn (param i32) (param i32) (result i32)
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
  (func $anon_24_fn (param i32) (param i32) (result i32)
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
    i32.const 71
    i32.store offset=4
    local.get 3)
  (func $anon_30_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.add)
  (func $anon_23_fn (param i32) (param i32) (result i32)
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
    i32.const 72
    i32.store offset=4
    local.get 3)
  (func $anon_31_fn (param i32) (param i32) (result i32)
    (local i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i32.mul)
  (func $anon_22_fn (param i32) (param i32) (result i32)
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
    i32.const 100
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
  (func $anon_21_fn (param i32) (param i32) (result i32)
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
  (func $anon_20_fn (param i32) (param i32) (result i32)
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
    i32.const 73
    i32.store offset=4
    local.get 4)
  (func $anon_32_fn (param i32) (param i32) (result i32)
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
    i32.const 74
    i32.store offset=4
    local.get 5)
  (func $anon_33_fn (param i32) (param i32) (result i32)
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
  (func $anon_19_fn (param i32) (param i32) (result i32)
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
    i32.const 75
    i32.store offset=4
    local.get 4)
  (func $anon_34_fn (param i32) (param i32) (result i32)
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
    i32.const 101
    local.get 4
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_18_fn (param i32) (param i32) (result i32)
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
    i32.const 76
    i32.store offset=4
    local.get 4)
  (func $anon_35_fn (param i32) (param i32) (result i32)
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
    i32.const 77
    i32.store offset=4
    local.get 5)
  (func $anon_36_fn (param i32) (param i32) (result i32)
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
  (func $anon_16_fn (param i32) (param i32) (result i32)
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
    i32.const 102
    local.get 3
    call $__lang_str_repeat
    call $__lang_str_concat
    end)
  (func $anon_15_fn (param i32) (param i32) (result i32)
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
    i32.const 104
    local.get 3
    call $__lang_str_repeat
    local.get 2
    call $__lang_str_concat
    end)
  (func $anon_14_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 4
    local.get 1
    i32.add
    i32.const 65521
    i32.rem_s
    local.set 6
    local.get 5
    local.get 6
    i32.add
    i32.const 65521
    i32.rem_s
    local.set 7
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 8
    local.get 6
    i32.store offset=0
    local.get 8
    local.get 7
    i32.store offset=4
    local.get 8)
  (func $anon_13_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 3
    i32.load offset=8
    local.set 6
    local.get 1
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 8
    local.get 7
    i32.load offset=4
    local.set 9
    local.get 7
    i32.load offset=8
    local.set 10
    global.get $__lang_bump
    local.set 11
    local.get 11
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 11
    local.get 4
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.add
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 11
    local.get 5
    f64.load offset=0 align=8
    local.get 9
    f64.load offset=0 align=8
    f64.add
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 11
    local.get 6
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.add
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 11)
  (func $anon_12_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 3
    i32.load offset=8
    local.set 6
    local.get 1
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 8
    local.get 7
    i32.load offset=4
    local.set 9
    local.get 7
    i32.load offset=8
    local.set 10
    global.get $__lang_bump
    local.set 11
    local.get 11
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 11
    local.get 4
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.sub
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 11
    local.get 5
    f64.load offset=0 align=8
    local.get 9
    f64.load offset=0 align=8
    f64.sub
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 11
    local.get 6
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.sub
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 11)
  (func $anon_11_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 3
    i32.load offset=8
    local.set 6
    local.get 1
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 8
    local.get 7
    i32.load offset=4
    local.set 9
    local.get 7
    i32.load offset=8
    local.set 10
    global.get $__lang_bump
    local.set 11
    local.get 11
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 11
    local.get 4
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.mul
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 11
    local.get 5
    f64.load offset=0 align=8
    local.get 9
    f64.load offset=0 align=8
    f64.mul
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 11
    local.get 6
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.mul
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 11)
  (func $anon_10_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 3
    i32.load offset=8
    local.set 6
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 4
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.mul
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 7
    local.get 5
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.mul
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 7
    local.get 6
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.mul
    local.set 10
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 10
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 7)
  (func $anon_9_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 4
    local.get 3
    i32.load offset=4
    local.set 5
    local.get 3
    i32.load offset=8
    local.set 6
    local.get 1
    local.set 7
    local.get 7
    i32.load offset=0
    local.set 8
    local.get 7
    i32.load offset=4
    local.set 9
    local.get 7
    i32.load offset=8
    local.set 10
    local.get 4
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.mul
    local.set 11
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 11
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 5
    f64.load offset=0 align=8
    local.get 9
    f64.load offset=0 align=8
    f64.mul
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 13
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 13
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 6
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.mul
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump)
  (func $anon_8_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 f64 i32 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 2
    call $v_sub
    local.set 3
    local.get 3
    i32.load offset=0
    local.get 1
    call $v_scale
    local.set 4
    local.get 4
    i32.load offset=0
    f64.const 2
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 2
    call $v_dot
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 1
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    f64.load offset=0 align=8
    f64.mul
    local.set 7
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 7
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.get 3
    i32.load offset=4
    return_call_indirect (type $cl))
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
    i32.const 78
    i32.store offset=4
    local.get 4)
  (func $anon_37_fn (param i32) (param i32) (result i32)
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
    i32.const 79
    i32.store offset=4
    local.get 5)
  (func $anon_38_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 i32 f64 f64 f64 f64 f64 f64 f64 i32 f64 i32 f64 f64 f64 f64 i32 f64 f64 f64 f64 f64 f64 f64)
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
    call $v_sub
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 3
    call $sph_center
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 3
    call $sph_radius
    local.set 7
    local.get 4
    call $v_dot
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 4
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 5
    call $v_dot
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 4
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 5
    call $v_dot
    local.set 13
    local.get 13
    i32.load offset=0
    local.get 5
    local.get 13
    i32.load offset=4
    call_indirect (type $cl)
    f64.load offset=0 align=8
    local.get 7
    f64.load offset=0 align=8
    local.get 7
    f64.load offset=0 align=8
    f64.mul
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 12
    local.get 10
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.mul
    local.set 17
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 17
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    local.get 12
    f64.load offset=0 align=8
    f64.mul
    local.set 18
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 18
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 19
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 19
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 16
    local.get 16
    f64.load offset=0 align=8
    f64.const 0
    local.set 20
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 20
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.lt
    if (result i32)
    f64.const 0
    local.set 21
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 21
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 1
    local.set 22
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 22
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 23
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 23
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    local.get 16
    f64.load offset=0 align=8
    f64.sqrt
    local.set 25
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 25
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 24
    f64.const 0
    local.set 27
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 27
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.sub
    local.set 28
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 28
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 24
    f64.load offset=0 align=8
    f64.sub
    local.set 29
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 29
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.div
    local.set 30
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 30
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 26
    local.get 26
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.gt
    if (result i32)
    local.get 26
    else
    f64.const 0
    local.set 32
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 32
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 10
    f64.load offset=0 align=8
    f64.sub
    local.set 33
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 33
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 24
    f64.load offset=0 align=8
    f64.add
    local.set 34
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 34
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 8
    f64.load offset=0 align=8
    f64.div
    local.set 35
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 35
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 31
    local.get 31
    f64.load offset=0 align=8
    local.get 1
    f64.load offset=0 align=8
    f64.gt
    if (result i32)
    local.get 31
    else
    f64.const 0
    local.set 36
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 36
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 1
    local.set 37
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 37
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 38
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 38
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    end
    end
    end)
  (func $anon_6_fn (param i32) (param i32) (result i32)
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
    i32.const 80
    i32.store offset=4
    local.get 4)
  (func $anon_39_fn (param i32) (param i32) (result i32)
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
    i32.const 81
    i32.store offset=4
    local.get 5)
  (func $anon_40_fn (param i32) (param i32) (result i32)
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
    i32.const 82
    i32.store offset=4
    local.get 6)
  (func $anon_41_fn (param i32) (param i32) (result i32)
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
    local.get 1
    i32.store offset=4
    local.get 6
    local.get 3
    i32.store offset=8
    local.get 6
    local.get 4
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
    i32.const 83
    i32.store offset=4
    local.get 7)
  (func $anon_42_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    local.get 2
    i32.const 4
    i32.eq
    if (result i32)
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 3
    i32.store offset=0
    local.get 7
    local.get 1
    i32.store offset=4
    local.get 7
    else
    local.get 2
    call $sph_hit
    local.set 11
    local.get 11
    i32.load offset=0
    local.get 4
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.load offset=0
    local.get 5
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.load offset=0
    local.get 6
    local.get 9
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    f64.load offset=0 align=8
    f64.const 0
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.gt
    if (result i32)
    local.get 1
    i32.const 0
    i32.lt_s
    if (result i32)
    i32.const 1
    else
    local.get 8
    f64.load offset=0 align=8
    local.get 3
    f64.load offset=0 align=8
    f64.lt
    end
    else
    i32.const 0
    end
    if (result i32)
    local.get 2
    i32.const 1
    i32.add
    call $nearest
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 4
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.load offset=0
    local.get 5
    local.get 16
    i32.load offset=4
    call_indirect (type $cl)
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 6
    local.get 15
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 14
    i32.load offset=0
    local.get 8
    local.get 14
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.load offset=0
    local.get 2
    local.get 13
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 2
    i32.const 1
    i32.add
    call $nearest
    local.set 22
    local.get 22
    i32.load offset=0
    local.get 4
    local.get 22
    i32.load offset=4
    call_indirect (type $cl)
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 5
    local.get 21
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.load offset=0
    local.get 6
    local.get 20
    i32.load offset=4
    call_indirect (type $cl)
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
    local.get 1
    local.get 18
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
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
    i32.const 84
    i32.store offset=4
    local.get 4)
  (func $anon_43_fn (param i32) (param i32) (result i32)
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
    i32.const 85
    i32.store offset=4
    local.get 5)
  (func $anon_44_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 f64 i32 i32 i32 i32 i32 i32 f64 f64 i32 i32 i32 f64 i32 i32 i32 i32 f64 f64 i32 i32 i32 f64 i32 f64 i32 i32 f64 f64 f64 i32 i32)
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
    call $v_add
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 3
    call $v_scale
    local.set 7
    local.get 7
    i32.load offset=0
    f64.const 0.001
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    i32.const 0
    call $nearest
    local.set 14
    local.get 14
    i32.load offset=0
    local.get 5
    local.get 14
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.load offset=0
    global.get $light_dir
    local.get 13
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.load offset=0
    f64.const 0.001
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 12
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.load offset=0
    f64.const 0
    local.set 16
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 16
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 11
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.load offset=0
    i32.const 0
    i32.const 1
    i32.sub
    local.get 10
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.load offset=0
    local.set 17
    local.get 9
    i32.load offset=4
    local.set 18
    local.get 17
    drop
    f64.const 0.14999999999999999
    local.set 20
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 20
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 19
    local.get 18
    i32.const 0
    i32.ge_s
    if (result i32)
    local.get 1
    call $v_scale
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 19
    local.get 21
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    call $v_dot
    local.set 23
    local.get 23
    i32.load offset=0
    global.get $light_dir
    local.get 23
    i32.load offset=4
    call_indirect (type $cl)
    local.set 22
    local.get 22
    f64.load offset=0 align=8
    f64.const 0
    local.set 25
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 25
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.lt
    if (result i32)
    f64.const 0
    local.set 26
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 26
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    else
    local.get 22
    end
    local.set 24
    global.get $light_dir
    call $v_sub
    local.set 28
    local.get 28
    i32.load offset=0
    local.get 4
    local.get 28
    i32.load offset=4
    call_indirect (type $cl)
    call $v_unit
    local.set 27
    f64.const 0.5
    local.set 30
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 30
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 3
    call $v_dot
    local.set 31
    local.get 31
    i32.load offset=0
    local.get 27
    local.get 31
    i32.load offset=4
    call_indirect (type $cl)
    call $spec_pow32
    f64.load offset=0 align=8
    f64.mul
    local.set 32
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 32
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 29
    local.get 1
    call $v_scale
    local.set 34
    local.get 34
    i32.load offset=0
    local.get 19
    f64.load offset=0 align=8
    f64.const 0.84999999999999998
    local.set 35
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 35
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 24
    f64.load offset=0 align=8
    f64.mul
    local.set 36
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 36
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 37
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 37
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 34
    i32.load offset=4
    call_indirect (type $cl)
    local.set 33
    local.get 33
    call $v_add
    local.set 38
    local.get 38
    i32.load offset=0
    global.get $__lang_bump
    local.set 39
    local.get 39
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 39
    local.get 29
    i32.store offset=0
    local.get 39
    local.get 29
    i32.store offset=4
    local.get 39
    local.get 29
    i32.store offset=8
    local.get 39
    local.get 38
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
  (func $anon_4_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 f64 f64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 i32 i32 i32 i32 i32 i32 f64 f64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 f64 f64 f64 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    i32.const 0
    call $nearest
    local.set 8
    local.get 8
    i32.load offset=0
    local.get 2
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 1
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.load offset=0
    f64.const 0.001
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.load offset=0
    f64.const 0
    local.set 10
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 10
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.load offset=0
    i32.const 0
    i32.const 1
    i32.sub
    local.get 4
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.load offset=0
    local.set 11
    local.get 3
    i32.load offset=4
    local.set 12
    local.get 12
    i32.const 0
    i32.lt_s
    if (result i32)
    local.get 1
    return_call $sky
    else
    local.get 2
    call $v_add
    local.set 14
    local.get 14
    i32.load offset=0
    local.get 1
    call $v_scale
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 11
    local.get 15
    i32.load offset=4
    call_indirect (type $cl)
    local.get 14
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    call $v_sub
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 12
    call $sph_center
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    call $v_unit
    local.set 16
    local.get 12
    call $sph_mirror
    if (result i32)
    local.get 1
    call $v_reflect
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 16
    local.get 19
    i32.load offset=4
    call_indirect (type $cl)
    call $v_unit
    local.set 18
    local.get 13
    call $v_add
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 16
    call $v_scale
    local.set 22
    local.get 22
    i32.load offset=0
    f64.const 0.001
    local.set 23
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 23
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 22
    i32.load offset=4
    call_indirect (type $cl)
    local.get 21
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    i32.const 0
    call $nearest
    local.set 29
    local.get 29
    i32.load offset=0
    local.get 20
    local.get 29
    i32.load offset=4
    call_indirect (type $cl)
    local.set 28
    local.get 28
    i32.load offset=0
    local.get 18
    local.get 28
    i32.load offset=4
    call_indirect (type $cl)
    local.set 27
    local.get 27
    i32.load offset=0
    f64.const 0.001
    local.set 30
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 30
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 27
    i32.load offset=4
    call_indirect (type $cl)
    local.set 26
    local.get 26
    i32.load offset=0
    f64.const 0
    local.set 31
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 31
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 26
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.load offset=0
    i32.const 0
    i32.const 1
    i32.sub
    local.get 25
    i32.load offset=4
    call_indirect (type $cl)
    local.set 24
    local.get 24
    i32.load offset=0
    local.set 32
    local.get 24
    i32.load offset=4
    local.set 33
    local.get 33
    i32.const 0
    i32.lt_s
    if (result i32)
    local.get 18
    call $sky
    else
    local.get 20
    call $v_add
    local.set 36
    local.get 36
    i32.load offset=0
    local.get 18
    call $v_scale
    local.set 37
    local.get 37
    i32.load offset=0
    local.get 32
    local.get 37
    i32.load offset=4
    call_indirect (type $cl)
    local.get 36
    i32.load offset=4
    call_indirect (type $cl)
    local.set 35
    local.get 35
    call $v_sub
    local.set 39
    local.get 39
    i32.load offset=0
    local.get 33
    call $sph_center
    local.get 39
    i32.load offset=4
    call_indirect (type $cl)
    call $v_unit
    local.set 38
    local.get 35
    call $shade
    local.set 42
    local.get 42
    i32.load offset=0
    local.get 38
    local.get 42
    i32.load offset=4
    call_indirect (type $cl)
    local.set 41
    local.get 41
    i32.load offset=0
    local.get 18
    local.get 41
    i32.load offset=4
    call_indirect (type $cl)
    local.set 40
    local.get 40
    i32.load offset=0
    local.get 33
    call $sph_albedo
    local.get 40
    i32.load offset=4
    call_indirect (type $cl)
    end
    local.set 34
    global.get $__lang_bump
    local.set 44
    local.get 44
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 44
    f64.const 0.94999999999999996
    local.set 45
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 45
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 44
    f64.const 0.94999999999999996
    local.set 46
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 46
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 44
    f64.const 0.94999999999999996
    local.set 47
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 47
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 44
    call $v_mulv
    local.set 43
    local.get 43
    i32.load offset=0
    local.get 34
    local.get 43
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 13
    call $shade
    local.set 50
    local.get 50
    i32.load offset=0
    local.get 16
    local.get 50
    i32.load offset=4
    call_indirect (type $cl)
    local.set 49
    local.get 49
    i32.load offset=0
    local.get 1
    local.get 49
    i32.load offset=4
    call_indirect (type $cl)
    local.set 48
    local.get 48
    i32.load offset=0
    local.get 12
    call $sph_albedo
    local.get 48
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
  (func $anon_3_fn (param i32) (param i32) (result i32)
    (local i32 i32 f64 f64 f64 i32 f64 f64 f64 f64 f64 i32 f64 f64 f64 f64 f64 i32 f64 f64 f64 f64 f64 i32 f64 f64 f64 f64 i32 f64 f64 f64)
    local.get 0
    i32.load offset=0
    local.set 2
    global.get $img_w
    f64.convert_i32_s
    local.set 4
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 4
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    global.get $img_h
    f64.convert_i32_s
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.div
    local.set 6
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 6
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 3
    local.get 2
    f64.convert_i32_s
    local.set 8
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 8
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 0.5
    local.set 9
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 9
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 10
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 10
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    global.get $img_w
    f64.convert_i32_s
    local.set 11
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 11
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.div
    local.set 12
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 12
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 7
    local.get 1
    f64.convert_i32_s
    local.set 14
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 14
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 0.5
    local.set 15
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 15
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.add
    local.set 16
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 16
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    global.get $img_h
    f64.convert_i32_s
    local.set 17
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 17
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.div
    local.set 18
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 18
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 13
    f64.const 2
    local.set 20
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 20
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 7
    f64.load offset=0 align=8
    f64.mul
    local.set 21
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 21
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 1
    local.set 22
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 22
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 23
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 23
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 3
    f64.load offset=0 align=8
    f64.mul
    local.set 24
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 24
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 19
    f64.const 1
    local.set 26
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 26
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 2
    local.set 27
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 27
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    local.get 13
    f64.load offset=0 align=8
    f64.mul
    local.set 28
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 28
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 29
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 29
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.set 25
    global.get $__lang_bump
    local.set 30
    local.get 30
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 30
    local.get 19
    i32.store offset=0
    local.get 30
    local.get 25
    i32.store offset=4
    local.get 30
    f64.const 0
    local.set 31
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 31
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.const 1
    local.set 32
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 32
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    f64.load offset=0 align=8
    f64.sub
    local.set 33
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 33
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 30
    return_call $v_unit)
  (func $anon_2_fn (param i32) (param i32) (result i32)
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
    i32.const 86
    i32.store offset=4
    local.get 4)
  (func $anon_45_fn (param i32) (param i32) (result i32)
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
    i32.const 87
    i32.store offset=4
    local.get 5)
  (func $anon_46_fn (param i32) (param i32) (result i32)
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
    local.get 1
    i32.store offset=0
    local.get 5
    local.get 2
    i32.store offset=4
    local.get 5
    local.get 3
    i32.store offset=8
    local.get 5
    local.get 4
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
    i32.const 88
    i32.store offset=4
    local.get 6)
  (func $anon_47_fn (param i32) (param i32) (result i32)
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
    local.get 1
    i32.store offset=4
    local.get 6
    local.get 3
    i32.store offset=8
    local.get 6
    local.get 4
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
    i32.const 89
    i32.store offset=4
    local.get 7)
  (func $anon_48_fn (param i32) (param i32) (result i32)
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
    local.get 0
    i32.load offset=16
    local.set 6
    i32.const 106
    local.get 2
    call $show_int
    call $__lang_str_concat
    i32.const 111
    call $__lang_str_concat
    local.get 3
    call $show_int
    call $__lang_str_concat
    i32.const 113
    call $__lang_str_concat
    local.get 1
    call $show_int
    call $__lang_str_concat
    i32.const 115
    call $__lang_str_concat
    local.set 7
    local.get 4
    local.get 7
    call $dom_canvas_fill_style
    i32.const 0
    drop
    local.get 4
    local.get 5
    local.get 6
    i32.const 1
    i32.const 1
    call $dom_canvas_fill_rect
    i32.const 0)
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
    i32.const 90
    i32.store offset=4
    local.get 4)
  (func $anon_49_fn (param i32) (param i32) (result i32)
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
    i32.const 91
    i32.store offset=4
    local.get 5)
  (func $anon_50_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
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
    global.get $img_w
    i32.eq
    if (result i32)
    local.get 1
    else
    global.get $cam
    call $trace
    local.set 6
    local.get 6
    i32.load offset=0
    local.get 2
    call $ray_dir
    local.set 7
    local.get 7
    i32.load offset=0
    local.get 3
    local.get 7
    i32.load offset=4
    call_indirect (type $cl)
    local.get 6
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.load offset=0
    local.set 8
    local.get 5
    i32.load offset=4
    local.set 9
    local.get 5
    i32.load offset=8
    local.set 10
    local.get 8
    call $quant
    local.set 11
    local.get 9
    call $quant
    local.set 12
    local.get 10
    call $quant
    local.set 13
    local.get 1
    call $adler_byte
    local.set 15
    local.get 15
    i32.load offset=0
    local.get 11
    local.get 15
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 14
    call $adler_byte
    local.set 17
    local.get 17
    i32.load offset=0
    local.get 12
    local.get 17
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    call $adler_byte
    local.set 19
    local.get 19
    i32.load offset=0
    local.get 13
    local.get 19
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 4
    call $put_px
    local.set 24
    local.get 24
    i32.load offset=0
    local.get 2
    local.get 24
    i32.load offset=4
    call_indirect (type $cl)
    local.set 23
    local.get 23
    i32.load offset=0
    local.get 3
    local.get 23
    i32.load offset=4
    call_indirect (type $cl)
    local.set 22
    local.get 22
    i32.load offset=0
    local.get 11
    local.get 22
    i32.load offset=4
    call_indirect (type $cl)
    local.set 21
    local.get 21
    i32.load offset=0
    local.get 12
    local.get 21
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.load offset=0
    local.get 13
    local.get 20
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 4
    call $px_loop
    local.set 27
    local.get 27
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 27
    i32.load offset=4
    call_indirect (type $cl)
    local.set 26
    local.get 26
    i32.load offset=0
    local.get 3
    local.get 26
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.load offset=0
    local.get 18
    local.get 25
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
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
    i32.const 92
    i32.store offset=4
    local.get 4)
  (func $anon_51_fn (param i32) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.load offset=0
    local.set 2
    local.get 0
    i32.load offset=4
    local.set 3
    local.get 2
    global.get $img_h
    i32.eq
    if (result i32)
    local.get 1
    else
    local.get 3
    call $row_loop
    local.set 5
    local.get 5
    i32.load offset=0
    local.get 2
    i32.const 1
    i32.add
    local.get 5
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.load offset=0
    local.get 3
    call $px_loop
    local.set 8
    local.get 8
    i32.load offset=0
    i32.const 0
    local.get 8
    i32.load offset=4
    call_indirect (type $cl)
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
    call_indirect (type $cl)
    local.get 4
    i32.load offset=4
    return_call_indirect (type $cl)
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
    (i32.const 97))
  (func $main (export "main") (result i32)
    (local i32 f64 f64 f64 i32 f64 f64 f64)
    i32.const 96
    global.set $img_w
    i32.const 54
    global.set $img_h
    global.get $__lang_bump
    local.set 0
    local.get 0
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 0
    f64.const 1
    local.set 1
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 1
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 0
    f64.const 1
    local.set 2
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 2
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 0
    f64.const 0.5
    local.set 3
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 3
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 0
    call $v_unit
    global.set $light_dir
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 12
    i32.add
    global.set $__lang_bump
    local.get 4
    f64.const 0
    local.set 5
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 5
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=0
    local.get 4
    f64.const 0
    local.set 6
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 6
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=4
    local.get 4
    f64.const 0.20000000000000001
    local.set 7
    global.get $__lang_bump
    i32.const 7
    i32.add
    i32.const -8
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.get 7
    f64.store offset=0 align=8
    global.get $__lang_bump
    global.get $__lang_bump
    i32.const 8
    i32.add
    global.set $__lang_bump
    i32.store offset=8
    local.get 4
    global.set $cam
    i32.const 0
    call $main_page
    drop
    i32.const 97
    call $puts
    i32.const 0)
)

