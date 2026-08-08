(module
  (type $cl (func (param i64) (param i64) (result i64)))
  (import "env" "puts" (func $puts_h (param i32)))
  (import "env" "__lang_str_of_float" (func $__lang_str_of_float (param f64) (result i32)))
  (import "env" "__lang_float_of_str" (func $__lang_float_of_str (param i32) (result f64)))
  (import "env" "time" (func $__lang_time (result f64)))
  (import "env" "__lang_sin" (func $__lang_sin (param f64) (result f64)))
  (import "env" "__lang_cos" (func $__lang_cos (param f64) (result f64)))
  (import "env" "__lang_tan" (func $__lang_tan (param f64) (result f64)))
  (import "env" "__lang_f_pow" (func $__lang_f_pow (param f64) (param f64) (result f64)))
  (import "env" "__lang_atan2" (func $__lang_atan2 (param f64) (param f64) (result f64)))
  (import "env" "dom_rom_byte" (func $dom_rom_byte_h (param i32) (result i32)))
  (import "env" "dom_get_by_id" (func $dom_get_by_id_h (param i32) (result i32)))
  (import "env" "dom_input_value" (func $dom_input_value_h (param i32) (result i32)))
  (import "env" "dom_canvas_fill_style" (func $dom_canvas_fill_style_h (param i32) (param i32)))
  (import "env" "dom_on_frame" (func $dom_on_frame_h (param i32)))
  (import "env" "dom_rom_size" (func $dom_rom_size_h (param i32) (result i32)))
  (import "env" "dom_audio_tone" (func $dom_audio_tone_h (param i32) (param i32) (param i32)))
  (import "env" "dom_canvas_fill_rect" (func $dom_canvas_fill_rect_h (param i32) (param i32) (param i32) (param i32) (param i32)))
  (import "env" "dom_on_key" (func $dom_on_key_h (param i32)))
  (import "env" "dom_on_click" (func $dom_on_click_h (param i32) (param i32)))
  (import "env" "dom_key_held" (func $dom_key_held_h (param i32) (result i32)))
  (import "env" "dom_set_text" (func $dom_set_text_h (param i32) (param i32)))
  (memory (export "memory") 1024)
  (func $puts (param i64) (call $puts_h (i32.wrap_i64 (local.get 0))))
  (func $dom_rom_byte (param i64) (result i64)
    (i64.extend_i32_u (call $dom_rom_byte_h (i32.wrap_i64 (local.get 0)))))
  (func $dom_get_by_id (param i64) (result i64)
    (i64.extend_i32_u (call $dom_get_by_id_h (i32.wrap_i64 (local.get 0)))))
  (func $dom_input_value (param i64) (result i64)
    (i64.extend_i32_u (call $dom_input_value_h (i32.wrap_i64 (local.get 0)))))
  (func $dom_canvas_fill_style (param i64) (param i64)
    (call $dom_canvas_fill_style_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1))))
  (func $dom_on_frame (param i64)
    (call $dom_on_frame_h (i32.wrap_i64 (local.get 0))))
  (func $dom_rom_size (param i64) (result i64)
    (i64.extend_i32_u (call $dom_rom_size_h (i32.wrap_i64 (local.get 0)))))
  (func $dom_audio_tone (param i64) (param i64) (param i64)
    (call $dom_audio_tone_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1)) (i32.wrap_i64 (local.get 2))))
  (func $dom_canvas_fill_rect (param i64) (param i64) (param i64) (param i64) (param i64)
    (call $dom_canvas_fill_rect_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1)) (i32.wrap_i64 (local.get 2)) (i32.wrap_i64 (local.get 3)) (i32.wrap_i64 (local.get 4))))
  (func $dom_on_key (param i64)
    (call $dom_on_key_h (i32.wrap_i64 (local.get 0))))
  (func $dom_on_click (param i64) (param i64)
    (call $dom_on_click_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1))))
  (func $dom_key_held (param i64) (result i64)
    (i64.extend_i32_u (call $dom_key_held_h (i32.wrap_i64 (local.get 0)))))
  (func $dom_set_text (param i64) (param i64)
    (call $dom_set_text_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1))))
  (table 133 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $frame_closure $render_closure $color_of_closure $drive_closure $service_closure $lowbit_closure $ppu_closure $render_line_closure $tilecolor_closure $tick_closure $step_closure $cb_closure $cb_rot_closure $daa_closure $cond_closure $set_pair_closure $get_pair_closure $add_hl_closure $dec_r_closure $inc_r_closure $alu_closure $pop16_closure $push16_closure $set_flags_closure $set_r_closure $get_r_closure $unpack_f_closure $pack_f_closure $set_de_closure $set_bc_closure $set_hl_closure $get_de_closure $get_bc_closure $get_hl_closure $fetch16_closure $fetch_closure $wr_closure $joypad_closure $apu_len_step_closure $apu_off_closure $apu_trigger_closure $apu_freq_closure $rd_closure $initload_closure $set_bank_closure $romld_closure $new_vec_closure $lo8_closure $hi8_closure $mask16_closure $mask8_closure $pad_left_closure $pad_right_closure $utf8_width_closure $_u8w_go_closure $_eaw_width_closure $utf8_rev_closure $_u8_rev_join_closure $utf8_sub_closure $_u8_slice_closure $utf8_at_closure $_u8_nth_closure $list_product_closure $list_sum_closure $range_closure $_range_down_closure $list_fold_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn $anon_17_fn $anon_18_fn $anon_19_fn $anon_20_fn $anon_21_fn $anon_22_fn $anon_23_fn $anon_24_fn $anon_25_fn $anon_26_fn $anon_27_fn $anon_28_fn $anon_29_fn $anon_30_fn $anon_31_fn $anon_32_fn $anon_33_fn $anon_34_fn $anon_35_fn $anon_36_fn $anon_37_fn $anon_38_fn $anon_39_fn $anon_40_fn $anon_41_fn $anon_42_fn $anon_43_fn $anon_44_fn $anon_45_fn $anon_46_fn $anon_47_fn $anon_48_fn $anon_49_fn $anon_50_fn $anon_51_fn $anon_52_fn $anon_53_fn $anon_54_fn $anon_55_fn $anon_56_fn $anon_57_fn $anon_58_fn $anon_59_fn $anon_60_fn $anon_61_fn $anon_62_fn $anon_63_fn $anon_64_fn $anon_65_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 2155))
(global $__rgn_tmp (mut i64) (i64.const 0))
  (global $__lang_char_table i32 (i32.const 619))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (global $rA (mut i64) (i64.const 0))
  (global $rB (mut i64) (i64.const 0))
  (global $rC (mut i64) (i64.const 0))
  (global $rD (mut i64) (i64.const 0))
  (global $rE (mut i64) (i64.const 0))
  (global $rH (mut i64) (i64.const 0))
  (global $rL (mut i64) (i64.const 0))
  (global $rSP (mut i64) (i64.const 0))
  (global $rPC (mut i64) (i64.const 0))
  (global $fZ (mut i64) (i64.const 0))
  (global $fN (mut i64) (i64.const 0))
  (global $fH (mut i64) (i64.const 0))
  (global $fC (mut i64) (i64.const 0))
  (global $rIME (mut i64) (i64.const 0))
  (global $rHALT (mut i64) (i64.const 0))
  (global $rHALTED (mut i64) (i64.const 0))
  (global $rEI (mut i64) (i64.const 0))
  (global $mem (mut i64) (i64.const 0))
  (global $romn (mut i64) (i64.const 0))
  (global $rom (mut i64) (i64.const 0))
  (global $mbc (mut i64) (i64.const 0))
  (global $apu (mut i64) (i64.const 0))
  (global $apuacc (mut i64) (i64.const 0))
  (global $ctab (mut i64) (i64.const 0))
  (global $reg (mut i64) (i64.const 0))
  (global $sys (mut i64) (i64.const 0))
  (global $fb (mut i64) (i64.const 0))
  (global $bgc (mut i64) (i64.const 0))
  (global $screen (mut i64) (i64.const 0))
  (global $scale (mut i64) (i64.const 0))
  (global $prev (mut i64) (i64.const 0))
  (global $laststyle (mut i64) (i64.const 0))
  (data (i32.const 16) "\07\00\00\00#9bbc0f\00")
  (data (i32.const 28) "\07\00\00\00#8bac0f\00")
  (data (i32.const 40) "\07\00\00\00#306230\00")
  (data (i32.const 52) "\07\00\00\00#0f380f\00")
  (data (i32.const 64) "\00\00\00\00\00")
  (data (i32.const 69) "\00\02\00\0001030202010102010502020201010201010302020101020103020202010102010203020201010201020202020101020102030202030303010202020201010201010101010101020101010101010102010101010101010201010101010101020101010101010102010101010101010201020202020202010201010101010102010101010101010201010101010101020101010101010102010101010101010201010101010101020101010101010102010101010101010201010101010101020102030304030402040204030103060204020303000304020402040300030002040303020000040204040104000000020403030201000402040302040100000204\00")
  (data (i32.const 586) "\06\00\00\00screen\00")
  (data (i32.const 597) "\00\00\00\00\00")
  (data (i32.const 602) "\00\00\00\00\00")
  (data (i32.const 607) "\01\00\00\00 \00")
  (data (i32.const 613) "\01\00\00\00 \00")

  ;; byte-safe str: linear-memory layout is [i32 len][len bytes]['\0'].
  ;; A `str` value is the address of byte0; the 4-byte length header sits
  ;; immediately before it (addr-4). NUL-free strings stay C/host-interop
  ;; compatible (the trailing '\0' is preserved); embedded NULs survive
  ;; because length comes from the header, not a NUL scan. Wasm permits
  ;; unaligned i32 access, so the header needs no alignment.
  (func $__lang_str_alloc (param $len8 i64) (result i64)
    (local $len i32) (local $p i32)
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (i32.store (global.get $__lang_bump) (local.get $len))          ;; header
    (local.set $p (i32.add (global.get $__lang_bump) (i32.const 4))) ;; byte0
    (i32.store8 (i32.add (local.get $p) (local.get $len)) (i32.const 0)) ;; NUL
    (global.set $__lang_bump
      (i32.add (local.get $p) (i32.add (local.get $len) (i32.const 1))))
    (i64.extend_i32_u (local.get $p)))
  ;; str length = i32 header at addr-4 (byte-safe: counts embedded NULs).
  (func $__lang_strlen (param $s8 i64) (result i64)
    (i64.extend_i32_u
      (i32.load (i32.sub (i32.wrap_i64 (local.get $s8)) (i32.const 4)))))
  ;; Copy `len` raw bytes into a fresh header'd str. Used to finalize
  ;; right-to-left digit buffers (show_int / to_json_int) whose result
  ;; pointer floats inside a scratch region with no room for a header.
  (func $__lang_str_copyn (param $src8 i64) (param $len8 i64) (result i64)
    (local $src i32) (local $len i32) (local $dst i32) (local $i i32)
    (local.set $src (i32.wrap_i64 (local.get $src8)))
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (local.set $dst (i32.wrap_i64 (call $__lang_str_alloc (i64.extend_i32_u (local.get $len)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (local.get $dst) (local.get $i))
                  (i32.load8_u (i32.add (local.get $src) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_u (local.get $dst)))
  (func $__lang_str_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $r i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; v0.1.37: deep-copy a NUL-terminated str into fresh bump space.
  ;; Region blocks copy their result out before releasing the block's
  ;; allocations (the safe version of the save/restore that Phase 16.4
  ;; removed as unsound).
  (func $__mcopy_str (param $s8 i64) (result i64)
    (local $l i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $l (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; byte-safe: compare lengths (from header) then bytes over that length,
  ;; so embedded NULs count instead of terminating the scan.
  (func $__lang_streq (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (if (i32.ne (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $la)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i)))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
          (then (return (i64.extend_i32_s (i32.const 0)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 31.0: str_compare — returns -1 / 0 / 1 (sign-normalized, matches
  ;; interp's `compare s t` from OCaml stdlib).
  ;; byte-safe: memcmp over min(la,lb), then length tiebreak.
  (func $__lang_str_compare (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $n i32) (local $i i32)
    (local $ba i32) (local $bb i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (local.set $n (select (local.get $la) (local.get $lb) (i32.lt_u (local.get $la) (local.get $lb))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $n)))
        (local.set $ba (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $bb (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (if (i32.lt_u (local.get $ba) (local.get $bb))
          (then (return (i64.extend_i32_s (i32.const -1)))))
        (if (i32.gt_u (local.get $ba) (local.get $bb))
          (then (return (i64.extend_i32_s (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (if (i32.lt_u (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const -1)))))
    (if (i32.gt_u (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const 1)))))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 19.1.1: str_index_of — returns position of needle in haystack,
  ;; -1 if not found. Empty needle returns 0.
  (func $__lang_str_index_of (param $h8 i64) (param $n8 i64) (result i64)
    (local $hlen i32) (local $nlen i32) (local $i i32) (local $j i32)
    (local $match i32)
    (local $h i32)
    (local $n i32)
    (local.set $h (i32.wrap_i64 (local.get $h8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (local.set $hlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $h)))))
    (local.set $nlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $n)))))
    (if (i32.eqz (local.get $nlen)) (then (return (i64.extend_i32_s (i32.const 0)))))
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
        (if (local.get $match) (then (return (i64.extend_i32_s (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i64.extend_i32_s (i32.const -1)))
  ;; Phase 36: __lang_is_ws — ASCII whitespace test (space/tab/lf/cr/ff)
  (func $__lang_is_ws (param $c8 i64) (result i64)
    (local $c i32)
    (local.set $c (i32.wrap_i64 (local.get $c8)))
    (i64.extend_i32_s (i32.or
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32))
                (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10))
                (i32.eq (local.get $c) (i32.const 13))))
      (i32.eq (local.get $c) (i32.const 12)))))
  ;; Phase 36: str_starts_with — bool (i32 0/1)
  ;; byte-safe: bound the compare by the prefix length (header), not a NUL.
  (func $__lang_str_starts_with (param $s8 i64) (param $p8 i64) (result i64)
    (local $i i32) (local $sl i32) (local $pl i32)
    (local $s i32)
    (local $p i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (i32.wrap_i64 (local.get $p8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $pl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    (if (i32.gt_u (local.get $pl) (local.get $sl))
      (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $pl)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $s) (local.get $i)))
                    (i32.load8_u (i32.add (local.get $p) (local.get $i))))
          (then (return (i64.extend_i32_s (i32.const 0)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 36: str_trim — strip leading + trailing whitespace
  (func $__lang_str_trim (param $s8 i64) (result i64)
    (local $p i32) (local $len i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (local.get $s))
    ;; skip leading whitespace
    (block $end_lead
      (loop $lp_lead
        (local.set $c (i32.load8_u (local.get $p)))
        (br_if $end_lead (i32.eqz (local.get $c)))
        (br_if $end_lead (i32.eqz (i32.wrap_i64 (call $__lang_is_ws (i64.extend_i32_s (local.get $c))))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $lp_lead)))
    ;; compute remaining length
    (local.set $len (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    ;; trim trailing
    (block $end_trail
      (loop $lp_trail
        (br_if $end_trail (i32.eqz (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $p)
                                            (i32.sub (local.get $len) (i32.const 1)))))
        (br_if $end_trail (i32.eqz (i32.wrap_i64 (call $__lang_is_ws (i64.extend_i32_s (local.get $c))))))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $lp_trail)))
    ;; copy [p, p+len) to bump
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: str_ends_with — bool (i32 0/1)
  (func $__lang_str_ends_with (param $s8 i64) (param $p8 i64) (result i64)
    (local $sl i32) (local $pl i32) (local $i i32)
    (local $s i32)
    (local $p i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (i32.wrap_i64 (local.get $p8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $pl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    (if (i32.gt_s (local.get $pl) (local.get $sl)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (loop $lp
      (if (i32.eq (local.get $i) (local.get $pl)) (then (return (i64.extend_i32_s (i32.const 1)))))
      (if (i32.ne
            (i32.load8_u (i32.add (i32.add (local.get $s)
                                           (i32.sub (local.get $sl) (local.get $pl)))
                                  (local.get $i)))
            (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (then (return (i64.extend_i32_s (i32.const 0)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_repeat s n
  (func $__lang_str_repeat (param $s8 i64) (param $n8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $j i32)
    (local $s i32)
    (local $n i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (if (i32.le_s (local.get $n) (i32.const 0))
      (then
        (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
        (i32.store8 (local.get $r) (i32.const 0))
        (global.set $__lang_bump (i32.add (local.get $r) (i32.const 1)))
        (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.const 0))
        (return (i64.extend_i32_s (local.get $r)))))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: str_rev
  (func $__lang_str_rev (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: chr n — return char_table entry pointer for byte n.
  ;; Mask to a single byte (n & 0xFF) so out-of-range input can't index
  ;; past the 256-entry table into adjacent memory. Matches the C backend
  ;; ((unsigned char)n) and the self-host $chr (i32.store8 truncation).
  (func $__lang_char_at_chr (param $n8 i64) (result i64)
    (local $n i32)
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (i32.add (global.get $__lang_char_table)
      (i32.mul (i32.and (local.get $n) (i32.const 255)) (i32.const 6))) (i32.const 4))))
  ;; Phase 36: abs / min / max / clamp
  (func $__lang_abs (param $n i64) (result i64)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (return (i64.sub (i64.const 0) (local.get $n)))))
    (local.get $n))
  (func $__lang_min (param $a i64) (param $b i64) (result i64)
    (if (i64.lt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_max (param $a i64) (param $b i64) (result i64)
    (if (i64.gt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_clamp (param $lo i64) (param $hi i64) (param $x i64) (result i64)
    (if (i64.lt_s (local.get $x) (local.get $lo))
      (then (return (local.get $lo))))
    (if (i64.gt_s (local.get $x) (local.get $hi))
      (then (return (local.get $hi))))
    (local.get $x))
  ;; Phase 36: to_upper / to_lower — ASCII case conversion
  (func $__lang_to_upper (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_to_lower (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: gcd via iterative Euclid on |a|, |b|
  (func $__lang_gcd (param $a0 i64) (param $b0 i64) (result i64)
    (local $a i64) (local $b i64) (local $t i64)
    (local.set $a (local.get $a0))
    (local.set $b (local.get $b0))
    (if (i64.lt_s (local.get $a) (i64.const 0))
      (then (local.set $a (i64.sub (i64.const 0) (local.get $a)))))
    (if (i64.lt_s (local.get $b) (i64.const 0))
      (then (local.set $b (i64.sub (i64.const 0) (local.get $b)))))
    (block $end
      (loop $lp
        (br_if $end (i64.eqz (local.get $b)))
        (local.set $t (local.get $b))
        (local.set $b (i64.rem_s (local.get $a) (local.get $b)))
        (local.set $a (local.get $t))
        (br $lp)))
    (local.get $a))
  ;; Phase 36: bool_of_str — "true" → 1, otherwise → 0
  (func $__lang_bool_of_str (param $s8 i64) (result i64)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (if (i32.ne (i32.load8_u (local.get $s)) (i32.const 116)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.const 114)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.const 117)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 3))) (i32.const 101)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 4))) (i32.const 0)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 36: str_replace s old new — replace all non-overlapping occurrences
  (func $__lang_str_replace (param $s8 i64) (param $old8 i64) (param $new8 i64) (result i64)
    (local $slen i32) (local $olen i32) (local $nlen i32)
    (local $r i32) (local $bi i32) (local $i i32) (local $j i32) (local $match i32)
    (local $s i32)
    (local $old i32)
    (local $new i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $old (i32.wrap_i64 (local.get $old8)))
    (local.set $new (i32.wrap_i64 (local.get $new8)))
    (local.set $olen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $old)))))
    (if (i32.eqz (local.get $olen)) (then (return (i64.extend_i32_s (local.get $s)))))
    (local.set $slen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $nlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $new)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 26.1/26.2: fail msg — if a try_or scope is active, set the
  ;; failure flag and return 0 (the caller's expected result type is i32
  ;; for everything in Wasm). Otherwise print + trap. The flag /
  ;; active-counter globals are declared at module level.
  (func $__lang_fail (param $msg8 i64) (result i64)
    (local $msg i32)
    (local.set $msg (i32.wrap_i64 (local.get $msg8)))
    (if (global.get $__lang_fail_active)
      (then
        (global.set $__lang_fail_flag (i32.const 1))
        (return (i64.extend_i32_s (i32.const 0)))))
    (call $puts_h (local.get $msg))
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
            ;; byte-safe entry: stride 6 = [i32 len=1][char][NUL]; the str
            ;; pointer returned is base + k*6 + 4 (header at base + k*6).
            (i32.store   (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6)))
                         (i32.const 1))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6))) (i32.const 4))
                        (local.get $k))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6))) (i32.const 5))
                        (i32.const 0))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $lp))))))
  (func $__lang_char_at (param $s8 i64) (param $i8 i64) (result i64)
    (local $s i32)
    (local $i i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (i32.add (global.get $__lang_char_table)
             (i32.mul (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 6))) (i32.const 4))))
  (func $__lang_is_digit (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.and (i32.ge_s (local.get $c) (i32.const 48))
             (i32.le_s (local.get $c) (i32.const 57)))))
  (func $__lang_is_alpha (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.or
      (i32.and (i32.ge_s (local.get $c) (i32.const 97))
               (i32.le_s (local.get $c) (i32.const 122)))
      (i32.and (i32.ge_s (local.get $c) (i32.const 65))
               (i32.le_s (local.get $c) (i32.const 90))))))
  (func $__lang_is_space (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.or
      (i32.or (i32.eq (local.get $c) (i32.const 32))
              (i32.eq (local.get $c) (i32.const 9)))
      (i32.or (i32.eq (local.get $c) (i32.const 10))
              (i32.eq (local.get $c) (i32.const 13))))))
  ;; Phase 26.1: substring s start end_ — region alloc + memcpy.
  (func $__lang_substring (param $s8 i64) (param $start8 i64) (param $end_8 i64) (result i64)
    (local $len i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local $start i32)
    (local $end_ i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $start (i32.wrap_i64 (local.get $start8)))
    (local.set $end_ (i32.wrap_i64 (local.get $end_8)))
    (local.set $len (i32.sub (local.get $end_) (local.get $start)))
    (if (i32.lt_s (local.get $len) (i32.const 0))
      (then (local.set $len (i32.const 0))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; v0.1.60: int_of_str s msg — strict decimal parse
  ;; (WS* [+-]? DIGIT+ WS*); anything else calls $__lang_fail with the
  ;; interned msg (try_or-able), matching the interpreter instead of the
  ;; old atoi semantics that silently returned 0 / a partial prefix.
  (func $__lang_int_of_str (param $s8 i64) (param $msg i64) (result i64)
    (local $s i32)
    (local $i i32) (local $sign i64) (local $acc i64) (local $c i32)
    (local $nd i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.const 0))
    (local.set $sign (i64.const 1))
    (local.set $acc (i64.const 0))
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
        (local.set $sign (i64.const -1))
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
        (local.set $acc (i64.add
          (i64.mul (local.get $acc) (i64.const 10))
          (i64.extend_i32_s (i32.sub (local.get $c) (i32.const 48)))))
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
        (drop (call $__lang_fail (local.get $msg)))
        (return (i64.const 0))))
    (i64.mul (local.get $acc) (local.get $sign)))
  ;; Phase 26.1: str_unescape s — replace backslash-escape sequences
  ;; (\n, \t, \r, \\ , \", \/) with the actual byte. Region-allocated.
  (func $__lang_str_unescape (param $s8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32)
    (local $c i32) (local $ec i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 26.6: str_escape s — backslash-escape newline / tab / cr / backslash
  ;; / quote. show_str pipes through this so output matches interp. Worst-case
  ;; 2x byte expansion, region-allocated.
  (func $__lang_str_escape (param $s8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32) (local $c i32) (local $ec i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
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
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_list_str_nil (result i64)
    (local $p i32)
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 16)))
    (i64.store offset=0 (local.get $p) (i64.const 0))
    (i64.extend_i32_u (local.get $p)))
  (func $__lang_list_str_cons (param $head i64) (param $tail i64) (result i64)
    (local $p i32) (local $box i32)
    ;; Tuple payload box: 16 bytes (str value + list value, 8-byte slots).
    (local.set $box (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $box) (i32.const 16)))
    (i64.store offset=0 (local.get $box) (local.get $head))
    (i64.store offset=8 (local.get $box) (local.get $tail))
    ;; Cons cell: 16 bytes (tag=1 + payload value).
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 16)))
    (i64.store offset=0 (local.get $p) (i64.const 1))
    (i64.store offset=8 (local.get $p) (i64.extend_i32_u (local.get $box)))
    (i64.extend_i32_u (local.get $p)))
  ;; list back-to-front by scanning for sequence starts from the end.
  (func $__lang_utf8_len (param $s8 i64) (result i64)
    (local $n i32) (local $i i32) (local $c i32) (local $b i32) (local $l i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
    (i64.extend_i32_s (local.get $c)))
  (func $__lang_utf8_chars (param $s8 i64) (result i64)
    (local $n i32) (local $end i32) (local $st i32) (local $l i32)
    (local $tok i32) (local $j i32) (local $acc i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $acc (i32.wrap_i64 (call $__lang_list_str_nil)))
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
        (local.set $tok (i32.add (global.get $__lang_bump) (i32.const 4)))
        (global.set $__lang_bump (i32.add (i32.add (local.get $tok) (local.get $l)) (i32.const 1)))
        (i32.store (i32.sub (local.get $tok) (i32.const 4)) (local.get $l))
        (local.set $j (i32.const 0))
        (block $cend
          (loop $clp
            (br_if $cend (i32.ge_s (local.get $j) (local.get $l)))
            (i32.store8 (i32.add (local.get $tok) (local.get $j))
                        (i32.load8_u (i32.add (i32.add (local.get $s) (local.get $st)) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $clp)))
        (i32.store8 (i32.add (local.get $tok) (local.get $l)) (i32.const 0))
        (local.set $acc (i32.wrap_i64 (call $__lang_list_str_cons (i64.extend_i32_s (local.get $tok)) (i64.extend_i32_s (local.get $acc)))))
        (local.set $end (local.get $st))
        (br $outer)))
    (i64.extend_i32_s (local.get $acc)))
  ;; str_split s delim — 2-pass: count tokens, then build list back-to-front.
  (func $__lang_str_split (param $s8 i64) (param $delim8 i64) (result i64)
    (local $sl i32) (local $dl i32) (local $i i32) (local $cnt i32)
    (local $starts i32) (local $lens i32) (local $tstart i32) (local $tidx i32)
    (local $tlen i32) (local $tk i32) (local $j i32) (local $match i32)
    (local $nil i32) (local $tail i32) (local $bi i32) (local $b_off i32)
    (local $s i32)
    (local $delim i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $delim (i32.wrap_i64 (local.get $delim8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $dl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $delim)))))
    ;; Empty delim: return Cons(s, Nil) (matches interp / C / LLVM).
    (if (i32.eqz (local.get $dl))
      (then
        (local.set $nil (i32.wrap_i64 (call $__lang_list_str_nil)))
        (return (call $__lang_list_str_cons (i64.extend_i32_s (local.get $s)) (i64.extend_i32_s (local.get $nil))))))
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
    (local.set $nil (i32.wrap_i64 (call $__lang_list_str_nil)))
    (local.set $tail (local.get $nil))
    (local.set $bi (local.get $cnt))
    (block $end_b
      (loop $lp_b
        (local.set $b_off (i32.mul (local.get $bi) (i32.const 4)))
        (local.set $tstart (i32.load (i32.add (local.get $starts) (local.get $b_off))))
        (local.set $tlen (i32.load (i32.add (local.get $lens) (local.get $b_off))))
        (local.set $tk (i32.add (global.get $__lang_bump) (i32.const 4)))
        (global.set $__lang_bump
          (i32.add (local.get $tk) (i32.add (local.get $tlen) (i32.const 1))))
        (i32.store (i32.sub (local.get $tk) (i32.const 4)) (local.get $tlen))
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
        (local.set $tail (i32.wrap_i64 (call $__lang_list_str_cons (i64.extend_i32_s (local.get $tk)) (i64.extend_i32_s (local.get $tail)))))
        (br_if $end_b (i32.eqz (local.get $bi)))
        (local.set $bi (i32.sub (local.get $bi) (i32.const 1)))
        (br $lp_b)))
    (i64.extend_i32_s (local.get $tail)))
  ;; str_join sep xs — walk list_str, concat with sep.
  (func $__lang_str_join (param $sep8 i64) (param $xs8 i64) (result i64)
    (local $sl i32) (local $cur i32) (local $box i32) (local $head i32)
    (local $total i32) (local $first i32) (local $r i32) (local $pos i32)
    (local $hl i32)
    (local $sep i32)
    (local $xs i32)
    (local.set $sep (i32.wrap_i64 (local.get $sep8)))
    (local.set $xs (i32.wrap_i64 (local.get $xs8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $sep)))))
    ;; Pass 1: total length.
    (local.set $cur (local.get $xs))
    (local.set $total (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_len
      (loop $lp_len
        (br_if $end_len (i64.eqz (i64.load offset=0 (local.get $cur))))
        (local.set $box (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))
        (local.set $head (i32.wrap_i64 (i64.load offset=0 (local.get $box))))
        (if (i32.eqz (local.get $first))
          (then (local.set $total (i32.add (local.get $total) (local.get $sl)))))
        (local.set $total
          (i32.add (local.get $total)
                   (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $head))))))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $box))))
        (br $lp_len)))
    ;; Allocate result + null terminator.
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (global.set $__lang_bump
      (i32.add (local.get $r) (i32.add (local.get $total) (i32.const 1))))
    ;; Pass 2: write.
    (local.set $cur (local.get $xs))
    (local.set $pos (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_w
      (loop $lp_w
        (br_if $end_w (i64.eqz (i64.load offset=0 (local.get $cur))))
        (local.set $box (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))
        (local.set $head (i32.wrap_i64 (i64.load offset=0 (local.get $box))))
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
        (local.set $hl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $head)))))
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
        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $box))))
        (br $lp_w)))
    (i32.store8 (i32.add (local.get $r) (local.get $total)) (i32.const 0))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; str_count s n — non-overlapping count of n in s.
  (func $__lang_str_count (param $s8 i64) (param $n8 i64) (result i64)
    (local $sl i32) (local $nl i32) (local $i i32) (local $j i32)
    (local $acc i32) (local $match i32)
    (local $s i32)
    (local $n i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $nl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $n)))))
    (if (i32.eqz (local.get $nl)) (then (return (i64.extend_i32_s (i32.const 0)))))
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
    (i64.extend_i32_s (local.get $acc)))
  (func $mere_vec_new (result i64)
    (local $v i32) (local $buf i32)
    (local.set $v (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $v) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 32)))
    (i32.store offset=0 (local.get $v) (local.get $buf))
    (i32.store offset=4 (local.get $v) (i32.const 0))
    (i32.store offset=8 (local.get $v) (i32.const 4))
    (i64.extend_i32_s (local.get $v)))
  (func $mere_vec_push (param $v8 i64) (param $x i64) (result i64)
    (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $cap (i32.load offset=8 (local.get $v)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf)
                   (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $buf (i32.load offset=0 (local.get $v)))
        (local.set $i (i32.const 0))
        (block $copy_end
          (loop $copy_lp
            (br_if $copy_end (i32.eq (local.get $i) (local.get $len)))
            (i64.store
              (i32.add (local.get $new_buf)
                       (i32.mul (local.get $i) (i32.const 8)))
              (i64.load
                (i32.add (local.get $buf)
                         (i32.mul (local.get $i) (i32.const 8)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $copy_lp)))
        (i32.store offset=0 (local.get $v) (local.get $new_buf))
        (i32.store offset=8 (local.get $v) (local.get $cap))))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.store
      (i32.add (local.get $buf)
               (i32.mul (local.get $len) (i32.const 8)))
      (local.get $x))
    (i32.store offset=4 (local.get $v) (i32.add (local.get $len) (i32.const 1)))
    (i64.extend_i32_s (i32.const 0)))
  (func $mere_vec_get (param $v8 i64) (param $i8 i64) (result i64)
    (local $len i32) (local $buf i32)
    (local $v i32)
    (local $i i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.load
      (i32.add (local.get $buf)
               (i32.mul (local.get $i) (i32.const 8)))))
  (func $mere_vec_len (param $v8 i64) (result i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (i64.extend_i32_s (i32.load offset=4 (local.get $v))))
  (func $mere_vec_set (param $v8 i64) (param $i8 i64) (param $x i64) (result i64)
    (local $len i32) (local $buf i32)
    (local $v i32)
    (local $i i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.store
      (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 8)))
      (local.get $x))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 15.7: OwnedVec helpers — in Wasm all values are i32 and the
  ;; bump allocator is also shared, so the runtime representations of Vec
  ;; and OwnedVec are the same. owned_vec_* aliases as a thin wrapper to
  ;; $mere_vec_*. Deep copy (vec_to_owned / owned_vec_to_vec) uses $mere_vec_clone.
  (func $mere_vec_clone (param $src8 i64) (result i64)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $src i32)
    (local.set $src (i32.wrap_i64 (local.get $src8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $len (i32.load offset=4 (local.get $src)))
    (local.set $buf (i32.load offset=0 (local.get $src)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.load (i32.add (local.get $buf)
                                    (i32.mul (local.get $i) (i32.const 8)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (local.get $new)))
  ;; Phase 19.3: vec_reverse — in-place swap, returns 0 (unit).
  (func $mere_vec_reverse (param $v8 i64) (result i64)
    (local $lo i32) (local $hi i32) (local $buf i32) (local $tmp i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $lo (i32.const 0))
    (local.set $hi (i32.sub (i32.load offset=4 (local.get $v)) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $lo) (local.get $hi)))
        (local.set $tmp (i64.load
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 8)))))
        (i64.store
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 8)))
          (i64.load (i32.add (local.get $buf)
                             (i32.mul (local.get $hi) (i32.const 8)))))
        (i64.store
          (i32.add (local.get $buf) (i32.mul (local.get $hi) (i32.const 8)))
          (local.get $tmp))
        (local.set $lo (i32.add (local.get $lo) (i32.const 1)))
        (local.set $hi (i32.sub (local.get $hi) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 19.3: vec_sort — in-place insertion sort.
  ;; cmp: closure_T_(closure_T_int). outer_fn(env, a) → inner closure_T_int,
  ;; inner_fn(inner.env, b) → i32 (negative/0/positive).
  (func $mere_vec_sort (param $v8 i64) (param $cmp i64) (result i64)
    (local $i i32) (local $j i32) (local $len i32) (local $buf i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $key i64) (local $j_val i64)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32)
    (local $cmp_res i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (i32.wrap_i64 (local.get $cmp))))
    (local.set $outer_fn  (i32.load offset=4 (i32.wrap_i64 (local.get $cmp))))
    (local.set $i (i32.const 1))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $key (i64.load
          (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $j (i32.sub (local.get $i) (i32.const 1)))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.lt_s (local.get $j) (i32.const 0)))
            (local.set $j_val (i64.load
              (i32.add (local.get $buf) (i32.mul (local.get $j) (i32.const 8)))))
            (local.set $inner_cl (i32.wrap_i64
              (call_indirect (type $cl)
                (i64.extend_i32_u (local.get $outer_env)) (local.get $j_val)
                (local.get $outer_fn))))
            (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
            (local.set $inner_fn  (i32.load offset=4 (local.get $inner_cl)))
            (local.set $cmp_res
              (call_indirect (type $cl)
                (i64.extend_i32_u (local.get $inner_env)) (local.get $key)
                (local.get $inner_fn)))
            (br_if $end_inner (i64.le_s (local.get $cmp_res) (i64.const 0)))
            ;; shift: data[j+1] = data[j]
            (i64.store
              (i32.add (local.get $buf)
                       (i32.mul (i32.add (local.get $j) (i32.const 1))
                                (i32.const 8)))
              (local.get $j_val))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        ;; place key at j+1
        (i64.store
          (i32.add (local.get $buf)
                   (i32.mul (i32.add (local.get $j) (i32.const 1))
                            (i32.const 8)))
          (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i64.const 0))
  (func $mere_vec_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $new i32) (local $i i32) (local $alen i32) (local $blen i32)
    (local $abuf i32) (local $bbuf i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $alen (i32.load offset=4 (local.get $a)))
    (local.set $blen (i32.load offset=4 (local.get $b)))
    (local.set $abuf (i32.load offset=0 (local.get $a)))
    (local.set $bbuf (i32.load offset=0 (local.get $b)))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $alen)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.extend_i32_s (i32.load (i32.add (local.get $abuf)
                                   (i32.mul (local.get $i) (i32.const 8))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $blen)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.extend_i32_s (i32.load (i32.add (local.get $bbuf)
                                   (i32.mul (local.get $i) (i32.const 8))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (i64.extend_i32_s (local.get $new)))
  (func $__lang_bytes_alloc (param $len8 i64) (result i64)
    (local $b i32)
    (local $len i32)
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 3)) (i32.const -4)))
    (local.set $b (global.get $__lang_bump))
    (i32.store (local.get $b) (local.get $len))
    (global.set $__lang_bump (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $len)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_bytes_get (param $b8 i64) (param $i8 i64) (result i64)
    (local $b i32)
    (local $i i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (i32.load (local.get $b))))
      (then (unreachable)))
    (i64.extend_i32_s (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i)))))
  (func $__lang_bytes_of_str (param $s8 i64) (result i64)
    (local $n i32) (local $b i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $b (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $n)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_str_of_bytes (param $b8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32)
    (local $b i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (local.get $r) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $n)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $n)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_hexchar (param $d8 i64) (result i64)
    (local $d i32)
    (local.set $d (i32.wrap_i64 (local.get $d8)))
    (i64.extend_i32_s (if (result i32) (i32.lt_s (local.get $d) (i32.const 10))
      (then (i32.add (local.get $d) (i32.const 48)))
      (else (i32.add (local.get $d) (i32.const 87))))))
  (func $__lang_hex_of_bytes (param $b8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $byte i32)
    (local $b i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (local.set $byte (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2)))
                  (i32.wrap_i64 (call $__lang_hexchar (i64.extend_i32_s (i32.shr_u (local.get $byte) (i32.const 4))))))
      (i32.store8 (i32.add (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2))) (i32.const 1))
                  (i32.wrap_i64 (call $__lang_hexchar (i64.extend_i32_s (i32.and (local.get $byte) (i32.const 15))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_hexval (param $c8 i64) (result i64)
    (local $c i32)
    (local.set $c (i32.wrap_i64 (local.get $c8)))
    (i64.extend_i32_s (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 48)) (i32.le_s (local.get $c) (i32.const 57)))
      (then (i32.sub (local.get $c) (i32.const 48)))
      (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 97)) (i32.le_s (local.get $c) (i32.const 102)))
        (then (i32.sub (local.get $c) (i32.const 87)))
        (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 65)) (i32.le_s (local.get $c) (i32.const 70)))
          (then (i32.sub (local.get $c) (i32.const 55)))
          (else (unreachable)))))))))
  (func $__lang_bytes_of_hex (param $h8 i64) (result i64)
    (local $half i32) (local $b i32) (local $i i32)
    (local $h i32)
    (local.set $h (i32.wrap_i64 (local.get $h8)))
    (local.set $half (i32.div_u (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $h)))) (i32.const 2)))
    (local.set $b (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $half)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $half)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
        (i32.add
          (i32.mul (i32.wrap_i64 (call $__lang_hexval (i64.extend_i32_s (i32.load8_u (i32.add (local.get $h) (i32.mul (local.get $i) (i32.const 2))))))) (i32.const 16))
          (i32.wrap_i64 (call $__lang_hexval (i64.extend_i32_s (i32.load8_u (i32.add (local.get $h) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_bytes_slice (param $b8 i64) (param $start8 i64) (param $len8 i64) (result i64)
    (local $o i32) (local $i i32)
    (local $b i32)
    (local $start i32)
    (local $len i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $start (i32.wrap_i64 (local.get $start8)))
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (local.set $o (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $len)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $start)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $o)))
  (func $__lang_bytes_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $alen i32) (local $blen i32) (local $o i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $alen (i32.load (local.get $a)))
    (local.set $blen (i32.load (local.get $b)))
    (local.set $o (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (i32.add (local.get $alen) (local.get $blen))))))
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
    (i64.extend_i32_s (local.get $o)))
  (func $frame (param i64) (result i64)
    global.get $__lang_bump
    i64.const 30000
    call $drive
    drop
    i64.const 0
    call $render
    global.set $__rgn_tmp
    global.set $__lang_bump
    global.get $__rgn_tmp)
  (func $render (param i64) (result i64)
    global.get $laststyle
    i64.const 0
    i64.const 0
    i64.const 1
    i64.sub
    call $mere_vec_set
    drop
    global.get $fb
    global.get $prev
    global.get $laststyle
    global.get $screen
    global.get $scale
    i64.const 0
    return_call $__lifted_go_uq1_0)
  (func $color_of (param i64) (result i64)
    local.get 0
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 20
    else
    local.get 0
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 32
    else
    local.get 0
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 44
    else
    i64.const 56
    end
    end
    end)
  (func $drive (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64)
    local.get 0
    i64.const 0
    i64.le_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $reg
    global.get $rHALT
    call $mere_vec_get
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $reg
    global.get $rHALTED
    call $mere_vec_get
    local.set 1
    local.get 1
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    call $tick
    drop
    i64.const 1
    call $ppu
    else
    global.get $reg
    global.get $rPC
    call $mere_vec_get
    local.set 2
    global.get $mem
    local.get 2
    call $mere_vec_get
    local.set 3
    local.get 3
    i64.const 203
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    global.get $mem
    local.get 2
    i64.const 1
    i64.add
    i64.const 65535
    i64.and
    call $mere_vec_get
    local.set 5
    local.get 5
    i64.const 7
    i64.and
    i64.const 6
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 4
    else
    i64.const 2
    end
    else
    global.get $ctab
    local.get 3
    call $__lang_bytes_get
    end
    local.set 4
    global.get $mem
    call $step
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $reg
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 4
    call $tick
    drop
    local.get 4
    call $ppu
    end
    drop
    global.get $reg
    global.get $rEI
    call $mere_vec_get
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    global.get $reg
    global.get $rEI
    i64.const 1
    call $mere_vec_set
    else
    global.get $reg
    global.get $rEI
    call $mere_vec_get
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    global.get $reg
    global.get $rEI
    i64.const 0
    call $mere_vec_set
    drop
    global.get $reg
    global.get $rIME
    i64.const 1
    call $mere_vec_set
    else
    i64.const 0
    end
    end
    drop
    i64.const 0
    call $service
    drop
    local.get 0
    i64.const 1
    i64.sub
    return_call $drive
    end
    end)
  (func $service (param i64) (result i64)
    (local i64 i64 i64 i64)
    global.get $mem
    i64.const 65535
    call $mere_vec_get
    global.get $mem
    i64.const 65295
    call $mere_vec_get
    i64.and
    i64.const 31
    i64.and
    local.set 1
    local.get 1
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $reg
    global.get $rHALTED
    i64.const 0
    call $mere_vec_set
    drop
    global.get $reg
    global.get $rIME
    call $mere_vec_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 1
    call $lowbit
    local.set 2
    global.get $reg
    global.get $rIME
    i64.const 0
    call $mere_vec_set
    drop
    global.get $mem
    i64.const 65295
    global.get $mem
    i64.const 65295
    call $mere_vec_get
    i64.const 1
    local.get 2
    i64.shl
    i64.const 255
    i64.xor
    i64.and
    call $mere_vec_set
    drop
    global.get $mem
    call $push16
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $reg
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $reg
    global.get $rPC
    call $mere_vec_get
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $reg
    global.get $rPC
    i64.const 64
    local.get 2
    i64.const 8
    i64.mul
    i64.add
    call $mere_vec_set
    drop
    i64.const 5
    call $tick
    drop
    i64.const 5
    return_call $ppu
    end
    end)
  (func $lowbit (param i64) (result i64)
    local.get 0
    i64.const 1
    i64.and
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 2
    i64.and
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 4
    i64.and
    i64.const 4
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 2
    else
    local.get 0
    i64.const 8
    i64.and
    i64.const 8
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 3
    else
    i64.const 4
    end
    end
    end
    end)
  (func $ppu (param i64) (result i64)
    global.get $sys
    i64.const 2
    global.get $sys
    i64.const 2
    call $mere_vec_get
    local.get 0
    i64.const 4
    i64.mul
    i64.add
    call $mere_vec_set
    drop
    global.get $sys
    global.get $mem
    i64.const 0
    return_call $__lifted_ll_1)
  (func $render_line (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    global.get $mem
    i64.const 65344
    call $mere_vec_get
    local.set 1
    local.get 1
    i64.const 128
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $mem
    i64.const 65351
    call $mere_vec_get
    local.set 2
    global.get $mem
    i64.const 65346
    call $mere_vec_get
    local.set 3
    global.get $mem
    i64.const 65347
    call $mere_vec_get
    local.set 4
    global.get $mem
    i64.const 65354
    call $mere_vec_get
    local.set 5
    global.get $mem
    i64.const 65355
    call $mere_vec_get
    local.set 6
    local.get 1
    i64.const 8
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 38912
    else
    i64.const 39936
    end
    local.set 7
    local.get 1
    i64.const 64
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 38912
    else
    i64.const 39936
    end
    local.set 8
    local.get 1
    i64.const 16
    i64.and
    local.set 9
    local.get 1
    i64.const 32
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    local.get 5
    i64.ge_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.set 10
    local.get 10
    local.get 6
    local.get 9
    local.get 8
    local.get 0
    local.get 5
    local.get 1
    local.get 7
    local.get 4
    local.get 3
    global.get $bgc
    global.get $fb
    local.get 2
    i64.const 0
    call $__lifted_px_2
    drop
    local.get 1
    i64.const 2
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 1
    i64.const 4
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 8
    else
    i64.const 16
    end
    local.set 11
    global.get $mem
    local.get 0
    local.get 11
    global.get $bgc
    global.get $fb
    i64.const 39
    return_call $__lifted_spr_3
    end
    end)
  (func $tilecolor (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    local.get 2
    i64.extend_i32_u)
  (func $tick (param i64) (result i64)
    (local i64 i64 i64 i64)
    local.get 0
    i64.const 4
    i64.mul
    local.set 1
    global.get $sys
    i64.const 0
    global.get $sys
    i64.const 0
    call $mere_vec_get
    local.get 1
    i64.add
    call $mere_vec_set
    drop
    global.get $sys
    global.get $mem
    i64.const 0
    call $__lifted_dl_5
    drop
    global.get $apuacc
    i64.const 0
    global.get $apuacc
    i64.const 0
    call $mere_vec_get
    local.get 0
    i64.add
    call $mere_vec_set
    drop
    global.get $apuacc
    i64.const 0
    call $__lifted_al_6
    drop
    global.get $mem
    i64.const 65287
    call $mere_vec_get
    local.set 2
    local.get 2
    i64.const 4
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 2
    i64.const 3
    i64.and
    local.set 3
    local.get 3
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1024
    else
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 16
    else
    local.get 3
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 64
    else
    i64.const 256
    end
    end
    end
    local.set 4
    global.get $sys
    i64.const 1
    global.get $sys
    i64.const 1
    call $mere_vec_get
    local.get 1
    i64.add
    call $mere_vec_set
    drop
    global.get $sys
    local.get 4
    global.get $mem
    i64.const 0
    return_call $__lifted_tl_7
    end)
  (func $step (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    local.get 2
    i64.extend_i32_u)
  (func $cb (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 69
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $cb_rot (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 70
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $daa (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    global.get $rA
    call $mere_vec_get
    local.set 1
    local.get 0
    global.get $fN
    call $mere_vec_get
    local.set 2
    local.get 0
    global.get $fH
    call $mere_vec_get
    local.set 3
    local.get 0
    global.get $fC
    call $mere_vec_get
    local.set 4
    local.get 2
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 1
    i64.const 153
    i64.gt_s
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.set 5
    local.get 5
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 96
    i64.add
    else
    local.get 1
    end
    local.set 6
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 6
    i64.const 15
    i64.and
    i64.const 9
    i64.gt_s
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 6
    i64.const 6
    i64.add
    else
    local.get 6
    end
    local.set 7
    local.get 7
    call $mask8
    local.set 8
    local.get 0
    global.get $rA
    local.get 8
    call $mere_vec_set
    drop
    local.get 0
    global.get $fZ
    local.get 8
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 0
    global.get $fH
    i64.const 0
    call $mere_vec_set
    drop
    local.get 0
    global.get $fC
    local.get 5
    call $mere_vec_set
    else
    local.get 4
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 96
    i64.sub
    else
    local.get 1
    end
    local.set 9
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 9
    i64.const 6
    i64.sub
    else
    local.get 9
    end
    local.set 10
    local.get 10
    call $mask8
    local.set 11
    local.get 0
    global.get $rA
    local.get 11
    call $mere_vec_set
    drop
    local.get 0
    global.get $fZ
    local.get 11
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 0
    global.get $fH
    i64.const 0
    call $mere_vec_set
    end)
  (func $cond (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 71
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $set_pair (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 72
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $get_pair (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 73
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $add_hl (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 74
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $dec_r (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 75
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $inc_r (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 76
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $alu (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 77
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $pop16 (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 78
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $push16 (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 79
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $set_flags (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 80
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $set_r (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 81
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $get_r (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 82
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $unpack_f (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 83
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $pack_f (param i64) (result i64)
    local.get 0
    global.get $fZ
    call $mere_vec_get
    i64.const 7
    i64.shl
    local.get 0
    global.get $fN
    call $mere_vec_get
    i64.const 6
    i64.shl
    local.get 0
    global.get $fH
    call $mere_vec_get
    i64.const 5
    i64.shl
    local.get 0
    global.get $fC
    call $mere_vec_get
    i64.const 4
    i64.shl
    i64.or
    i64.or
    i64.or)
  (func $set_de (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 84
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $set_bc (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 85
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $set_hl (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 86
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $get_de (param i64) (result i64)
    local.get 0
    global.get $rD
    call $mere_vec_get
    i64.const 256
    i64.mul
    local.get 0
    global.get $rE
    call $mere_vec_get
    i64.add)
  (func $get_bc (param i64) (result i64)
    local.get 0
    global.get $rB
    call $mere_vec_get
    i64.const 256
    i64.mul
    local.get 0
    global.get $rC
    call $mere_vec_get
    i64.add)
  (func $get_hl (param i64) (result i64)
    local.get 0
    global.get $rH
    call $mere_vec_get
    i64.const 256
    i64.mul
    local.get 0
    global.get $rL
    call $mere_vec_get
    i64.add)
  (func $fetch16 (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 87
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $fetch (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 88
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $wr (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 89
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $joypad (param i64) (result i64)
    (local i64 i64 i64 i64)
    local.get 0
    i64.const 48
    i64.and
    local.set 1
    i64.const 0
    call $dom_key_held
    i64.const 1
    call $dom_key_held
    i64.const 1
    i64.shl
    i64.const 2
    call $dom_key_held
    i64.const 2
    i64.shl
    i64.const 3
    call $dom_key_held
    i64.const 3
    i64.shl
    i64.or
    i64.or
    i64.or
    local.set 2
    i64.const 4
    call $dom_key_held
    i64.const 5
    call $dom_key_held
    i64.const 1
    i64.shl
    i64.const 6
    call $dom_key_held
    i64.const 2
    i64.shl
    i64.const 7
    call $dom_key_held
    i64.const 3
    i64.shl
    i64.or
    i64.or
    i64.or
    local.set 3
    local.get 1
    i64.const 16
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    else
    local.get 1
    i64.const 32
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    else
    i64.const 0
    end
    end
    local.set 4
    i64.const 192
    local.get 1
    local.get 4
    i64.const 15
    i64.xor
    i64.const 15
    i64.and
    i64.or
    i64.or)
  (func $apu_len_step (param i64) (result i64)
    global.get $apu
    i64.const 0
    return_call $__lifted_ch_8)
  (func $apu_off (param i64) (result i64)
    global.get $apu
    i64.const 0
    i64.const 0
    call $mere_vec_set
    drop
    global.get $apu
    i64.const 4
    i64.const 0
    call $mere_vec_set
    drop
    i64.const 0
    i64.const 0
    i64.const 0
    call $dom_audio_tone
    i64.const 0
    drop
    i64.const 1
    i64.const 0
    i64.const 0
    call $dom_audio_tone
    i64.const 0)
  (func $apu_trigger (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 90
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $apu_freq (param i64) (result i64)
    local.get 0
    i64.const 2048
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    i64.const 131072
    i64.const 2048
    local.get 0
    i64.sub
    i64.div_s
    end)
  (func $rd (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 91
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $initload (param i64) (result i64)
    local.get 0
    i64.const 32768
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $mem
    local.get 0
    local.get 0
    global.get $romn
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    global.get $rom
    local.get 0
    call $mere_vec_get
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 0
    i64.const 1
    i64.add
    return_call $initload
    end)
  (func $set_bank (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    end
    local.set 1
    global.get $mbc
    i64.const 0
    local.get 1
    call $mere_vec_set
    drop
    local.get 1
    i64.const 16384
    i64.mul
    local.set 2
    global.get $mem
    local.get 2
    global.get $romn
    global.get $rom
    i64.const 0
    return_call $__lifted_cp_9)
  (func $romld (param i64) (result i64)
    local.get 0
    global.get $romn
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    global.get $rom
    local.get 0
    local.get 0
    call $dom_rom_byte
    call $mere_vec_set
    drop
    local.get 0
    i64.const 1
    i64.add
    return_call $romld
    end)
  (func $new_vec (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 92
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $lo8 (param i64) (result i64)
    local.get 0
    i64.const 255
    i64.and)
  (func $hi8 (param i64) (result i64)
    local.get 0
    i64.const 8
    i64.shr_s
    i64.const 255
    i64.and)
  (func $mask16 (param i64) (result i64)
    local.get 0
    i64.const 65535
    i64.and)
  (func $mask8 (param i64) (result i64)
    local.get 0
    i64.const 255
    i64.and)
  (func $pad_left (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 93
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $pad_right (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 94
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $utf8_width (param i64) (result i64)
    (local i64 i64 i64)
    local.get 0
    call $_u8w_go
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 0
    call $__lang_strlen
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_u8w_go (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 95
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $_eaw_width (param i64) (result i64)
    local.get 0
    i64.const 768
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 879
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 12351
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 4352
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 4447
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 11904
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 42191
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 43360
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 43391
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 44032
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 55203
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 63744
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 64255
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 65040
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 65049
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 65072
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 65135
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 65280
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 65376
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 65504
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 65510
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 127744
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 128767
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 129280
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 129535
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 0
    i64.const 131072
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 262141
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    end
    i32.wrap_i64
    if (result i64)
    i64.const 2
    else
    i64.const 1
    end
    end
    end)
  (func $utf8_rev (param i64) (result i64)
    (local i64)
    local.get 0
    call $__lang_utf8_chars
    call $_u8_rev_join
    local.set 1
    local.get 1
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 68
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_u8_rev_join (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 96
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $utf8_sub (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 97
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $_u8_slice (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 98
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $utf8_at (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 99
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $_u8_nth (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 100
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $list_product (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    call $list_fold
    local.set 2
    local.get 2
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
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
    i32.const 101
    i32.store offset=4
    local.get 4
    i64.extend_i32_u
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $list_sum (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    call $list_fold
    local.set 2
    local.get 2
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 1
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
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
    i32.const 102
    i32.store offset=4
    local.get 4
    i64.extend_i32_u
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $range (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 103
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $_range_down (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 104
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $list_fold (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 1
    local.get 1
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 1
    local.get 0
    i64.store offset=0
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
    i32.const 105
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $__lifted_go_10 (param i64) (param i64) (param i64) (param i64) (result i64)
    local.get 3
    local.get 0
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 1
    local.get 2
    call $mere_vec_push
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    i64.const 1
    i64.add
    return_call $__lifted_go_10
    end)
  (func $__lifted_cp_9 (param i64) (param i64) (param i64) (param i64) (param i64) (result i64)
    local.get 4
    i64.const 16384
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 16384
    local.get 4
    i64.add
    local.get 1
    local.get 4
    i64.add
    local.get 2
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    local.get 1
    local.get 4
    i64.add
    call $mere_vec_get
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    i64.const 1
    i64.add
    return_call $__lifted_cp_9
    end)
  (func $__lifted_ch_8 (param i64) (param i64) (result i64)
    (local i64)
    local.get 1
    i64.const 4
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    local.get 1
    call $mere_vec_get
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    local.get 1
    i64.const 3
    i64.add
    call $mere_vec_get
    i64.const 0
    i64.gt_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 0
    local.get 1
    i64.const 3
    i64.add
    call $mere_vec_get
    i64.const 1
    i64.sub
    local.set 2
    local.get 0
    local.get 1
    i64.const 3
    i64.add
    local.get 2
    call $mere_vec_set
    drop
    local.get 2
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    local.get 1
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    i64.const 4
    i64.div_s
    i64.const 0
    i64.const 0
    call $dom_audio_tone
    i64.const 0
    else
    i64.const 0
    end
    else
    i64.const 0
    end
    drop
    local.get 0
    local.get 1
    i64.const 4
    i64.add
    return_call $__lifted_ch_8
    end)
  (func $__lifted_tl_7 (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i64.const 1
    call $mere_vec_get
    local.get 1
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1
    local.get 0
    i64.const 1
    call $mere_vec_get
    local.get 1
    i64.sub
    call $mere_vec_set
    drop
    local.get 2
    i64.const 65285
    call $mere_vec_get
    i64.const 1
    i64.add
    local.set 4
    local.get 4
    i64.const 255
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    i64.const 65285
    local.get 2
    i64.const 65286
    call $mere_vec_get
    call $mere_vec_set
    drop
    local.get 2
    i64.const 65295
    local.get 2
    i64.const 65295
    call $mere_vec_get
    i64.const 4
    i64.or
    call $mere_vec_set
    else
    local.get 2
    i64.const 65285
    local.get 4
    call $mere_vec_set
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    i64.const 0
    return_call $__lifted_tl_7
    else
    i64.const 0
    end)
  (func $__lifted_al_6 (param i64) (param i64) (result i64)
    local.get 0
    i64.const 0
    call $mere_vec_get
    i64.const 4096
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 0
    local.get 0
    i64.const 0
    call $mere_vec_get
    i64.const 4096
    i64.sub
    call $mere_vec_set
    drop
    i64.const 0
    call $apu_len_step
    drop
    local.get 0
    i64.const 0
    return_call $__lifted_al_6
    else
    i64.const 0
    end)
  (func $__lifted_dl_5 (param i64) (param i64) (param i64) (result i64)
    local.get 0
    i64.const 0
    call $mere_vec_get
    i64.const 256
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 0
    local.get 0
    i64.const 0
    call $mere_vec_get
    i64.const 256
    i64.sub
    call $mere_vec_set
    drop
    local.get 1
    i64.const 65284
    local.get 1
    i64.const 65284
    call $mere_vec_get
    i64.const 1
    i64.add
    i64.const 255
    i64.and
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    i64.const 0
    return_call $__lifted_dl_5
    else
    i64.const 0
    end)
  (func $__lifted_sp_4 (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64 i64 i64)
    local.get 9
    i64.const 8
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 9
    else
    i64.const 7
    local.get 9
    i64.sub
    end
    local.set 10
    local.get 1
    local.get 10
    i64.shr_s
    i64.const 1
    i64.and
    local.get 2
    local.get 10
    i64.shr_s
    i64.const 1
    i64.and
    i64.const 1
    i64.shl
    i64.or
    local.set 11
    local.get 3
    local.get 9
    i64.add
    local.set 12
    local.get 11
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 12
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 12
    i64.const 160
    i64.ge_s
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 4
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 5
    local.get 6
    i64.const 160
    i64.mul
    local.get 12
    i64.add
    call $mere_vec_get
    i64.const 0
    i64.ne
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 7
    local.get 6
    i64.const 160
    i64.mul
    local.get 12
    i64.add
    local.get 8
    local.get 11
    i64.const 2
    i64.mul
    i64.shr_s
    i64.const 3
    i64.and
    call $mere_vec_set
    end
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    local.get 6
    local.get 7
    local.get 8
    local.get 9
    i64.const 1
    i64.add
    return_call $__lifted_sp_4
    end)
  (func $__lifted_spr_3 (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 5
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 65024
    local.get 5
    i64.const 4
    i64.mul
    i64.add
    call $mere_vec_get
    i64.const 16
    i64.sub
    local.set 6
    local.get 0
    i64.const 65024
    local.get 5
    i64.const 4
    i64.mul
    i64.add
    i64.const 1
    i64.add
    call $mere_vec_get
    i64.const 8
    i64.sub
    local.set 7
    local.get 0
    i64.const 65024
    local.get 5
    i64.const 4
    i64.mul
    i64.add
    i64.const 2
    i64.add
    call $mere_vec_get
    local.set 8
    local.get 0
    i64.const 65024
    local.get 5
    i64.const 4
    i64.mul
    i64.add
    i64.const 3
    i64.add
    call $mere_vec_get
    local.set 9
    local.get 1
    local.get 6
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    local.get 6
    local.get 2
    i64.add
    i64.lt_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    local.get 6
    i64.sub
    local.set 10
    local.get 9
    i64.const 64
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    i64.const 1
    i64.sub
    local.get 10
    i64.sub
    else
    local.get 10
    end
    local.set 11
    local.get 2
    i64.const 16
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 8
    i64.const 254
    i64.and
    else
    local.get 8
    end
    local.set 12
    i64.const 32768
    local.get 12
    local.get 11
    i64.const 8
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    i64.add
    i64.const 16
    i64.mul
    i64.add
    local.get 11
    i64.const 7
    i64.and
    i64.const 2
    i64.mul
    i64.add
    local.set 13
    local.get 0
    local.get 13
    call $mere_vec_get
    local.set 14
    local.get 0
    local.get 13
    i64.const 1
    i64.add
    call $mere_vec_get
    local.set 15
    local.get 9
    i64.const 16
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 65352
    call $mere_vec_get
    else
    local.get 0
    i64.const 65353
    call $mere_vec_get
    end
    local.set 16
    local.get 9
    i64.const 128
    i64.and
    local.set 17
    local.get 9
    i64.const 32
    i64.and
    local.set 18
    local.get 18
    local.get 14
    local.get 15
    local.get 7
    local.get 17
    local.get 3
    local.get 1
    local.get 4
    local.get 16
    i64.const 0
    call $__lifted_sp_4
    else
    i64.const 0
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    i64.const 1
    i64.sub
    return_call $__lifted_spr_3
    end)
  (func $__lifted_px_2 (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64)
    local.get 13
    i64.const 160
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 13
    i64.const 7
    i64.add
    local.get 1
    i64.ge_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $tilecolor
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 13
    i64.const 7
    i64.add
    local.get 1
    i64.sub
    local.get 16
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    local.get 5
    i64.sub
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    else
    local.get 6
    i64.const 1
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $tilecolor
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 13
    local.get 8
    i64.add
    i64.const 255
    i64.and
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    local.get 9
    i64.add
    i64.const 255
    i64.and
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    else
    i64.const 0
    end
    end
    local.set 14
    local.get 10
    local.get 4
    i64.const 160
    i64.mul
    local.get 13
    i64.add
    local.get 14
    call $mere_vec_set
    drop
    local.get 11
    local.get 4
    i64.const 160
    i64.mul
    local.get 13
    i64.add
    local.get 12
    local.get 14
    i64.const 2
    i64.mul
    i64.shr_s
    i64.const 3
    i64.and
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    local.get 6
    local.get 7
    local.get 8
    local.get 9
    local.get 10
    local.get 11
    local.get 12
    local.get 13
    i64.const 1
    i64.add
    return_call $__lifted_px_2
    end)
  (func $__lifted_ll_1 (param i64) (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i64.const 2
    call $mere_vec_get
    i64.const 456
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 2
    local.get 0
    i64.const 2
    call $mere_vec_get
    i64.const 456
    i64.sub
    call $mere_vec_set
    drop
    local.get 1
    i64.const 65348
    call $mere_vec_get
    local.set 3
    local.get 3
    i64.const 144
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $render_line
    else
    i64.const 0
    end
    drop
    local.get 3
    i64.const 1
    i64.add
    local.set 4
    local.get 4
    i64.const 144
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 65295
    local.get 1
    i64.const 65295
    call $mere_vec_get
    i64.const 1
    i64.or
    call $mere_vec_set
    else
    i64.const 0
    end
    drop
    local.get 1
    i64.const 65348
    local.get 4
    i64.const 153
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 4
    end
    call $mere_vec_set
    drop
    local.get 0
    local.get 1
    i64.const 0
    return_call $__lifted_ll_1
    else
    i64.const 0
    end)
  (func $__lifted_go_uq1_0 (param i64) (param i64) (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64 i64 i64)
    local.get 5
    i64.const 23040
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 0
    local.get 5
    call $mere_vec_get
    local.set 6
    local.get 6
    local.get 1
    local.get 5
    call $mere_vec_get
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 1
    local.get 5
    local.get 6
    call $mere_vec_set
    drop
    local.get 2
    i64.const 0
    call $mere_vec_get
    local.get 6
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 3
    local.get 6
    call $color_of
    call $dom_canvas_fill_style
    i64.const 0
    drop
    local.get 2
    i64.const 0
    local.get 6
    call $mere_vec_set
    end
    drop
    local.get 5
    i64.const 160
    i64.div_s
    local.set 7
    local.get 5
    local.get 7
    i64.const 160
    i64.mul
    i64.sub
    local.set 8
    local.get 3
    local.get 8
    local.get 4
    i64.mul
    local.get 7
    local.get 4
    i64.mul
    local.get 4
    local.get 4
    call $dom_canvas_fill_rect
    i64.const 0
    end
    drop
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    local.get 5
    i64.const 1
    i64.add
    return_call $__lifted_go_uq1_0
    end)
  (func $frame_closure (param i64) (param i64) (result i64)
    local.get 1
    call $frame)
  (func $render_closure (param i64) (param i64) (result i64)
    local.get 1
    call $render)
  (func $color_of_closure (param i64) (param i64) (result i64)
    local.get 1
    call $color_of)
  (func $drive_closure (param i64) (param i64) (result i64)
    local.get 1
    call $drive)
  (func $service_closure (param i64) (param i64) (result i64)
    local.get 1
    call $service)
  (func $lowbit_closure (param i64) (param i64) (result i64)
    local.get 1
    call $lowbit)
  (func $ppu_closure (param i64) (param i64) (result i64)
    local.get 1
    call $ppu)
  (func $render_line_closure (param i64) (param i64) (result i64)
    local.get 1
    call $render_line)
  (func $tilecolor_closure (param i64) (param i64) (result i64)
    local.get 1
    call $tilecolor)
  (func $tick_closure (param i64) (param i64) (result i64)
    local.get 1
    call $tick)
  (func $step_closure (param i64) (param i64) (result i64)
    local.get 1
    call $step)
  (func $cb_closure (param i64) (param i64) (result i64)
    local.get 1
    call $cb)
  (func $cb_rot_closure (param i64) (param i64) (result i64)
    local.get 1
    call $cb_rot)
  (func $daa_closure (param i64) (param i64) (result i64)
    local.get 1
    call $daa)
  (func $cond_closure (param i64) (param i64) (result i64)
    local.get 1
    call $cond)
  (func $set_pair_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_pair)
  (func $get_pair_closure (param i64) (param i64) (result i64)
    local.get 1
    call $get_pair)
  (func $add_hl_closure (param i64) (param i64) (result i64)
    local.get 1
    call $add_hl)
  (func $dec_r_closure (param i64) (param i64) (result i64)
    local.get 1
    call $dec_r)
  (func $inc_r_closure (param i64) (param i64) (result i64)
    local.get 1
    call $inc_r)
  (func $alu_closure (param i64) (param i64) (result i64)
    local.get 1
    call $alu)
  (func $pop16_closure (param i64) (param i64) (result i64)
    local.get 1
    call $pop16)
  (func $push16_closure (param i64) (param i64) (result i64)
    local.get 1
    call $push16)
  (func $set_flags_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_flags)
  (func $set_r_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_r)
  (func $get_r_closure (param i64) (param i64) (result i64)
    local.get 1
    call $get_r)
  (func $unpack_f_closure (param i64) (param i64) (result i64)
    local.get 1
    call $unpack_f)
  (func $pack_f_closure (param i64) (param i64) (result i64)
    local.get 1
    call $pack_f)
  (func $set_de_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_de)
  (func $set_bc_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_bc)
  (func $set_hl_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_hl)
  (func $get_de_closure (param i64) (param i64) (result i64)
    local.get 1
    call $get_de)
  (func $get_bc_closure (param i64) (param i64) (result i64)
    local.get 1
    call $get_bc)
  (func $get_hl_closure (param i64) (param i64) (result i64)
    local.get 1
    call $get_hl)
  (func $fetch16_closure (param i64) (param i64) (result i64)
    local.get 1
    call $fetch16)
  (func $fetch_closure (param i64) (param i64) (result i64)
    local.get 1
    call $fetch)
  (func $wr_closure (param i64) (param i64) (result i64)
    local.get 1
    call $wr)
  (func $joypad_closure (param i64) (param i64) (result i64)
    local.get 1
    call $joypad)
  (func $apu_len_step_closure (param i64) (param i64) (result i64)
    local.get 1
    call $apu_len_step)
  (func $apu_off_closure (param i64) (param i64) (result i64)
    local.get 1
    call $apu_off)
  (func $apu_trigger_closure (param i64) (param i64) (result i64)
    local.get 1
    call $apu_trigger)
  (func $apu_freq_closure (param i64) (param i64) (result i64)
    local.get 1
    call $apu_freq)
  (func $rd_closure (param i64) (param i64) (result i64)
    local.get 1
    call $rd)
  (func $initload_closure (param i64) (param i64) (result i64)
    local.get 1
    call $initload)
  (func $set_bank_closure (param i64) (param i64) (result i64)
    local.get 1
    call $set_bank)
  (func $romld_closure (param i64) (param i64) (result i64)
    local.get 1
    call $romld)
  (func $new_vec_closure (param i64) (param i64) (result i64)
    local.get 1
    call $new_vec)
  (func $lo8_closure (param i64) (param i64) (result i64)
    local.get 1
    call $lo8)
  (func $hi8_closure (param i64) (param i64) (result i64)
    local.get 1
    call $hi8)
  (func $mask16_closure (param i64) (param i64) (result i64)
    local.get 1
    call $mask16)
  (func $mask8_closure (param i64) (param i64) (result i64)
    local.get 1
    call $mask8)
  (func $pad_left_closure (param i64) (param i64) (result i64)
    local.get 1
    call $pad_left)
  (func $pad_right_closure (param i64) (param i64) (result i64)
    local.get 1
    call $pad_right)
  (func $utf8_width_closure (param i64) (param i64) (result i64)
    local.get 1
    call $utf8_width)
  (func $_u8w_go_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_u8w_go)
  (func $_eaw_width_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_eaw_width)
  (func $utf8_rev_closure (param i64) (param i64) (result i64)
    local.get 1
    call $utf8_rev)
  (func $_u8_rev_join_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_u8_rev_join)
  (func $utf8_sub_closure (param i64) (param i64) (result i64)
    local.get 1
    call $utf8_sub)
  (func $_u8_slice_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_u8_slice)
  (func $utf8_at_closure (param i64) (param i64) (result i64)
    local.get 1
    call $utf8_at)
  (func $_u8_nth_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_u8_nth)
  (func $list_product_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_product)
  (func $list_sum_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_sum)
  (func $range_closure (param i64) (param i64) (result i64)
    local.get 1
    call $range)
  (func $_range_down_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_range_down)
  (func $list_fold_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_fold)
  (func $anon_38_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 106
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_39_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    local.set 4
    local.get 4
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 5
    local.get 5
    if (result i64)
    local.get 3
    else
    local.get 4
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 6
    local.get 6
    if (result i32)
    local.get 4
    i32.wrap_i64
    i64.load offset=8
    local.set 7
    local.get 7
    i32.wrap_i64
    i64.load offset=0
    local.set 9
    i32.const 1
    local.set 10
    local.get 7
    i32.wrap_i64
    i64.load offset=8
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
    if (result i64)
    local.get 11
    call $list_fold
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 9
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 16
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_37_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 107
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_40_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    local.get 3
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    else
    local.get 3
    call $_range_down
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 1
    i64.sub
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $__lang_bump
    local.set 6
    local.get 6
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 6
    i64.const 1
    i64.store offset=0
    local.get 6
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 7
    local.get 2
    i64.store offset=0
    local.get 7
    local.get 1
    i64.store offset=8
    local.get 7
    i64.extend_i32_u
    i64.store offset=8
    local.get 6
    i64.extend_i32_u
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
  (func $anon_36_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $_range_down
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 5
    i64.const 0
    i64.store offset=0
    local.get 5
    i64.extend_i32_u
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_35_fn (param i64) (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i64.store offset=0
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
    i32.const 108
    i32.store offset=4
    local.get 3
    i64.extend_i32_u)
  (func $anon_41_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i64.add)
  (func $anon_34_fn (param i64) (param i64) (result i64)
    (local i32 i32)
    global.get $__lang_bump
    local.set 2
    local.get 2
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 2
    local.get 1
    i64.store offset=0
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
    i32.const 109
    i32.store offset=4
    local.get 3
    i64.extend_i32_u)
  (func $anon_42_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i64.mul)
  (func $anon_33_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 4
    local.get 4
    if (result i64)
    i64.const 601
    else
    local.get 3
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 5
    local.get 5
    if (result i32)
    local.get 3
    i32.wrap_i64
    i64.load offset=8
    local.set 6
    local.get 6
    i32.wrap_i64
    i64.load offset=0
    local.set 8
    i32.const 1
    local.set 9
    local.get 6
    i32.wrap_i64
    i64.load offset=8
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
    if (result i64)
    local.get 1
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 8
    else
    local.get 10
    call $_u8_nth
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    i64.const 1
    i64.sub
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    else
    unreachable
    end
    end)
  (func $anon_32_fn (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $__lang_utf8_chars
    call $_u8_nth
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_31_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 110
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_43_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 2
    i64.store offset=0
    local.get 4
    local.get 3
    i64.store offset=8
    local.get 4
    local.get 1
    i64.store offset=16
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
    i32.const 111
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_44_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    local.get 2
    local.set 5
    local.get 5
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 6
    local.get 6
    if (result i64)
    local.get 1
    else
    local.get 5
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 7
    local.get 7
    if (result i32)
    local.get 5
    i32.wrap_i64
    i64.load offset=8
    local.set 8
    local.get 8
    i32.wrap_i64
    i64.load offset=0
    local.set 10
    i32.const 1
    local.set 11
    local.get 8
    i32.wrap_i64
    i64.load offset=8
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
    if (result i64)
    local.get 3
    i64.const 0
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 12
    call $_u8_slice
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 1
    i64.sub
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 4
    i64.const 0
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 12
    call $_u8_slice
    local.set 22
    local.get 22
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 22
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 21
    local.get 21
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    i64.const 1
    i64.sub
    local.get 21
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 10
    call $__lang_str_concat
    local.get 20
    i32.wrap_i64
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
  (func $anon_30_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 112
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_45_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    call $__lang_utf8_chars
    call $_u8_slice
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 606
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_29_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.set 3
    local.get 3
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 4
    local.get 4
    if (result i64)
    local.get 1
    else
    local.get 3
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 5
    local.get 5
    if (result i32)
    local.get 3
    i32.wrap_i64
    i64.load offset=8
    local.set 6
    local.get 6
    i32.wrap_i64
    i64.load offset=0
    local.set 8
    i32.const 1
    local.set 9
    local.get 6
    i32.wrap_i64
    i64.load offset=8
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
    if (result i64)
    local.get 10
    call $_u8_rev_join
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 8
    local.get 1
    call $__lang_str_concat
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_28_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 113
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_46_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 2
    i64.store offset=0
    local.get 4
    local.get 1
    i64.store offset=8
    local.get 4
    local.get 3
    i64.store offset=16
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
    i32.const 114
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_47_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    local.get 2
    local.get 3
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    else
    local.get 4
    local.get 2
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    local.set 5
    local.get 5
    i64.const 194
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    call $_u8w_go
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 1
    i64.add
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    i64.const 1
    i64.add
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 5
    i64.const 224
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    i64.const 1
    i64.add
    local.get 3
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    call $_u8w_go
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 2
    i64.add
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i64.const 32
    i64.rem_s
    i64.const 64
    i64.mul
    local.get 4
    local.get 2
    i64.const 1
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.add
    call $_eaw_width
    i64.add
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i64.const 1
    i64.add
    end
    else
    local.get 5
    i64.const 240
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    i64.const 2
    i64.add
    local.get 3
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    call $_u8w_go
    local.set 14
    local.get 14
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 3
    i64.add
    local.get 14
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i64.const 16
    i64.rem_s
    i64.const 4096
    i64.mul
    local.get 4
    local.get 2
    i64.const 1
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.const 64
    i64.mul
    i64.add
    local.get 4
    local.get 2
    i64.const 2
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.add
    call $_eaw_width
    i64.add
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i64.const 1
    i64.add
    end
    else
    local.get 2
    i64.const 3
    i64.add
    local.get 3
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    call $_u8w_go
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 4
    i64.add
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 16
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i64.const 8
    i64.rem_s
    i64.const 262144
    i64.mul
    local.get 4
    local.get 2
    i64.const 1
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.const 4096
    i64.mul
    i64.add
    local.get 4
    local.get 2
    i64.const 2
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.const 64
    i64.mul
    i64.add
    local.get 4
    local.get 2
    i64.const 3
    i64.add
    call $__lang_char_at
    i32.wrap_i64
    i32.load8_u
    i64.extend_i32_u
    i64.const 64
    i64.rem_s
    i64.add
    call $_eaw_width
    i64.add
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    i64.const 1
    i64.add
    end
    end
    end
    end
    end)
  (func $anon_27_fn (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    local.get 2
    call $utf8_width
    i64.sub
    local.set 3
    local.get 3
    i64.const 0
    i64.le_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    else
    local.get 2
    i64.const 611
    local.get 3
    call $__lang_str_repeat
    call $__lang_str_concat
    end)
  (func $anon_26_fn (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    local.get 2
    call $utf8_width
    i64.sub
    local.set 3
    local.get 3
    i64.const 0
    i64.le_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    else
    i64.const 617
    local.get 3
    call $__lang_str_repeat
    local.get 2
    call $__lang_str_concat
    end)
  (func $anon_25_fn (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    call $mere_vec_new
    local.set 3
    local.get 2
    local.get 3
    local.get 1
    i64.const 0
    call $__lifted_go_10
    drop
    local.get 3)
  (func $anon_24_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.get 1
    call $mask16
    call $mere_vec_get)
  (func $anon_23_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 115
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_48_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 1
    i64.store offset=0
    local.get 4
    local.get 2
    i64.store offset=8
    local.get 4
    local.get 3
    i64.store offset=16
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
    i32.const 116
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_49_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 32
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 1
    i64.store offset=0
    local.get 5
    local.get 2
    i64.store offset=8
    local.get 5
    local.get 3
    i64.store offset=16
    local.get 5
    local.get 4
    i64.store offset=24
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
    i32.const 117
    i32.store offset=4
    local.get 6
    i64.extend_i32_u)
  (func $anon_50_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    local.get 0
    i32.wrap_i64
    i64.load offset=24
    local.set 5
    global.get $mem
    local.get 2
    call $mere_vec_get
    global.get $mem
    local.get 1
    call $mere_vec_get
    i64.const 7
    i64.and
    i64.const 8
    i64.shl
    i64.or
    local.set 6
    local.get 6
    call $apu_freq
    local.set 7
    global.get $mem
    local.get 3
    call $mere_vec_get
    i64.const 4
    i64.shr_s
    local.set 8
    global.get $mem
    local.get 1
    call $mere_vec_get
    i64.const 64
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 64
    global.get $mem
    local.get 4
    call $mere_vec_get
    i64.const 63
    i64.and
    i64.sub
    else
    i64.const 0
    end
    local.set 9
    global.get $apu
    local.get 5
    i64.const 1
    call $mere_vec_set
    drop
    global.get $apu
    local.get 5
    i64.const 1
    i64.add
    local.get 7
    call $mere_vec_set
    drop
    global.get $apu
    local.get 5
    i64.const 2
    i64.add
    local.get 8
    call $mere_vec_set
    drop
    global.get $apu
    local.get 5
    i64.const 3
    i64.add
    local.get 9
    call $mere_vec_set
    drop
    local.get 5
    i64.const 4
    i64.div_s
    local.get 7
    local.get 8
    call $dom_audio_tone
    i64.const 0)
  (func $anon_22_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 118
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_51_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    call $mask16
    local.set 4
    local.get 4
    i64.const 65280
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 65280
    local.get 1
    call $joypad
    call $mere_vec_set
    else
    local.get 4
    i64.const 8192
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    i64.const 16383
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 31
    i64.and
    return_call $set_bank
    else
    local.get 4
    i64.const 32768
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 3
    local.get 4
    local.get 1
    call $mask8
    call $mere_vec_set
    drop
    local.get 4
    i64.const 65300
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 128
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 0
    call $apu_trigger
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65297
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65298
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65299
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65300
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 4
    i64.const 65305
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 128
    i64.and
    i64.const 0
    i64.ne
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 4
    call $apu_trigger
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65302
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65303
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65304
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65305
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 4
    i64.const 65318
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 128
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 0
    return_call $apu_off
    else
    i64.const 0
    end
    end
    end
    end
    end
    end)
  (func $anon_21_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.set 3
    local.get 2
    local.get 3
    call $mere_vec_get
    local.set 4
    local.get 1
    global.get $rPC
    local.get 3
    i64.const 1
    i64.add
    call $mask16
    call $mere_vec_set
    drop
    local.get 4)
  (func $anon_20_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $fetch
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 2
    call $fetch
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 3
    local.get 5
    i64.const 256
    i64.mul
    i64.add)
  (func $anon_19_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    global.get $rH
    local.get 1
    call $hi8
    call $mere_vec_set
    drop
    local.get 2
    global.get $rL
    local.get 1
    call $lo8
    call $mere_vec_set)
  (func $anon_18_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    global.get $rB
    local.get 1
    call $hi8
    call $mere_vec_set
    drop
    local.get 2
    global.get $rC
    local.get 1
    call $lo8
    call $mere_vec_set)
  (func $anon_17_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    global.get $rD
    local.get 1
    call $hi8
    call $mere_vec_set
    drop
    local.get 2
    global.get $rE
    local.get 1
    call $lo8
    call $mere_vec_set)
  (func $anon_16_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    global.get $fZ
    local.get 1
    i64.const 7
    i64.shr_s
    i64.const 1
    i64.and
    call $mere_vec_set
    drop
    local.get 2
    global.get $fN
    local.get 1
    i64.const 6
    i64.shr_s
    i64.const 1
    i64.and
    call $mere_vec_set
    drop
    local.get 2
    global.get $fH
    local.get 1
    i64.const 5
    i64.shr_s
    i64.const 1
    i64.and
    call $mere_vec_set
    drop
    local.get 2
    global.get $fC
    local.get 1
    i64.const 4
    i64.shr_s
    i64.const 1
    i64.and
    call $mere_vec_set)
  (func $anon_15_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 119
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_52_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 1
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rB
    call $mere_vec_get
    else
    local.get 1
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rC
    call $mere_vec_get
    else
    local.get 1
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rD
    call $mere_vec_get
    else
    local.get 1
    i64.const 3
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rE
    call $mere_vec_get
    else
    local.get 1
    i64.const 4
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rH
    call $mere_vec_get
    else
    local.get 1
    i64.const 5
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $rL
    call $mere_vec_get
    else
    local.get 1
    i64.const 6
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $rd
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $get_hl
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 2
    global.get $rA
    call $mere_vec_get
    end
    end
    end
    end
    end
    end
    end)
  (func $anon_14_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 120
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_53_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 1
    i64.store offset=0
    local.get 4
    local.get 2
    i64.store offset=8
    local.get 4
    local.get 3
    i64.store offset=16
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
    i32.const 121
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_54_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    local.get 1
    call $mask8
    local.set 5
    local.get 2
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rB
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rC
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rD
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 3
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rE
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 4
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rH
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 5
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    global.get $rL
    local.get 5
    call $mere_vec_set
    else
    local.get 2
    i64.const 6
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    call $wr
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    call $get_hl
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 5
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    global.get $rA
    local.get 5
    call $mere_vec_set
    end
    end
    end
    end
    end
    end
    end)
  (func $anon_13_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 122
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_55_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 2
    i64.store offset=0
    local.get 4
    local.get 3
    i64.store offset=8
    local.get 4
    local.get 1
    i64.store offset=16
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
    i32.const 123
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_56_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    global.get $__lang_bump
    local.set 5
    local.get 5
    i32.const 32
    i32.add
    global.set $__lang_bump
    local.get 5
    local.get 2
    i64.store offset=0
    local.get 5
    local.get 3
    i64.store offset=8
    local.get 5
    local.get 4
    i64.store offset=16
    local.get 5
    local.get 1
    i64.store offset=24
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
    i32.const 124
    i32.store offset=4
    local.get 6
    i64.extend_i32_u)
  (func $anon_57_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    local.get 0
    i32.wrap_i64
    i64.load offset=24
    local.set 5
    local.get 2
    global.get $fZ
    local.get 3
    call $mere_vec_set
    drop
    local.get 2
    global.get $fN
    local.get 4
    call $mere_vec_set
    drop
    local.get 2
    global.get $fH
    local.get 5
    call $mere_vec_set
    drop
    local.get 2
    global.get $fC
    local.get 1
    call $mere_vec_set)
  (func $anon_12_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 125
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_58_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    global.get $rSP
    call $mere_vec_get
    i64.const 2
    i64.sub
    call $mask16
    local.set 4
    local.get 2
    global.get $rSP
    local.get 4
    call $mere_vec_set
    drop
    local.get 3
    call $wr
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $lo8
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 3
    call $wr
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    i64.const 1
    i64.add
    call $mask16
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $hi8
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_11_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    global.get $rSP
    call $mere_vec_get
    local.set 3
    local.get 2
    call $rd
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 2
    call $rd
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 1
    i64.add
    call $mask16
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 256
    i64.mul
    i64.add
    local.set 4
    local.get 1
    global.get $rSP
    local.get 3
    i64.const 2
    i64.add
    call $mask16
    call $mere_vec_set
    drop
    local.get 4)
  (func $anon_10_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 126
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_59_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    global.get $rA
    call $mere_vec_get
    local.set 4
    local.get 2
    global.get $fC
    call $mere_vec_get
    local.set 5
    local.get 3
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 5
    else
    i64.const 0
    end
    local.set 6
    local.get 4
    local.get 1
    i64.add
    local.get 6
    i64.add
    local.set 7
    local.get 4
    i64.const 15
    i64.and
    local.get 1
    i64.const 15
    i64.and
    i64.add
    local.get 6
    i64.add
    i64.const 15
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.set 8
    local.get 7
    call $mask8
    local.set 9
    local.get 2
    call $set_flags
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 9
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 8
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    i64.const 255
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    global.get $rA
    local.get 9
    call $mere_vec_set
    else
    local.get 3
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 3
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 7
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 3
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 5
    else
    i64.const 0
    end
    local.set 14
    local.get 4
    local.get 1
    i64.sub
    local.get 14
    i64.sub
    local.set 15
    local.get 4
    i64.const 15
    i64.and
    local.get 1
    i64.const 15
    i64.and
    i64.sub
    local.get 14
    i64.sub
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.set 16
    local.get 15
    call $mask8
    local.set 17
    local.get 2
    call $set_flags
    local.set 21
    local.get 21
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 17
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 21
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 16
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 15
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 3
    i64.const 7
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 2
    global.get $rA
    local.get 17
    call $mere_vec_set
    end
    else
    local.get 3
    i64.const 4
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    local.get 1
    i64.and
    local.set 22
    local.get 2
    call $set_flags
    local.set 26
    local.get 26
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 22
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 26
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 25
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 24
    local.get 24
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 24
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 23
    local.get 23
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 23
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    global.get $rA
    local.get 22
    call $mere_vec_set
    else
    local.get 3
    i64.const 5
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 4
    local.get 1
    i64.xor
    local.set 27
    local.get 2
    call $set_flags
    local.set 31
    local.get 31
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 27
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 31
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 30
    local.get 30
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 30
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 29
    local.get 29
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 29
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 28
    local.get 28
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 28
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    global.get $rA
    local.get 27
    call $mere_vec_set
    else
    local.get 4
    local.get 1
    i64.or
    local.set 32
    local.get 2
    call $set_flags
    local.set 36
    local.get 36
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 32
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 36
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 35
    local.get 35
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 35
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 34
    local.get 34
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 34
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 33
    local.get 33
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 33
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    global.get $rA
    local.get 32
    call $mere_vec_set
    end
    end
    end
    end)
  (func $anon_9_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 127
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_60_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    call $get_r
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i64.const 1
    i64.add
    call $mask8
    local.set 7
    local.get 2
    call $set_r
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 3
    global.get $fZ
    local.get 7
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 3
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 3
    global.get $fH
    local.get 4
    i64.const 15
    i64.and
    i64.const 15
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set)
  (func $anon_8_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 2
    i64.store offset=0
    local.get 3
    local.get 1
    i64.store offset=8
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
    i32.const 128
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_61_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    call $get_r
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 4
    local.get 4
    i64.const 1
    i64.sub
    call $mask8
    local.set 7
    local.get 2
    call $set_r
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 3
    global.get $fZ
    local.get 7
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 3
    global.get $fN
    i64.const 1
    call $mere_vec_set
    drop
    local.get 3
    global.get $fH
    local.get 4
    i64.const 15
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set)
  (func $anon_7_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $get_hl
    local.set 3
    local.get 3
    local.get 1
    i64.add
    local.set 4
    local.get 2
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 2
    global.get $fH
    local.get 3
    i64.const 4095
    i64.and
    local.get 1
    i64.const 4095
    i64.and
    i64.add
    i64.const 4095
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 2
    global.get $fC
    local.get 4
    i64.const 65535
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 2
    call $set_hl
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    call $mask16
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_6_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    return_call $get_bc
    else
    local.get 1
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    return_call $get_de
    else
    local.get 1
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    return_call $get_hl
    else
    local.get 2
    global.get $rSP
    call $mere_vec_get
    end
    end
    end)
  (func $anon_5_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 129
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_62_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $set_bc
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 2
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $set_de
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 2
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $set_hl
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    global.get $rSP
    local.get 1
    call $mask16
    call $mere_vec_set
    end
    end
    end)
  (func $anon_4_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $fZ
    call $mere_vec_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    else
    local.get 1
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $fZ
    call $mere_vec_get
    else
    local.get 1
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    global.get $fC
    call $mere_vec_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    else
    local.get 2
    global.get $fC
    call $mere_vec_get
    end
    end
    end)
  (func $anon_3_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 130
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_63_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 2
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 7
    i64.shr_s
    local.set 4
    local.get 1
    i64.const 1
    i64.shl
    local.get 4
    i64.or
    call $mask8
    local.set 5
    local.get 3
    call $set_flags
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 5
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 4
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 5
    else
    local.get 2
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 1
    i64.and
    local.set 10
    local.get 1
    i64.const 1
    i64.shr_s
    local.get 10
    i64.const 7
    i64.shl
    i64.or
    local.set 11
    local.get 3
    call $set_flags
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 11
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 14
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 14
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 10
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 11
    else
    local.get 2
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 7
    i64.shr_s
    local.set 16
    local.get 1
    i64.const 1
    i64.shl
    local.get 3
    global.get $fC
    call $mere_vec_get
    i64.or
    call $mask8
    local.set 17
    local.get 3
    call $set_flags
    local.set 21
    local.get 21
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 17
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 21
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 16
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 17
    else
    local.get 2
    i64.const 3
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 1
    i64.and
    local.set 22
    local.get 1
    i64.const 1
    i64.shr_s
    local.get 3
    global.get $fC
    call $mere_vec_get
    i64.const 7
    i64.shl
    i64.or
    local.set 23
    local.get 3
    call $set_flags
    local.set 27
    local.get 27
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 23
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 27
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 26
    local.get 26
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 26
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 25
    local.get 25
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 25
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 24
    local.get 24
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 22
    local.get 24
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 23
    else
    local.get 2
    i64.const 4
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 7
    i64.shr_s
    local.set 28
    local.get 1
    i64.const 1
    i64.shl
    call $mask8
    local.set 29
    local.get 3
    call $set_flags
    local.set 33
    local.get 33
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 29
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 33
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 32
    local.get 32
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 32
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 31
    local.get 31
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 31
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 30
    local.get 30
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 28
    local.get 30
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 29
    else
    local.get 2
    i64.const 5
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 1
    i64.and
    local.set 34
    local.get 1
    i64.const 1
    i64.shr_s
    local.get 1
    i64.const 128
    i64.and
    i64.or
    local.set 35
    local.get 3
    call $set_flags
    local.set 39
    local.get 39
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 35
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 39
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 38
    local.get 38
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 38
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 37
    local.get 37
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 37
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 36
    local.get 36
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 34
    local.get 36
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 35
    else
    local.get 2
    i64.const 6
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    i64.const 4
    i64.shr_s
    local.get 1
    i64.const 4
    i64.shl
    call $mask8
    i64.or
    local.set 40
    local.get 3
    call $set_flags
    local.set 44
    local.get 44
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 40
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 44
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 43
    local.get 43
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 43
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 42
    local.get 42
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 42
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 41
    local.get 41
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 41
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 40
    else
    local.get 1
    i64.const 1
    i64.and
    local.set 45
    local.get 1
    i64.const 1
    i64.shr_s
    local.set 46
    local.get 3
    call $set_flags
    local.set 50
    local.get 50
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 46
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.get 50
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 49
    local.get 49
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 49
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 48
    local.get 48
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 48
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 47
    local.get 47
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 45
    local.get 47
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 46
    end
    end
    end
    end
    end
    end
    end)
  (func $anon_2_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $fetch
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i64.const 6
    i64.shr_s
    local.set 5
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.set 6
    local.get 3
    i64.const 7
    i64.and
    local.set 7
    local.get 2
    call $get_r
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 8
    local.get 5
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $set_r
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $cb_rot
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 6
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 14
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 8
    local.get 14
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 5
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $fZ
    local.get 8
    i64.const 1
    local.get 6
    i64.shl
    i64.and
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 1
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    i64.const 1
    call $mere_vec_set
    else
    local.get 5
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $set_r
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 16
    local.get 16
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 8
    i64.const 1
    local.get 6
    i64.shl
    i64.const 255
    i64.xor
    i64.and
    local.get 16
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 2
    call $set_r
    local.set 21
    local.get 21
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 21
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 7
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 8
    i64.const 1
    local.get 6
    i64.shl
    i64.or
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end
    end)
  (func $anon_1_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    call $fetch
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 0
    else
    local.get 3
    i64.const 118
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rHALTED
    i64.const 1
    call $mere_vec_set
    else
    local.get 3
    i64.const 16
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    i64.const 0
    else
    local.get 3
    i64.const 243
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rIME
    i64.const 0
    call $mere_vec_set
    else
    local.get 3
    i64.const 251
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rEI
    i64.const 2
    call $mere_vec_set
    else
    local.get 3
    i64.const 203
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $cb
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_bc
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch16
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 17
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_de
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch16
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 33
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_hl
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch16
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 49
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rSP
    local.get 2
    call $fetch16
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 8
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch16
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 1
    global.get $rSP
    call $mere_vec_get
    local.set 16
    local.get 2
    call $wr
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 14
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 16
    call $lo8
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 2
    call $wr
    local.set 20
    local.get 20
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 14
    i64.const 1
    i64.add
    call $mask16
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 16
    call $hi8
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 2
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $wr
    local.set 22
    local.get 22
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_bc
    local.get 22
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 21
    local.get 21
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 21
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 18
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $wr
    local.set 24
    local.get 24
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_de
    local.get 24
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 23
    local.get 23
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 23
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 10
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 25
    local.get 25
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_bc
    local.get 25
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 26
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 26
    local.get 26
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_de
    local.get 26
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 34
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $get_hl
    local.set 27
    local.get 2
    call $wr
    local.set 29
    local.get 29
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 27
    local.get 29
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 28
    local.get 28
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 28
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 1
    call $set_hl
    local.set 30
    local.get 30
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 27
    i64.const 1
    i64.add
    call $mask16
    local.get 30
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 50
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $get_hl
    local.set 31
    local.get 2
    call $wr
    local.set 33
    local.get 33
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 31
    local.get 33
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 32
    local.get 32
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 32
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 1
    call $set_hl
    local.set 34
    local.get 34
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 31
    i64.const 1
    i64.sub
    call $mask16
    local.get 34
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 42
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $get_hl
    local.set 35
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 36
    local.get 36
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 35
    local.get 36
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    drop
    local.get 1
    call $set_hl
    local.set 37
    local.get 37
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 35
    i64.const 1
    i64.add
    call $mask16
    local.get 37
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 58
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $get_hl
    local.set 38
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 39
    local.get 39
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 38
    local.get 39
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    drop
    local.get 1
    call $set_hl
    local.set 40
    local.get 40
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 38
    i64.const 1
    i64.sub
    call $mask16
    local.get 40
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 224
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $wr
    local.set 42
    local.get 42
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65280
    local.get 2
    call $fetch
    local.set 43
    local.get 43
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 43
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.add
    local.get 42
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 41
    local.get 41
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 41
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 240
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 44
    local.get 44
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65280
    local.get 2
    call $fetch
    local.set 45
    local.get 45
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 45
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.add
    local.get 44
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 226
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $wr
    local.set 47
    local.get 47
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65280
    local.get 1
    global.get $rC
    call $mere_vec_get
    i64.add
    local.get 47
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 46
    local.get 46
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 46
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 242
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 48
    local.get 48
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 65280
    local.get 1
    global.get $rC
    call $mere_vec_get
    i64.add
    local.get 48
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 234
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $wr
    local.set 50
    local.get 50
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch16
    local.set 51
    local.get 51
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 51
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 50
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 49
    local.get 49
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.get 49
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 250
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 2
    call $rd
    local.set 52
    local.get 52
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch16
    local.set 53
    local.get 53
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 53
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 52
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 3
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 19
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 35
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 51
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 4
    i64.shr_s
    i64.const 3
    i64.and
    local.set 54
    local.get 1
    call $set_pair
    local.set 56
    local.get 56
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 54
    local.get 56
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 55
    local.get 55
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_pair
    local.set 57
    local.get 57
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 54
    local.get 57
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.add
    call $mask16
    local.get 55
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 11
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 27
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 43
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 59
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 4
    i64.shr_s
    i64.const 3
    i64.and
    local.set 58
    local.get 1
    call $set_pair
    local.set 60
    local.get 60
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 58
    local.get 60
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 59
    local.get 59
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_pair
    local.set 61
    local.get 61
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 58
    local.get 61
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.sub
    call $mask16
    local.get 59
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 9
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 25
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 41
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 57
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $add_hl
    local.set 62
    local.get 62
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_pair
    local.set 63
    local.get 63
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 4
    i64.shr_s
    i64.const 3
    i64.and
    local.get 63
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 62
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 232
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rSP
    call $mere_vec_get
    local.set 64
    local.get 2
    call $fetch
    local.set 66
    local.get 66
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 66
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 65
    local.get 65
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 65
    i64.const 256
    i64.sub
    else
    local.get 65
    end
    local.set 67
    local.get 1
    global.get $fZ
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    local.get 64
    i64.const 15
    i64.and
    local.get 65
    i64.const 15
    i64.and
    i64.add
    i64.const 15
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 1
    global.get $fC
    local.get 64
    i64.const 255
    i64.and
    local.get 65
    i64.const 255
    i64.and
    i64.add
    i64.const 255
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 1
    global.get $rSP
    local.get 64
    local.get 67
    i64.add
    call $mask16
    call $mere_vec_set
    else
    local.get 3
    i64.const 248
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rSP
    call $mere_vec_get
    local.set 68
    local.get 2
    call $fetch
    local.set 70
    local.get 70
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 70
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 69
    local.get 69
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 69
    i64.const 256
    i64.sub
    else
    local.get 69
    end
    local.set 71
    local.get 1
    global.get $fZ
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    local.get 68
    i64.const 15
    i64.and
    local.get 69
    i64.const 15
    i64.and
    i64.add
    i64.const 15
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 1
    global.get $fC
    local.get 68
    i64.const 255
    i64.and
    local.get 69
    i64.const 255
    i64.and
    i64.add
    i64.const 255
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    drop
    local.get 1
    call $set_hl
    local.set 72
    local.get 72
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 68
    local.get 71
    i64.add
    call $mask16
    local.get 72
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 249
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rSP
    local.get 1
    call $get_hl
    call $mere_vec_set
    else
    local.get 3
    i64.const 64
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 7
    i64.and
    i64.const 4
    i64.eq
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $inc_r
    local.set 74
    local.get 74
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 74
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 73
    local.get 73
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 73
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 64
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 7
    i64.and
    i64.const 5
    i64.eq
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $dec_r
    local.set 76
    local.get 76
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 76
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 75
    local.get 75
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 75
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 64
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 7
    i64.and
    i64.const 6
    i64.eq
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $set_r
    local.set 79
    local.get 79
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 79
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 78
    local.get 78
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 78
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 77
    local.get 77
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch
    local.set 80
    local.get 80
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 80
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 77
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 7
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.set 81
    local.get 81
    i64.const 7
    i64.shr_s
    local.set 82
    local.get 1
    global.get $rA
    local.get 81
    i64.const 1
    i64.shl
    local.get 82
    i64.or
    call $mask8
    call $mere_vec_set
    drop
    local.get 1
    call $set_flags
    local.set 86
    local.get 86
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 86
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 85
    local.get 85
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 85
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 84
    local.get 84
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 84
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 83
    local.get 83
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 82
    local.get 83
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 15
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.set 87
    local.get 87
    i64.const 1
    i64.and
    local.set 88
    local.get 1
    global.get $rA
    local.get 87
    i64.const 1
    i64.shr_s
    local.get 88
    i64.const 7
    i64.shl
    i64.or
    call $mere_vec_set
    drop
    local.get 1
    call $set_flags
    local.set 92
    local.get 92
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 92
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 91
    local.get 91
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 91
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 90
    local.get 90
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 90
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 89
    local.get 89
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 88
    local.get 89
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 23
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.set 93
    local.get 93
    i64.const 7
    i64.shr_s
    local.set 94
    local.get 1
    global.get $rA
    local.get 93
    i64.const 1
    i64.shl
    local.get 1
    global.get $fC
    call $mere_vec_get
    i64.or
    call $mask8
    call $mere_vec_set
    drop
    local.get 1
    call $set_flags
    local.set 98
    local.get 98
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 98
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 97
    local.get 97
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 97
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 96
    local.get 96
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 96
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 95
    local.get 95
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 94
    local.get 95
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 31
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    call $mere_vec_get
    local.set 99
    local.get 99
    i64.const 1
    i64.and
    local.set 100
    local.get 1
    global.get $rA
    local.get 99
    i64.const 1
    i64.shr_s
    local.get 1
    global.get $fC
    call $mere_vec_get
    i64.const 7
    i64.shl
    i64.or
    call $mere_vec_set
    drop
    local.get 1
    call $set_flags
    local.set 104
    local.get 104
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 104
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 103
    local.get 103
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 103
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 102
    local.get 102
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 102
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 101
    local.get 101
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 100
    local.get 101
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 39
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    return_call $daa
    else
    local.get 3
    i64.const 47
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rA
    local.get 1
    global.get $rA
    call $mere_vec_get
    i64.const 255
    i64.xor
    i64.const 255
    i64.and
    call $mere_vec_set
    drop
    local.get 1
    global.get $fN
    i64.const 1
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    i64.const 1
    call $mere_vec_set
    else
    local.get 3
    i64.const 55
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fC
    i64.const 1
    call $mere_vec_set
    else
    local.get 3
    i64.const 63
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $fN
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fH
    i64.const 0
    call $mere_vec_set
    drop
    local.get 1
    global.get $fC
    local.get 1
    global.get $fC
    call $mere_vec_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    call $mere_vec_set
    else
    local.get 3
    i64.const 64
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 127
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $set_r
    local.set 107
    local.get 107
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 107
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 106
    local.get 106
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 106
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 105
    local.get 105
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $get_r
    local.set 109
    local.get 109
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 109
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 108
    local.get 108
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 7
    i64.and
    local.get 108
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 105
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 191
    i64.le_s
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $alu
    local.set 111
    local.get 111
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 111
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 110
    local.get 110
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $get_r
    local.set 113
    local.get 113
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 113
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 112
    local.get 112
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 7
    i64.and
    local.get 112
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 110
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 198
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 206
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 214
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 222
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 230
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 238
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 246
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 254
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $alu
    local.set 115
    local.get 115
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 7
    i64.and
    local.get 115
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 114
    local.get 114
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $fetch
    local.set 116
    local.get 116
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 116
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 114
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 195
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rPC
    local.get 2
    call $fetch16
    local.set 117
    local.get 117
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 117
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 194
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 202
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 210
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 218
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch16
    local.set 119
    local.get 119
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 119
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 118
    local.get 1
    call $cond
    local.set 120
    local.get 120
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 3
    i64.and
    local.get 120
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rPC
    local.get 118
    call $mere_vec_set
    else
    i64.const 0
    end
    else
    local.get 3
    i64.const 233
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rPC
    local.get 1
    call $get_hl
    call $mere_vec_set
    else
    local.get 3
    i64.const 24
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch
    local.set 122
    local.get 122
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 122
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 121
    local.get 121
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 121
    i64.const 256
    i64.sub
    else
    local.get 121
    end
    local.set 123
    local.get 1
    global.get $rPC
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.get 123
    i64.add
    call $mask16
    call $mere_vec_set
    else
    local.get 3
    i64.const 32
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 40
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 48
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 56
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch
    local.set 125
    local.get 125
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 125
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 124
    local.get 1
    call $cond
    local.set 126
    local.get 126
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 3
    i64.and
    local.get 126
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 124
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 124
    i64.const 256
    i64.sub
    else
    local.get 124
    end
    local.set 127
    local.get 1
    global.get $rPC
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.get 127
    i64.add
    call $mask16
    call $mere_vec_set
    else
    i64.const 0
    end
    else
    local.get 3
    i64.const 205
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch16
    local.set 129
    local.get 129
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 129
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 128
    local.get 2
    call $push16
    local.set 131
    local.get 131
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 131
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 130
    local.get 130
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.get 130
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 1
    global.get $rPC
    local.get 128
    call $mere_vec_set
    else
    local.get 3
    i64.const 196
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 204
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 212
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 220
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $fetch16
    local.set 133
    local.get 133
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 133
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 132
    local.get 1
    call $cond
    local.set 134
    local.get 134
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 3
    i64.and
    local.get 134
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 136
    local.get 136
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 136
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 135
    local.get 135
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.get 135
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 1
    global.get $rPC
    local.get 132
    call $mere_vec_set
    else
    i64.const 0
    end
    else
    local.get 3
    i64.const 201
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rPC
    local.get 2
    call $pop16
    local.set 137
    local.get 137
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 137
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 217
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rIME
    i64.const 1
    call $mere_vec_set
    drop
    local.get 1
    global.get $rPC
    local.get 2
    call $pop16
    local.set 138
    local.get 138
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 138
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    local.get 3
    i64.const 192
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 200
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 208
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 216
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $cond
    local.set 139
    local.get 139
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    i64.const 3
    i64.shr_s
    i64.const 3
    i64.and
    local.get 139
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    i64.const 1
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    global.get $rPC
    local.get 2
    call $pop16
    local.set 140
    local.get 140
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 140
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    call $mere_vec_set
    else
    i64.const 0
    end
    else
    local.get 3
    i64.const 199
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 207
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 215
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 223
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 231
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 239
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 247
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get 3
    i64.const 255
    i64.eq
    i64.extend_i32_u
    end
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 142
    local.get 142
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 142
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 141
    local.get 141
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rPC
    call $mere_vec_get
    local.get 141
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    local.get 1
    global.get $rPC
    local.get 3
    i64.const 56
    i64.and
    call $mere_vec_set
    else
    local.get 3
    i64.const 197
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 144
    local.get 144
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 144
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 143
    local.get 143
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_bc
    local.get 143
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 213
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 146
    local.get 146
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 146
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 145
    local.get 145
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_de
    local.get 145
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 229
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 148
    local.get 148
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 148
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 147
    local.get 147
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    call $get_hl
    local.get 147
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 245
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $push16
    local.set 150
    local.get 150
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 150
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 149
    local.get 149
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    global.get $rA
    call $mere_vec_get
    i64.const 256
    i64.mul
    local.get 1
    call $pack_f
    i64.add
    local.get 149
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 193
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_bc
    local.set 151
    local.get 151
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $pop16
    local.set 152
    local.get 152
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 152
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 151
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 209
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_de
    local.set 153
    local.get 153
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $pop16
    local.set 154
    local.get 154
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 154
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 153
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 225
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $set_hl
    local.set 155
    local.get 155
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    call $pop16
    local.set 156
    local.get 156
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 156
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 155
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 3
    i64.const 241
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    call $pop16
    local.set 158
    local.get 158
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 158
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 157
    local.get 1
    global.get $rA
    local.get 157
    call $hi8
    call $mere_vec_set
    drop
    local.get 1
    call $unpack_f
    local.set 159
    local.get 159
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 157
    i64.const 240
    i64.and
    local.get 159
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    global.get $rHALT
    i64.const 1
    call $mere_vec_set
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
  (func $anon_0_fn (param i64) (param i64) (result i64)
    (local i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    global.get $__lang_bump
    local.set 3
    local.get 3
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 3
    local.get 1
    i64.store offset=0
    local.get 3
    local.get 2
    i64.store offset=8
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
    i32.const 131
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_64_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    global.get $__lang_bump
    local.set 4
    local.get 4
    i32.const 24
    i32.add
    global.set $__lang_bump
    local.get 4
    local.get 2
    i64.store offset=0
    local.get 4
    local.get 1
    i64.store offset=8
    local.get 4
    local.get 3
    i64.store offset=16
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
    i32.const 132
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_65_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 0
    i32.wrap_i64
    i64.load offset=8
    local.set 3
    local.get 0
    i32.wrap_i64
    i64.load offset=16
    local.set 4
    global.get $mem
    local.get 2
    local.get 1
    i64.const 8
    i64.div_s
    i64.const 32
    i64.mul
    i64.add
    local.get 3
    i64.const 8
    i64.div_s
    i64.add
    call $mere_vec_get
    local.set 5
    local.get 4
    i64.const 0
    i64.ne
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 32768
    local.get 5
    i64.const 16
    i64.mul
    i64.add
    else
    i64.const 36864
    local.get 5
    i64.const 128
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 5
    i64.const 256
    i64.sub
    else
    local.get 5
    end
    i64.const 16
    i64.mul
    i64.add
    end
    local.set 6
    global.get $mem
    local.get 6
    local.get 1
    i64.const 7
    i64.and
    i64.const 2
    i64.mul
    i64.add
    call $mere_vec_get
    local.set 7
    global.get $mem
    local.get 6
    local.get 1
    i64.const 7
    i64.and
    i64.const 2
    i64.mul
    i64.add
    i64.const 1
    i64.add
    call $mere_vec_get
    local.set 8
    i64.const 7
    local.get 3
    i64.const 7
    i64.and
    i64.sub
    local.set 9
    local.get 7
    local.get 9
    i64.shr_s
    i64.const 1
    i64.and
    local.get 8
    local.get 9
    i64.shr_s
    i64.const 1
    i64.and
    i64.const 1
    i64.shl
    i64.or)
  (func $show_int (param $n i64) (result i64)
    (local $buf i32) (local $i i32) (local $abs i64) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 24)))
    (local.set $i (i32.const 23))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then
        (local.set $neg (i32.const 1))
        ;; wraps at INT64_MIN; div_u/rem_u below read it as the correct
        ;; unsigned magnitude, so the full i64 range formats right.
        (local.set $abs (i64.sub (i64.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i64.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))))
    (block $end
      (loop $lp
        (br_if $end (i64.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48)
            (i32.wrap_i64 (i64.rem_u (local.get $abs) (i64.const 10)))))
        (local.set $abs (i64.div_u (local.get $abs) (i64.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))
  (func $__mcopy_unit (param $v i64) (result i64) (local.get $v))
  (func $main (export "main") (result i32)
    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i32)
    i64.const 0
    global.set $rA
    i64.const 1
    global.set $rB
    i64.const 2
    global.set $rC
    i64.const 3
    global.set $rD
    i64.const 4
    global.set $rE
    i64.const 5
    global.set $rH
    i64.const 6
    global.set $rL
    i64.const 7
    global.set $rSP
    i64.const 8
    global.set $rPC
    i64.const 9
    global.set $fZ
    i64.const 10
    global.set $fN
    i64.const 11
    global.set $fH
    i64.const 12
    global.set $fC
    i64.const 13
    global.set $rIME
    i64.const 14
    global.set $rHALT
    i64.const 15
    global.set $rHALTED
    i64.const 16
    global.set $rEI
    i64.const 65536
    call $new_vec
    local.set 0
    local.get 0
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 0
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $mem
    i64.const 0
    call $dom_rom_size
    global.set $romn
    global.get $romn
    call $new_vec
    local.set 1
    local.get 1
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $rom
    i64.const 0
    call $romld
    drop
    i64.const 1
    call $new_vec
    local.set 2
    local.get 2
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $mbc
    i64.const 0
    call $initload
    drop
    i64.const 8
    call $new_vec
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $apu
    i64.const 1
    call $new_vec
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $apuacc
    i64.const 73
    call $__lang_bytes_of_hex
    global.set $ctab
    i64.const 17
    call $new_vec
    local.set 5
    local.get 5
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 5
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $reg
    i64.const 3
    call $new_vec
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $sys
    i64.const 23040
    call $new_vec
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 7
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $fb
    i64.const 23040
    call $new_vec
    local.set 8
    local.get 8
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $bgc
    global.get $reg
    global.get $rA
    i64.const 1
    call $mere_vec_set
    drop
    global.get $reg
    call $set_bc
    local.set 9
    local.get 9
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 19
    local.get 9
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $reg
    call $set_de
    local.set 10
    local.get 10
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 216
    local.get 10
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $reg
    call $set_hl
    local.set 11
    local.get 11
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 333
    local.get 11
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    global.get $reg
    global.get $rSP
    i64.const 65534
    call $mere_vec_set
    drop
    global.get $reg
    global.get $rPC
    i64.const 256
    call $mere_vec_set
    drop
    global.get $reg
    call $set_flags
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 14
    local.get 14
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    local.get 14
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 13
    local.get 13
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 13
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 12
    local.get 12
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 1
    local.get 12
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    drop
    i64.const 590
    call $dom_get_by_id
    global.set $screen
    i64.const 3
    global.set $scale
    i64.const 23040
    call $new_vec
    local.set 16
    local.get 16
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    i64.const 1
    i64.sub
    local.get 16
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $prev
    i64.const 1
    call $new_vec
    local.set 17
    local.get 17
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 0
    i64.const 1
    i64.sub
    local.get 17
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    global.set $laststyle
    global.get $__lang_bump
    i32.const 3
    i32.add
    i32.const -4
    i32.and
    global.set $__lang_bump
    global.get $__lang_bump
    local.set 18
    local.get 18
    i32.const 8
    i32.add
    global.set $__lang_bump
    local.get 18
    i32.const 0
    i32.store offset=0
    local.get 18
    i32.const 0
    i32.store offset=4
    local.get 18
    i64.extend_i32_u
    call $dom_on_frame
    i64.const 0
    drop
    i64.const 0
    call $show_int
    call $puts
    i32.const 0)
)

