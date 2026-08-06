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
  (import "env" "cf_registry_data" (func $cf_registry_data_h (result i32)))
  (import "env" "cf_on_fetch" (func $cf_on_fetch_h (param i32)))
  (memory (export "memory") 1024)
  (func $puts (param i64) (call $puts_h (i32.wrap_i64 (local.get 0))))
  (func $cf_registry_data (result i64)
    (i64.extend_i32_u (call $cf_registry_data_h)))
  (func $cf_on_fetch (param i64)
    (call $cf_on_fetch_h (i32.wrap_i64 (local.get 0))))
  (table 62 funcref)
  (export "__indirect_function_table" (table 0))
  (elem (i32.const 0) $handler_closure $path_segments_closure $_split_seg_closure $resp_not_found_closure $resp_package_closure $resp_all_packages_closure $resp_landing_closure $extract_object_at_closure $json_esc_closure $_json_esc_walk_closure $json_str_field_closure $pad_left_closure $pad_right_closure $utf8_width_closure $_u8w_go_closure $_eaw_width_closure $utf8_rev_closure $_u8_rev_join_closure $utf8_sub_closure $_u8_slice_closure $utf8_at_closure $_u8_nth_closure $list_product_closure $list_sum_closure $list_append_closure $range_closure $_range_down_closure $list_fold_closure $list_rev_into_closure $anon_0_fn $anon_1_fn $anon_2_fn $anon_3_fn $anon_4_fn $anon_5_fn $anon_6_fn $anon_7_fn $anon_8_fn $anon_9_fn $anon_10_fn $anon_11_fn $anon_12_fn $anon_13_fn $anon_14_fn $anon_15_fn $anon_16_fn $anon_17_fn $anon_18_fn $anon_19_fn $anon_20_fn $anon_21_fn $anon_22_fn $anon_23_fn $anon_24_fn $anon_25_fn $anon_26_fn $anon_27_fn $anon_28_fn $anon_29_fn $anon_30_fn $anon_31_fn $anon_32_fn)
  (global $__lang_bump (export "__lang_bump") (mut i32) (i32.const 1659))
(global $__rgn_tmp (mut i64) (i64.const 0))
  (global $__lang_char_table i32 (i32.const 1147))
  (global $__lang_char_table_initialized (mut i32) (i32.const 0))
  (global $__lang_fail_flag (mut i32) (i32.const 0))
  (global $__lang_fail_active (mut i32) (i32.const 0))
  (data (i32.const 16) "method\00")
  (data (i32.const 23) "path\00")
  (data (i32.const 28) "GET\00")
  (data (i32.const 32) "only GET supported\0a\00")
  (data (i32.const 52) "/\00")
  (data (i32.const 54) "pkg\00")
  (data (i32.const 58) "pkg\00")
  (data (i32.const 62) "\00")
  (data (i32.const 63) "no such package: \00")
  (data (i32.const 81) "\0a\00")
  (data (i32.const 83) "pkg\00")
  (data (i32.const 87) "latest\00")
  (data (i32.const 94) "\00")
  (data (i32.const 95) "no such package: \00")
  (data (i32.const 113) "\0a\00")
  (data (i32.const 115) "latest\00")
  (data (i32.const 122) "\00")
  (data (i32.const 123) "no latest version\0a\00")
  (data (i32.const 142) "versions\00")
  (data (i32.const 151) "\00")
  (data (i32.const 152) "version metadata missing\0a\00")
  (data (i32.const 178) "{\22name\22:\22\00")
  (data (i32.const 188) "\22,\22version\22:\22\00")
  (data (i32.const 202) "\22,\00")
  (data (i32.const 205) "pkg\00")
  (data (i32.const 209) "\00")
  (data (i32.const 210) "no such package: \00")
  (data (i32.const 228) "\0a\00")
  (data (i32.const 230) "versions\00")
  (data (i32.const 239) "\00")
  (data (i32.const 240) "no such version: \00")
  (data (i32.const 258) "@\00")
  (data (i32.const 260) "\0a\00")
  (data (i32.const 262) "{\22name\22:\22\00")
  (data (i32.const 272) "\22,\22version\22:\22\00")
  (data (i32.const 286) "\22,\00")
  (data (i32.const 289) "unknown path: \00")
  (data (i32.const 304) "\0a\00")
  (data (i32.const 306) "/\00")
  (data (i32.const 308) "{\22status\22:404,\00")
  (data (i32.const 323) "\22headers\22:{\22content-type\22:\22text/plain\22},\00")
  (data (i32.const 364) "\22body\22:\22\00")
  (data (i32.const 373) "\22}\00")
  (data (i32.const 376) "{\22status\22:200,\00")
  (data (i32.const 391) "\22headers\22:{\22content-type\22:\22application/json\22},\00")
  (data (i32.const 438) "\22body_raw\22:true,\00")
  (data (i32.const 455) "\22body\22:\00")
  (data (i32.const 463) "}\00")
  (data (i32.const 465) "{\22status\22:200,\00")
  (data (i32.const 480) "\22headers\22:{\22content-type\22:\22application/json\22},\00")
  (data (i32.const 527) "\22body_raw\22:true,\00")
  (data (i32.const 544) "\22body\22:\00")
  (data (i32.const 552) "}\00")
  (data (i32.const 554) "{\22status\22:200,\00")
  (data (i32.const 569) "\22headers\22:{\22content-type\22:\22text/html; charset=utf-8\22},\00")
  (data (i32.const 624) "\22body\22:\22\00")
  (data (i32.const 633) "<!doctype html><title>mere package registry</title>\00")
  (data (i32.const 685) "<h1>mere package registry (v0.1)</h1>\00")
  (data (i32.const 723) "<p>Read-only JSON API. Endpoints:</p>\00")
  (data (i32.const 761) "<ul>\00")
  (data (i32.const 766) "<li><a href=/pkg>/pkg</a> &mdash; list all packages</li>\00")
  (data (i32.const 823) "<li>/pkg/&lt;name&gt; &mdash; one package&#39;s metadata</li>\00")
  (data (i32.const 885) "<li>/pkg/&lt;name&gt;/latest &mdash; latest version metadata</li>\00")
  (data (i32.const 951) "<li>/pkg/&lt;name&gt;/&lt;version&gt; &mdash; specific version</li>\00")
  (data (i32.const 1019) "</ul>\00")
  (data (i32.const 1025) "\22}\00")
  (data (i32.const 1028) "\00")
  (data (i32.const 1029) "i\00")
  (data (i32.const 1031) "end\00")
  (data (i32.const 1035) "i\00")
  (data (i32.const 1037) "{\00")
  (data (i32.const 1039) "depth\00")
  (data (i32.const 1045) "depth\00")
  (data (i32.const 1051) "}\00")
  (data (i32.const 1053) "depth\00")
  (data (i32.const 1059) "depth\00")
  (data (i32.const 1065) "depth\00")
  (data (i32.const 1071) "end\00")
  (data (i32.const 1075) "i\00")
  (data (i32.const 1077) "\00")
  (data (i32.const 1078) "\00")
  (data (i32.const 1079) " \00")
  (data (i32.const 1081) " \00")
  (data (i32.const 1083) "\22\00")
  (data (i32.const 1085) "\22:\22\00")
  (data (i32.const 1089) "\00")
  (data (i32.const 1090) "\22\00")
  (data (i32.const 1092) "\00")
  (data (i32.const 1093) "\5c\00")
  (data (i32.const 1095) "\5c\5c\00")
  (data (i32.const 1098) "\22\00")
  (data (i32.const 1100) "\5c\22\00")
  (data (i32.const 1103) "\0a\00")
  (data (i32.const 1105) "\5cn\00")
  (data (i32.const 1108) "\0d\00")
  (data (i32.const 1110) "\5cr\00")
  (data (i32.const 1113) "\09\00")
  (data (i32.const 1115) "\5ct\00")
  (data (i32.const 1118) "\22\00")
  (data (i32.const 1120) "\22:\00")
  (data (i32.const 1123) "\00")
  (data (i32.const 1124) "\00")
  (data (i32.const 1125) "{\00")
  (data (i32.const 1127) "\00")
  (data (i32.const 1128) "i\00")
  (data (i32.const 1130) "depth\00")
  (data (i32.const 1136) "end\00")
  (data (i32.const 1140) "end\00")
  (data (i32.const 1144) "\00")
  (data (i32.const 1145) "/\00")

  (func $__lang_strlen (param $s8 i64) (result i64)
    (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (i32.load8_u (i32.add (local.get $s) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (local.get $i)))
  (func $__lang_str_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $r i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
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
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_streq (param $a8 i64) (param $b8 i64) (result i64)
    (local $ba i32) (local $bb i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (block $not_eq
      (loop $lp
        (local.set $ba (i32.load8_u (local.get $a)))
        (local.set $bb (i32.load8_u (local.get $b)))
        (br_if $not_eq (i32.ne (local.get $ba) (local.get $bb)))
        (if (i32.eqz (local.get $ba))
          (then (return (i64.extend_i32_s (i32.const 1)))))
        (local.set $a (i32.add (local.get $a) (i32.const 1)))
        (local.set $b (i32.add (local.get $b) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 31.0: str_compare — returns -1 / 0 / 1 (sign-normalized, matches
  ;; interp's `compare s t` from OCaml stdlib).
  (func $__lang_str_compare (param $a8 i64) (param $b8 i64) (result i64)
    (local $ba i32) (local $bb i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (loop $lp
      (local.set $ba (i32.load8_u (local.get $a)))
      (local.set $bb (i32.load8_u (local.get $b)))
      (if (i32.lt_u (local.get $ba) (local.get $bb))
        (then (return (i64.extend_i32_s (i32.const -1)))))
      (if (i32.gt_u (local.get $ba) (local.get $bb))
        (then (return (i64.extend_i32_s (i32.const 1)))))
      (if (i32.eqz (local.get $ba))
        (then (return (i64.extend_i32_s (i32.const 0)))))
      (local.set $a (i32.add (local.get $a) (i32.const 1)))
      (local.set $b (i32.add (local.get $b) (i32.const 1)))
      (br $lp))
    (unreachable))
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
  (func $__lang_str_starts_with (param $s8 i64) (param $p8 i64) (result i64)
    (local $i i32) (local $cs i32) (local $cp i32)
    (local $s i32)
    (local $p i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (i32.wrap_i64 (local.get $p8)))
    (local.set $i (i32.const 0))
    (loop $lp
      (local.set $cp (i32.load8_u (i32.add (local.get $p) (local.get $i))))
      (if (i32.eqz (local.get $cp)) (then (return (i64.extend_i32_s (i32.const 1)))))
      (local.set $cs (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.ne (local.get $cs) (local.get $cp)) (then (return (i64.extend_i32_s (i32.const 0)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
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
        (local.set $r (global.get $__lang_bump))
        (i32.store8 (local.get $r) (i32.const 0))
        (global.set $__lang_bump (i32.add (local.get $r) (i32.const 1)))
        (return (i64.extend_i32_s (local.get $r)))))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: str_rev
  (func $__lang_str_rev (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: chr n — return char_table entry pointer for byte n.
  ;; Mask to a single byte (n & 0xFF) so out-of-range input can't index
  ;; past the 256-entry table into adjacent memory. Matches the C backend
  ;; ((unsigned char)n) and the self-host $chr (i32.store8 truncation).
  (func $__lang_char_at_chr (param $n8 i64) (result i64)
    (local $n i32)
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (global.get $__lang_char_table)
      (i32.mul (i32.and (local.get $n) (i32.const 255)) (i32.const 2)))))
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
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_to_lower (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
            (i32.store8 (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2)))
                        (local.get $k))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2))) (i32.const 1))
                        (i32.const 0))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $lp))))))
  (func $__lang_char_at (param $s8 i64) (param $i8 i64) (result i64)
    (local $s i32)
    (local $i i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (global.get $__lang_char_table)
             (i32.mul (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 2)))))
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
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 26.6: str_escape s — backslash-escape newline / tab / cr / backslash
  ;; / quote. show_str pipes through this so output matches interp. Worst-case
  ;; 2x byte expansion, region-allocated.
  (func $__lang_str_escape (param $s8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32) (local $c i32) (local $ec i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
    (local.set $r (global.get $__lang_bump))
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
  (func $mere_strbuf_new (result i64)
    (local $sb i32) (local $buf i32)
    (local.set $sb (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $sb) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $sb) (local.get $buf))
    (i32.store offset=4 (local.get $sb) (i32.const 0))
    (i32.store offset=8 (local.get $sb) (i32.const 16))
    (i64.extend_i32_s (local.get $sb)))
  (func $mere_strbuf_push (param $sb8 i64) (param $s8 i64) (result i64)
    (local $slen i32) (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local $sb i32)
    (local $s i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $slen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
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
    (i64.extend_i32_s (i32.const 0)))
  (func $mere_strbuf_to_str (param $sb8 i64) (result i64)
    (local $len i32) (local $out i32) (local $buf i32) (local $i i32)
    (local $sb i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
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
    (i64.extend_i32_s (local.get $out)))
  (func $mere_strbuf_len (param $sb8 i64) (result i64)
    (local $sb i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
    (i64.extend_i32_s (i32.load offset=4 (local.get $sb))))  (func $mere_map_key_eq_str (param $a i64) (param $b i64) (result i64)
    (i64.extend_i32_u (i32.wrap_i64 (call $__lang_streq (local.get $a) (local.get $b)))))  (func $__lang_hash_u32 (param $x8 i64) (result i64)
    (local $x i32)
    (local.set $x (i32.xor (i32.wrap_i64 (local.get $x8))
                           (i32.wrap_i64 (i64.shr_u (local.get $x8) (i64.const 32)))))
    (local.set $x (i32.xor (i32.xor (local.get $x) (i32.const 61)) (i32.shr_u (local.get $x) (i32.const 16))))
    (local.set $x (i32.add (local.get $x) (i32.shl (local.get $x) (i32.const 3))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 4))))
    (local.set $x (i32.mul (local.get $x) (i32.const 668265261)))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 15))))
    (i64.extend_i32_u (local.get $x)))
  (func $__lang_hash_str (param $s8 i64) (result i64)
    (local $h i32) (local $c i32) (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $h (i32.const 2166136261))
    (loop $lp
      (local.set $c (i32.load8_u (local.get $s)))
      (if (i32.eqz (local.get $c)) (then (return (i64.extend_i32_u (local.get $h)))))
      (local.set $h (i32.mul (i32.xor (local.get $h) (local.get $c)) (i32.const 16777619)))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (br $lp))
    (unreachable))
  (func $mere_map_key_hash_str (param $a i64) (result i64)
    (call $__lang_hash_str (local.get $a)))

  (func $mere_map_str_new (result i64)
    (local $m i32) (local $keys i32) (local $values i32) (local $idx i32) (local $i i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 24)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 32)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 32)))
    (local.set $idx (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $idx) (i32.const 32)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (i32.store offset=16 (local.get $m) (local.get $idx))
    (i32.store offset=20 (local.get $m) (i32.const 8))
    (local.set $i (i32.const 0))
    (block $fend (loop $fl
      (br_if $fend (i32.eq (local.get $i) (i32.const 8)))
      (i32.store (i32.add (local.get $idx) (i32.mul (local.get $i) (i32.const 4))) (i32.const -1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fl)))
    (i64.extend_i32_u (local.get $m)))
  (func $mere_map_str_reindex (param $m i32) (param $newcap i32)
    (local $ni i32) (local $i i32) (local $s i32) (local $len i32) (local $keys i32) (local $ncm1 i32) (local $h i32)
    (local.set $ni (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $ni) (i32.mul (local.get $newcap) (i32.const 4))))
    (local.set $i (i32.const 0))
    (block $fend (loop $fl
      (br_if $fend (i32.eq (local.get $i) (local.get $newcap)))
      (i32.store (i32.add (local.get $ni) (i32.mul (local.get $i) (i32.const 4))) (i32.const -1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fl)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $ncm1 (i32.sub (local.get $newcap) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $pend (loop $pl
      (br_if $pend (i32.eq (local.get $i) (local.get $len)))
      (local.set $h (i32.wrap_i64 (call $mere_map_key_hash_str
        (i64.load (i32.add (local.get $keys) (i32.mul (local.get $i) (i32.const 8)))))))
      (local.set $s (i32.and (local.get $h) (local.get $ncm1)))
      (block $placed (loop $probe
        (if (i32.eq (i32.load (i32.add (local.get $ni) (i32.mul (local.get $s) (i32.const 4)))) (i32.const -1))
          (then
            (i32.store (i32.add (local.get $ni) (i32.mul (local.get $s) (i32.const 4))) (local.get $i))
            (br $placed)))
        (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $ncm1)))
        (br $probe)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $pl)))
    (i32.store offset=16 (local.get $m) (local.get $ni))
    (i32.store offset=20 (local.get $m) (local.get $newcap)))
  (func $mere_map_str_set (param $m8 i64) (param $k i64) (param $v i64) (result i64)
    (local $m i32)
    (local $h i32) (local $s i32) (local $idx i32) (local $idxcap i32) (local $icm1 i32)
    (local $keys i32) (local $values i32) (local $len i32) (local $cap i32) (local $occ i32)
    (local $nk i32) (local $nv i32) (local $i i32) (local $newlen i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $h (i32.wrap_i64 (call $mere_map_key_hash_str (local.get $k))))
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $idxcap (i32.load offset=20 (local.get $m)))
    (local.set $icm1 (i32.sub (local.get $idxcap) (i32.const 1)))
    (local.set $s (i32.and (local.get $h) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $done_probe (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $done_probe (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_str
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then
          (i64.store (i32.add (local.get $values) (i32.mul (local.get $occ) (i32.const 8))) (local.get $v))
          (return (i64.const 0))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $nk (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $nk) (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $nv (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $nv) (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $i (i32.const 0))
        (block $cend (loop $cl
          (br_if $cend (i32.eq (local.get $i) (local.get $len)))
          (i64.store (i32.add (local.get $nk) (i32.mul (local.get $i) (i32.const 8)))
                     (i64.load (i32.add (local.get $keys) (i32.mul (local.get $i) (i32.const 8)))))
          (i64.store (i32.add (local.get $nv) (i32.mul (local.get $i) (i32.const 8)))
                     (i64.load (i32.add (local.get $values) (i32.mul (local.get $i) (i32.const 8)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cl)))
        (i32.store offset=0 (local.get $m) (local.get $nk))
        (i32.store offset=4 (local.get $m) (local.get $nv))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $nk))
        (local.set $values (local.get $nv))))
    (i64.store (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 8))) (local.get $k))
    (i64.store (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 8))) (local.get $v))
    (local.set $newlen (i32.add (local.get $len) (i32.const 1)))
    (i32.store offset=8 (local.get $m) (local.get $newlen))
    (if (i32.ge_s (i32.mul (local.get $newlen) (i32.const 10)) (i32.mul (local.get $idxcap) (i32.const 7)))
      (then (call $mere_map_str_reindex (local.get $m) (i32.mul (local.get $idxcap) (i32.const 2))))
      (else (i32.store (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))
                       (i32.sub (local.get $newlen) (i32.const 1)))))
    (i64.const 0))
  (func $mere_map_str_get (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $icm1 i32) (local $keys i32) (local $values i32) (local $occ i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $icm1 (i32.sub (i32.load offset=20 (local.get $m)) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_str (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $fail (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $fail (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_str
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then (return (i64.load (i32.add (local.get $values) (i32.mul (local.get $occ) (i32.const 8)))))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (unreachable))
  (func $mere_map_str_has (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $icm1 i32) (local $keys i32) (local $occ i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $icm1 (i32.sub (i32.load offset=20 (local.get $m)) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_str (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (block $notf (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $notf (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_str
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then (return (i64.const 1))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (i64.const 0))
  (func $mere_map_str_len (param $m8 i64) (result i64)
    (i64.extend_i32_s (i32.load offset=8 (i32.wrap_i64 (local.get $m8)))))
  (func $mere_map_str_iter (param $m8 i64) (param $cl8 i64) (result i64)
    (local $m i32) (local $cl i32)
    (local $i i32) (local $len i32)
    (local $keys i32) (local $values i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $k i64) (local $v i64) (local $inner_cl i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $len    (i32.load offset=8 (local.get $m)))
    (local.set $keys   (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $outer_env (i32.load offset=0 (local.get $cl)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $k (i64.load (i32.add (local.get $keys)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $v (i64.load (i32.add (local.get $values)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $inner_cl (i32.wrap_i64
          (call_indirect (type $cl) (i64.extend_i32_u (local.get $outer_env)) (local.get $k)
                         (local.get $outer_fn))))
        (drop (call_indirect (type $cl)
                (i64.extend_i32_u (i32.load offset=0 (local.get $inner_cl)))
                (local.get $v)
                (i32.load offset=4 (local.get $inner_cl))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.const 0))
  (func $mere_map_str_delete (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $idxcap i32) (local $icm1 i32)
    (local $keys i32) (local $values i32) (local $occ i32) (local $len i32) (local $j i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $idxcap (i32.load offset=20 (local.get $m)))
    (local.set $icm1 (i32.sub (local.get $idxcap) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_str (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $notf (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $notf (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_str
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then
          (local.set $len (i32.load offset=8 (local.get $m)))
          (local.set $j (local.get $occ))
          (block $sdone (loop $sl
            (br_if $sdone (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
            (i64.store (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 8)))
              (i64.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
            (i64.store (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 8)))
              (i64.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $sl)))
          (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
          (call $mere_map_str_reindex (local.get $m) (local.get $idxcap))
          (return (i64.const 0))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (i64.const 0))  (func $handler (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i64 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i64 i64 i64 i64 i64 i64 i64 i64 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i64 i64 i64 i64 i64 i64 i64 i32)
    local.get 0
    call $json_str_field
    local.set 2
    local.get 2
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 16
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 1
    local.get 0
    call $json_str_field
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 23
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    call $cf_registry_data
    local.set 5
    local.get 1
    i64.const 28
    call $__lang_streq
    i64.eqz
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 32
    return_call $resp_not_found
    else
    local.get 3
    i64.const 52
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 0
    return_call $resp_landing
    else
    local.get 3
    call $path_segments
    local.set 6
    local.get 6
    local.set 7
    local.get 7
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 8
    local.get 8
    if (result i32)
    local.get 7
    i32.wrap_i64
    i64.load offset=8
    local.set 9
    local.get 9
    i32.wrap_i64
    i64.load offset=0
    local.set 11
    local.get 11
    i64.const 54
    call $__lang_streq
    i32.wrap_i64
    local.set 12
    local.get 9
    i32.wrap_i64
    i64.load offset=8
    local.set 13
    local.get 13
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
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
    if (result i64)
    local.get 5
    return_call $resp_all_packages
    else
    local.get 7
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 18
    local.get 18
    if (result i32)
    local.get 7
    i32.wrap_i64
    i64.load offset=8
    local.set 19
    local.get 19
    i32.wrap_i64
    i64.load offset=0
    local.set 21
    local.get 21
    i64.const 58
    call $__lang_streq
    i32.wrap_i64
    local.set 22
    local.get 19
    i32.wrap_i64
    i64.load offset=8
    local.set 23
    local.get 23
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 24
    local.get 24
    if (result i32)
    local.get 23
    i32.wrap_i64
    i64.load offset=8
    local.set 25
    local.get 25
    i32.wrap_i64
    i64.load offset=0
    local.set 27
    i32.const 1
    local.set 28
    local.get 25
    i32.wrap_i64
    i64.load offset=8
    local.set 29
    local.get 29
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 30
    i32.const 1
    local.set 31
    local.get 31
    local.get 28
    i32.and
    local.set 32
    local.get 32
    local.get 30
    i32.and
    local.set 33
    local.get 33
    else
    i32.const 0
    end
    local.set 26
    i32.const 1
    local.set 34
    local.get 34
    local.get 22
    i32.and
    local.set 35
    local.get 35
    local.get 26
    i32.and
    local.set 36
    local.get 36
    else
    i32.const 0
    end
    local.set 20
    local.get 20
    if (result i64)
    local.get 5
    call $extract_object_at
    local.set 38
    local.get 38
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 27
    local.get 38
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 37
    local.get 37
    i64.const 62
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 63
    local.get 27
    call $__lang_str_concat
    i64.const 81
    call $__lang_str_concat
    return_call $resp_not_found
    else
    local.get 37
    return_call $resp_package
    end
    else
    local.get 7
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 39
    local.get 39
    if (result i32)
    local.get 7
    i32.wrap_i64
    i64.load offset=8
    local.set 40
    local.get 40
    i32.wrap_i64
    i64.load offset=0
    local.set 42
    local.get 42
    i64.const 83
    call $__lang_streq
    i32.wrap_i64
    local.set 43
    local.get 40
    i32.wrap_i64
    i64.load offset=8
    local.set 44
    local.get 44
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 45
    local.get 45
    if (result i32)
    local.get 44
    i32.wrap_i64
    i64.load offset=8
    local.set 46
    local.get 46
    i32.wrap_i64
    i64.load offset=0
    local.set 48
    i32.const 1
    local.set 49
    local.get 46
    i32.wrap_i64
    i64.load offset=8
    local.set 50
    local.get 50
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 51
    local.get 51
    if (result i32)
    local.get 50
    i32.wrap_i64
    i64.load offset=8
    local.set 52
    local.get 52
    i32.wrap_i64
    i64.load offset=0
    local.set 54
    local.get 54
    i64.const 87
    call $__lang_streq
    i32.wrap_i64
    local.set 55
    local.get 52
    i32.wrap_i64
    i64.load offset=8
    local.set 56
    local.get 56
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 57
    i32.const 1
    local.set 58
    local.get 58
    local.get 55
    i32.and
    local.set 59
    local.get 59
    local.get 57
    i32.and
    local.set 60
    local.get 60
    else
    i32.const 0
    end
    local.set 53
    i32.const 1
    local.set 61
    local.get 61
    local.get 49
    i32.and
    local.set 62
    local.get 62
    local.get 53
    i32.and
    local.set 63
    local.get 63
    else
    i32.const 0
    end
    local.set 47
    i32.const 1
    local.set 64
    local.get 64
    local.get 43
    i32.and
    local.set 65
    local.get 65
    local.get 47
    i32.and
    local.set 66
    local.get 66
    else
    i32.const 0
    end
    local.set 41
    local.get 41
    if (result i64)
    local.get 5
    call $extract_object_at
    local.set 68
    local.get 68
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 48
    local.get 68
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 67
    local.get 67
    i64.const 94
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 95
    local.get 48
    call $__lang_str_concat
    i64.const 113
    call $__lang_str_concat
    return_call $resp_not_found
    else
    local.get 67
    call $json_str_field
    local.set 70
    local.get 70
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 115
    local.get 70
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 69
    local.get 69
    i64.const 122
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 123
    return_call $resp_not_found
    else
    local.get 67
    call $extract_object_at
    local.set 72
    local.get 72
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 142
    local.get 72
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 71
    local.get 71
    call $extract_object_at
    local.set 74
    local.get 74
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 69
    local.get 74
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 73
    local.get 73
    i64.const 151
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 152
    return_call $resp_not_found
    else
    i64.const 178
    local.get 48
    call $__lang_str_concat
    i64.const 188
    call $__lang_str_concat
    local.get 69
    call $__lang_str_concat
    i64.const 202
    call $__lang_str_concat
    local.get 73
    i64.const 1
    local.get 73
    call $__lang_strlen
    call $__lang_substring
    call $__lang_str_concat
    local.set 75
    local.get 75
    return_call $resp_package
    end
    end
    end
    else
    local.get 7
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 76
    local.get 76
    if (result i32)
    local.get 7
    i32.wrap_i64
    i64.load offset=8
    local.set 77
    local.get 77
    i32.wrap_i64
    i64.load offset=0
    local.set 79
    local.get 79
    i64.const 205
    call $__lang_streq
    i32.wrap_i64
    local.set 80
    local.get 77
    i32.wrap_i64
    i64.load offset=8
    local.set 81
    local.get 81
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 82
    local.get 82
    if (result i32)
    local.get 81
    i32.wrap_i64
    i64.load offset=8
    local.set 83
    local.get 83
    i32.wrap_i64
    i64.load offset=0
    local.set 85
    i32.const 1
    local.set 86
    local.get 83
    i32.wrap_i64
    i64.load offset=8
    local.set 87
    local.get 87
    i32.wrap_i64
    i64.load offset=0
    i64.const 1
    i64.eq
    local.set 88
    local.get 88
    if (result i32)
    local.get 87
    i32.wrap_i64
    i64.load offset=8
    local.set 89
    local.get 89
    i32.wrap_i64
    i64.load offset=0
    local.set 91
    i32.const 1
    local.set 92
    local.get 89
    i32.wrap_i64
    i64.load offset=8
    local.set 93
    local.get 93
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 94
    i32.const 1
    local.set 95
    local.get 95
    local.get 92
    i32.and
    local.set 96
    local.get 96
    local.get 94
    i32.and
    local.set 97
    local.get 97
    else
    i32.const 0
    end
    local.set 90
    i32.const 1
    local.set 98
    local.get 98
    local.get 86
    i32.and
    local.set 99
    local.get 99
    local.get 90
    i32.and
    local.set 100
    local.get 100
    else
    i32.const 0
    end
    local.set 84
    i32.const 1
    local.set 101
    local.get 101
    local.get 80
    i32.and
    local.set 102
    local.get 102
    local.get 84
    i32.and
    local.set 103
    local.get 103
    else
    i32.const 0
    end
    local.set 78
    local.get 78
    if (result i64)
    local.get 5
    call $extract_object_at
    local.set 105
    local.get 105
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 85
    local.get 105
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 104
    local.get 104
    i64.const 209
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 210
    local.get 85
    call $__lang_str_concat
    i64.const 228
    call $__lang_str_concat
    return_call $resp_not_found
    else
    local.get 104
    call $extract_object_at
    local.set 107
    local.get 107
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    i64.const 230
    local.get 107
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 106
    local.get 106
    call $extract_object_at
    local.set 109
    local.get 109
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 91
    local.get 109
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 108
    local.get 108
    i64.const 239
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    i64.const 240
    local.get 85
    call $__lang_str_concat
    i64.const 258
    call $__lang_str_concat
    local.get 91
    call $__lang_str_concat
    i64.const 260
    call $__lang_str_concat
    return_call $resp_not_found
    else
    i64.const 262
    local.get 85
    call $__lang_str_concat
    i64.const 272
    call $__lang_str_concat
    local.get 91
    call $__lang_str_concat
    i64.const 286
    call $__lang_str_concat
    local.get 108
    i64.const 1
    local.get 108
    call $__lang_strlen
    call $__lang_substring
    call $__lang_str_concat
    local.set 110
    local.get 110
    return_call $resp_package
    end
    end
    else
    i32.const 1
    local.set 111
    local.get 111
    if (result i64)
    i64.const 289
    local.get 3
    call $__lang_str_concat
    i64.const 304
    call $__lang_str_concat
    return_call $resp_not_found
    else
    unreachable
    end
    end
    end
    end
    end
    end
    end)
  (func $path_segments (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i32)
    local.get 0
    call $__lang_strlen
    i64.const 0
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 0
    call $__lang_char_at
    i64.const 306
    call $__lang_streq
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    i64.const 0
    end
    local.set 1
    local.get 0
    call $_split_seg
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
    local.get 0
    call $__lang_strlen
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 3
    local.get 3
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 1
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 2
    local.get 2
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
    i64.const 0
    i64.store offset=0
    local.get 6
    i64.extend_i32_u
    local.get 2
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $_split_seg (param i64) (result i64)
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
    i32.const 29
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $resp_not_found (param i64) (result i64)
    i64.const 308
    i64.const 323
    call $__lang_str_concat
    i64.const 364
    call $__lang_str_concat
    local.get 0
    call $json_esc
    call $__lang_str_concat
    i64.const 373
    call $__lang_str_concat)
  (func $resp_package (param i64) (result i64)
    i64.const 376
    i64.const 391
    call $__lang_str_concat
    i64.const 438
    call $__lang_str_concat
    i64.const 455
    call $__lang_str_concat
    local.get 0
    call $__lang_str_concat
    i64.const 463
    call $__lang_str_concat)
  (func $resp_all_packages (param i64) (result i64)
    i64.const 465
    i64.const 480
    call $__lang_str_concat
    i64.const 527
    call $__lang_str_concat
    i64.const 544
    call $__lang_str_concat
    local.get 0
    call $__lang_str_concat
    i64.const 552
    call $__lang_str_concat)
  (func $resp_landing (param i64) (result i64)
    i64.const 554
    i64.const 569
    call $__lang_str_concat
    i64.const 624
    call $__lang_str_concat
    i64.const 633
    call $__lang_str_concat
    i64.const 685
    call $__lang_str_concat
    i64.const 723
    call $__lang_str_concat
    i64.const 761
    call $__lang_str_concat
    i64.const 766
    call $__lang_str_concat
    i64.const 823
    call $__lang_str_concat
    i64.const 885
    call $__lang_str_concat
    i64.const 951
    call $__lang_str_concat
    i64.const 1019
    call $__lang_str_concat
    i64.const 1025
    call $__lang_str_concat)
  (func $extract_object_at (param i64) (result i64)
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
    i32.const 30
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $json_esc (param i64) (result i64)
    (local i64 i64 i64 i64)
    call $mere_strbuf_new
    local.set 1
    local.get 0
    call $_json_esc_walk
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
    return_call_indirect (type $cl))
  (func $_json_esc_walk (param i64) (result i64)
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
    i32.const 31
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $json_str_field (param i64) (result i64)
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
    i32.const 32
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
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
    i32.const 33
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
    i32.const 34
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
    i32.const 35
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
    i64.const 1028
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
    i32.const 36
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
    i32.const 37
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
    i32.const 38
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
    i32.const 39
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
    i32.const 40
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
    i32.const 41
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
    i32.const 42
    i32.store offset=4
    local.get 4
    i64.extend_i32_u
    local.get 1
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $list_append (param i64) (result i64)
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
    i32.const 43
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
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
    i32.const 44
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
    i32.const 45
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
    i32.const 46
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $list_rev_into (param i64) (result i64)
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
    i32.const 47
    i32.store offset=4
    local.get 2
    i64.extend_i32_u)
  (func $__lifted___while___cx_0_0 (param i64) (param i64) (param i64) (param i64) (result i64)
    (local i64 i64)
    local.get 0
    i64.const 1029
    call $mere_map_str_get
    local.get 1
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1031
    call $mere_map_str_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    else
    i64.const 0
    end
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1035
    call $mere_map_str_get
    local.set 4
    local.get 2
    local.get 4
    call $__lang_char_at
    local.set 5
    local.get 5
    i64.const 1037
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1039
    local.get 0
    i64.const 1045
    call $mere_map_str_get
    i64.const 1
    i64.add
    call $mere_map_str_set
    else
    local.get 5
    i64.const 1051
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1053
    local.get 0
    i64.const 1059
    call $mere_map_str_get
    i64.const 1
    i64.sub
    call $mere_map_str_set
    drop
    local.get 0
    i64.const 1065
    call $mere_map_str_get
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 0
    i64.const 1071
    local.get 4
    i64.const 1
    i64.add
    call $mere_map_str_set
    else
    i64.const 0
    end
    else
    i64.const 0
    end
    end
    drop
    local.get 0
    i64.const 1075
    local.get 4
    i64.const 1
    i64.add
    call $mere_map_str_set
    drop
    local.get 0
    local.get 1
    local.get 2
    i64.const 0
    return_call $__lifted___while___cx_0_0
    else
    i64.const 0
    end)
  (func $handler_closure (param i64) (param i64) (result i64)
    local.get 1
    call $handler)
  (func $path_segments_closure (param i64) (param i64) (result i64)
    local.get 1
    call $path_segments)
  (func $_split_seg_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_split_seg)
  (func $resp_not_found_closure (param i64) (param i64) (result i64)
    local.get 1
    call $resp_not_found)
  (func $resp_package_closure (param i64) (param i64) (result i64)
    local.get 1
    call $resp_package)
  (func $resp_all_packages_closure (param i64) (param i64) (result i64)
    local.get 1
    call $resp_all_packages)
  (func $resp_landing_closure (param i64) (param i64) (result i64)
    local.get 1
    call $resp_landing)
  (func $extract_object_at_closure (param i64) (param i64) (result i64)
    local.get 1
    call $extract_object_at)
  (func $json_esc_closure (param i64) (param i64) (result i64)
    local.get 1
    call $json_esc)
  (func $_json_esc_walk_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_json_esc_walk)
  (func $json_str_field_closure (param i64) (param i64) (result i64)
    local.get 1
    call $json_str_field)
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
  (func $list_append_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_append)
  (func $range_closure (param i64) (param i64) (result i64)
    local.get 1
    call $range)
  (func $_range_down_closure (param i64) (param i64) (result i64)
    local.get 1
    call $_range_down)
  (func $list_fold_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_fold)
  (func $list_rev_into_closure (param i64) (param i64) (result i64)
    local.get 1
    call $list_rev_into)
  (func $anon_18_fn (param i64) (param i64) (result i64)
    (local i64 i64 i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 i32 i64 i32 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    local.set 3
    local.get 3
    i32.wrap_i64
    i64.load offset=0
    i64.const 0
    i64.eq
    local.set 4
    local.get 4
    if (result i64)
    local.get 2
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
    global.get $__lang_bump
    local.set 16
    local.get 16
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 16
    i64.const 1
    i64.store offset=0
    local.get 16
    global.get $__lang_bump
    local.set 17
    local.get 17
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 17
    local.get 8
    i64.store offset=0
    local.get 17
    local.get 2
    i64.store offset=8
    local.get 17
    i64.extend_i32_u
    i64.store offset=8
    local.get 16
    i64.extend_i32_u
    call $list_rev_into
    local.set 15
    local.get 15
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 10
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    unreachable
    end
    end)
  (func $anon_17_fn (param i64) (param i64) (result i64)
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
    i32.const 48
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_19_fn (param i64) (param i64) (result i64)
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
  (func $anon_16_fn (param i64) (param i64) (result i64)
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
    i32.const 49
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_20_fn (param i64) (param i64) (result i64)
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
  (func $anon_15_fn (param i64) (param i64) (result i64)
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
  (func $anon_14_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i32)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 1
    call $list_rev_into
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
    call $list_rev_into
    local.set 4
    local.get 4
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 3
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_13_fn (param i64) (param i64) (result i64)
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
    i32.const 50
    i32.store offset=4
    local.get 3
    i64.extend_i32_u)
  (func $anon_21_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i64.add)
  (func $anon_12_fn (param i64) (param i64) (result i64)
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
    i32.const 51
    i32.store offset=4
    local.get 3
    i64.extend_i32_u)
  (func $anon_22_fn (param i64) (param i64) (result i64)
    (local i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    local.get 2
    local.get 1
    i64.mul)
  (func $anon_11_fn (param i64) (param i64) (result i64)
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
    i64.const 1077
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
  (func $anon_10_fn (param i64) (param i64) (result i64)
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
    i32.const 52
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_23_fn (param i64) (param i64) (result i64)
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
    i32.const 53
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_24_fn (param i64) (param i64) (result i64)
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
    i32.const 54
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_25_fn (param i64) (param i64) (result i64)
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
    i64.const 1078
    local.get 4
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl))
  (func $anon_7_fn (param i64) (param i64) (result i64)
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
  (func $anon_6_fn (param i64) (param i64) (result i64)
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
    i32.const 55
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_26_fn (param i64) (param i64) (result i64)
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
    i32.const 56
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_27_fn (param i64) (param i64) (result i64)
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
  (func $anon_5_fn (param i64) (param i64) (result i64)
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
    i64.const 1079
    local.get 3
    call $__lang_str_repeat
    call $__lang_str_concat
    end)
  (func $anon_4_fn (param i64) (param i64) (result i64)
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
    i64.const 1081
    local.get 3
    call $__lang_str_repeat
    local.get 2
    call $__lang_str_concat
    end)
  (func $anon_3_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    i64.const 1083
    local.get 1
    call $__lang_str_concat
    i64.const 1085
    call $__lang_str_concat
    local.set 3
    local.get 2
    local.get 3
    call $__lang_str_index_of
    local.set 4
    local.get 4
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1089
    else
    local.get 2
    local.get 4
    local.get 3
    call $__lang_strlen
    i64.add
    local.get 2
    call $__lang_strlen
    call $__lang_substring
    local.set 5
    local.get 5
    i64.const 1090
    call $__lang_str_index_of
    local.set 6
    local.get 6
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1092
    else
    local.get 5
    i64.const 0
    local.get 6
    call $__lang_substring
    end
    end)
  (func $anon_2_fn (param i64) (param i64) (result i64)
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
    i32.const 57
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_28_fn (param i64) (param i64) (result i64)
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
    i32.const 58
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_29_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64)
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
    local.get 1
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 3
    call $mere_strbuf_to_str
    else
    local.get 4
    local.get 2
    call $__lang_char_at
    local.set 5
    local.get 5
    i64.const 1093
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1095
    call $mere_strbuf_push
    drop
    i64.const 0
    else
    local.get 5
    i64.const 1098
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1100
    call $mere_strbuf_push
    drop
    i64.const 0
    else
    local.get 5
    i64.const 1103
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1105
    call $mere_strbuf_push
    drop
    i64.const 0
    else
    local.get 5
    i64.const 1108
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1110
    call $mere_strbuf_push
    drop
    i64.const 0
    else
    local.get 5
    i64.const 1113
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 3
    i64.const 1115
    call $mere_strbuf_push
    drop
    i64.const 0
    else
    local.get 3
    local.get 5
    call $mere_strbuf_push
    drop
    i64.const 0
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
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
    local.get 8
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 7
    local.get 7
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 1
    i64.add
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
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    end)
  (func $anon_1_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i64 i64)
    local.get 0
    i32.wrap_i64
    i64.load offset=0
    local.set 2
    i64.const 1118
    local.get 1
    call $__lang_str_concat
    i64.const 1120
    call $__lang_str_concat
    local.set 3
    local.get 2
    local.get 3
    call $__lang_str_index_of
    local.set 4
    local.get 4
    i64.const 0
    i64.lt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1123
    else
    local.get 4
    local.get 3
    call $__lang_strlen
    i64.add
    local.set 5
    local.get 2
    call $__lang_strlen
    local.set 6
    local.get 5
    local.get 6
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1124
    else
    local.get 2
    local.get 5
    call $__lang_char_at
    i64.const 1125
    call $__lang_streq
    i64.eqz
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1127
    else
    call $mere_map_str_new
    local.set 7
    local.get 7
    i64.const 1128
    local.get 5
    call $mere_map_str_set
    drop
    local.get 7
    i64.const 1130
    i64.const 0
    call $mere_map_str_set
    drop
    local.get 7
    i64.const 1136
    i64.const 0
    call $mere_map_str_set
    drop
    local.get 7
    local.get 6
    local.get 2
    i64.const 0
    call $__lifted___while___cx_0_0
    drop
    local.get 7
    i64.const 1140
    call $mere_map_str_get
    local.set 8
    local.get 8
    i64.const 0
    i64.eq
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    i64.const 1144
    else
    local.get 2
    local.get 5
    local.get 8
    call $__lang_substring
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
    i32.const 59
    i32.store offset=4
    local.get 4
    i64.extend_i32_u)
  (func $anon_30_fn (param i64) (param i64) (result i64)
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
    i32.const 60
    i32.store offset=4
    local.get 5
    i64.extend_i32_u)
  (func $anon_31_fn (param i64) (param i64) (result i64)
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
    local.get 1
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
    i32.const 61
    i32.store offset=4
    local.get 6
    i64.extend_i32_u)
  (func $anon_32_fn (param i64) (param i64) (result i64)
    (local i64 i64 i64 i64 i64 i32 i32 i32 i64 i32 i32 i32 i32 i64 i64 i64 i64 i64 i64 i64 i64 i64)
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
    local.get 3
    i64.ge_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 2
    local.get 4
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    local.get 1
    call $list_append
    local.set 6
    local.get 6
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    global.get $__lang_bump
    local.set 7
    local.get 7
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 7
    i64.const 1
    i64.store offset=0
    local.get 7
    global.get $__lang_bump
    local.set 8
    local.get 8
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 8
    local.get 5
    local.get 4
    local.get 2
    call $__lang_substring
    i64.store offset=0
    local.get 8
    global.get $__lang_bump
    local.set 9
    local.get 9
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 9
    i64.const 0
    i64.store offset=0
    local.get 9
    i64.extend_i32_u
    i64.store offset=8
    local.get 8
    i64.extend_i32_u
    i64.store offset=8
    local.get 7
    i64.extend_i32_u
    local.get 6
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 1
    end
    else
    local.get 5
    local.get 2
    call $__lang_char_at
    i64.const 1145
    call $__lang_streq
    i32.wrap_i64
    if (result i64)
    local.get 2
    local.get 4
    i64.gt_s
    i64.extend_i32_u
    i32.wrap_i64
    if (result i64)
    global.get $__lang_bump
    local.set 11
    local.get 11
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 11
    i64.const 1
    i64.store offset=0
    local.get 11
    global.get $__lang_bump
    local.set 12
    local.get 12
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 12
    local.get 5
    local.get 4
    local.get 2
    call $__lang_substring
    i64.store offset=0
    local.get 12
    global.get $__lang_bump
    local.set 13
    local.get 13
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 13
    i64.const 0
    i64.store offset=0
    local.get 13
    i64.extend_i32_u
    i64.store offset=8
    local.get 12
    i64.extend_i32_u
    i64.store offset=8
    local.get 11
    i64.extend_i32_u
    else
    global.get $__lang_bump
    local.set 14
    local.get 14
    i32.const 16
    i32.add
    global.set $__lang_bump
    local.get 14
    i64.const 0
    i64.store offset=0
    local.get 14
    i64.extend_i32_u
    end
    local.set 10
    local.get 5
    call $_split_seg
    local.set 18
    local.get 18
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 1
    i64.add
    local.get 18
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
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
    local.get 2
    i64.const 1
    i64.add
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
    call $list_append
    local.set 19
    local.get 19
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 10
    local.get 19
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.get 15
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    else
    local.get 5
    call $_split_seg
    local.set 23
    local.get 23
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 2
    i64.const 1
    i64.add
    local.get 23
    i32.wrap_i64
    i32.load offset=4
    call_indirect (type $cl)
    local.set 22
    local.get 22
    i32.wrap_i64
    i32.load offset=0
    i64.extend_i32_u
    local.get 3
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
    local.get 20
    i32.wrap_i64
    i32.load offset=4
    return_call_indirect (type $cl)
    end
    end)
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
        (return (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))))))
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
    (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))))
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
    i64.extend_i32_u
    call $cf_on_fetch
    i64.const 0
    drop
    i64.const 0
    call $show_int
    call $puts
    i32.const 0)
)

