(* rv_libm.ml — the RISC-V prelude's libm: the functions a C program gets from
   libm and this target has no libm for. Appended to Rv_prelude.contents.

   Two kinds of name live here. `sin`, `cos`, `tan` and `atan2` are Mere
   builtins (every backend has them). The `__libm_*` functions are what an
   `extern fn` of the same libm name is bound to on RISC-V (codegen_riscv's
   `libm_bound`): a program that declares `extern fn cbrt: float -> float;` --
   mere-ruby declares twenty-one of these -- gets the C library's function
   natively and this one here, instead of a refusal.

   The standard is CORRECT ROUNDING, not any one libm's bits. Each function is
   computed in double-double (pairs whose sum carries ~106 bits; the pieces are
   rv_prelude's two_sum, two_prod and __dd_ helpers) and rounded once at the end.
   Measured against a 50-digit reference over thousands of points per function
   (v0.1.609): every one is within ~0.52 ulp of the true value, which is the
   correctly rounded answer except where the true value sits a hair from a
   rounding boundary. macOS's libm, measured the same way, is NOT correctly
   rounded for most of these (cbrt, the inverse and hyperbolic functions, tan,
   erf, erfc, tgamma, lgamma: 3% to 49% of points one ulp or more away), so on
   those points this prelude and a Mac disagree -- in this prelude's favour --
   and test/float/rv_libm_ext.mere holds it to the correctly rounded value
   rather than to the host's. fmod and ldexp are exact.

   Arguments past each function's working range are handled the way C's libm
   handles them (NaN in, NaN out; poles, overflow and underflow to the IEEE
   answer). sin / cos / tan reduce with the prelude's three-piece pi/2 below 2^20
   and by Payne-Hanek (2/pi to 1248 bits) above it: they degraded past
   about 1.6e6 before (sin 1e22 answered 7.9e91). *)

let contents = {mere|
// --- the RISC-V libm (lib/rv_libm.ml) ---------------------------------------

// --- trig: the three-piece reduction is rv_prelude's up to 2^20, Payne-Hanek
// past it (below); the kernels are pairs ----------------------------------
// sin(y0 + y1) for |y0| <= pi/4: y0 - y0^3/6 (a pair) + y0^5 S(y0^2), with the
// tail y1 carried to first order. Both series run to 1/23! (cos to 1/22!): the
// earlier ones stopped at 1/17! and 1/14!, and r^16/16! at pi/4 is 1.6e-15 --
// that was most of their "<= 10 ulp".
let __lm_sin_k = fn (y0: float) -> fn (y1: float) ->
  let (zh, zl) = __fp_two_prod y0 y0 in
  let (ch, cl) = __dd_mul_d zh zl y0 in
  let (th, tl) = __dd_mul ch cl 0.16666666666666666 9.25185853854297e-18 in
  let p = (0.0 - 3.868170170630684e-23) in
  let p = p * zh + 1.9572941063391263e-20 in
  let p = p * zh - 8.22063524662433e-18 in
  let p = p * zh + 2.8114572543455206e-15 in
  let p = p * zh - 7.647163731819816e-13 in
  let p = p * zh + 1.6059043836821613e-10 in
  let p = p * zh - 2.505210838544172e-08 in
  let p = p * zh + 2.7557319223985893e-06 in
  let p = p * zh - 0.0001984126984126984 in
  let p = p * zh + 0.008333333333333333 in
  let rest = (ch * zh) * p in
  let tail = y1 * (1.0 - zh * 0.5) in
  let (h, l) = __dd_add y0 tail (0.0 - th) (0.0 - tl) in
  __dd_add h l rest 0.0;
let __lm_cos_k = fn (y0: float) -> fn (y1: float) ->
  let (zh, zl) = __fp_two_prod y0 y0 in
  let (qh, ql) = __dd_mul zh zl zh zl in
  let (fh, fl) = __dd_mul qh ql 0.041666666666666664 2.3129646346357427e-18 in
  let p = (0.0 - 8.896791392450574e-22) in
  let p = p * zh + 4.110317623312165e-19 in
  let p = p * zh - 1.5619206968586225e-16 in
  let p = p * zh + 4.779477332387385e-14 in
  let p = p * zh - 1.1470745597729725e-11 in
  let p = p * zh + 2.08767569878681e-09 in
  let p = p * zh - 2.755731922398589e-07 in
  let p = p * zh + 2.48015873015873e-05 in
  let p = p * zh - 0.001388888888888889 in
  let rest = (qh * zh) * p in
  let (h, l) = __dd_add 1.0 0.0 (0.0 - zh * 0.5) (0.0 - zl * 0.5) in
  let (h2, l2) = __dd_add h l fh fl in
  __dd_add h2 l2 (rest - y1 * y0) 0.0;
let __lm_ipio2 = fn (j: int) ->
  if j < 1 then 0.0 else
  (if j <= 26 then (if j <= 13 then (if j <= 7 then (if j <= 4 then (if j <= 2 then (if j <= 1 then 10680707.0
   else 7228996.0)
   else (if j <= 3 then 1387004.0
   else 2578385.0))
   else (if j <= 6 then (if j <= 5 then 16069853.0
   else 12639074.0)
   else 9804092.0))
   else (if j <= 10 then (if j <= 9 then (if j <= 8 then 4427841.0
   else 16666979.0)
   else 11263675.0)
   else (if j <= 12 then (if j <= 11 then 12935607.0
   else 2387514.0)
   else 4345298.0)))
   else (if j <= 20 then (if j <= 17 then (if j <= 15 then (if j <= 14 then 14681673.0
   else 3074569.0)
   else (if j <= 16 then 13734428.0
   else 16653803.0))
   else (if j <= 19 then (if j <= 18 then 1880361.0
   else 10960616.0)
   else 8533493.0))
   else (if j <= 23 then (if j <= 22 then (if j <= 21 then 3062596.0
   else 8710556.0)
   else 7349940.0)
   else (if j <= 25 then (if j <= 24 then 6258241.0
   else 3772886.0)
   else 3769171.0))))
   else (if j <= 39 then (if j <= 33 then (if j <= 30 then (if j <= 28 then (if j <= 27 then 3798172.0
   else 8675211.0)
   else (if j <= 29 then 12450088.0
   else 3874808.0))
   else (if j <= 32 then (if j <= 31 then 9961438.0
   else 366607.0)
   else 15675153.0))
   else (if j <= 36 then (if j <= 35 then (if j <= 34 then 9132554.0
   else 7151469.0)
   else 3571407.0)
   else (if j <= 38 then (if j <= 37 then 2607881.0
   else 12013382.0)
   else 4155038.0)))
   else (if j <= 46 then (if j <= 43 then (if j <= 41 then (if j <= 40 then 6285869.0
   else 7677882.0)
   else (if j <= 42 then 13102053.0
   else 15825725.0))
   else (if j <= 45 then (if j <= 44 then 473591.0
   else 9065106.0)
   else 15363067.0))
   else (if j <= 49 then (if j <= 48 then (if j <= 47 then 6271263.0
   else 9264392.0)
   else 5636912.0)
   else (if j <= 51 then (if j <= 50 then 4652155.0
   else 7056368.0)
   else 13614112.0)))));
// Payne-Hanek, for |x| >= 2^20 where the three-piece pi/2 stops being exact:
// x = X 2^(e-52) with X a 53-bit integer split 5/24/24 bits, 2/pi = sum c_j
// 2^-24j (the table above), and x (2/pi) mod 8 is the sum over i + j = k of
// x_i c_j 2^(e - 4 - 24k) for the seven k whose terms are not multiples of 8.
// Each product is below 2^48 and each level's sum is exact; the first three
// levels drop their multiples of 8 exactly, and the rest are summed in a pair.
let rec __lm_ph_sum = fn (x0: float) -> fn (x1: float) -> fn (x2: float) -> fn (k0: int) ->
                       fn (sh: int) -> fn (m: int) -> fn (rh: float) -> fn (rl: float) ->
  if m > 6 then (rh, rl)
  else
    let k = k0 + m in
    let s = x0 * __lm_ipio2 k + x1 * __lm_ipio2 (k - 1) + x2 * __lm_ipio2 (k - 2) in
    let t0 = s * __fp_pow2i (sh - 24 * m) in
    let t = if m < 3 then t0 - 8.0 * __fp_trunc (t0 * 0.125) else t0 in
    let (h, l) = __dd_add rh rl t 0.0 in
    __lm_ph_sum x0 x1 x2 k0 sh (m + 1) h l;
let __lm_ph_reduce = fn (x: float) ->
  let a = f_abs x in
  let e = __lm_ilogb a in
  let xx = a * __fp_pow2i (52 - e) in
  let x0 = __fp_trunc (xx * __fp_pow2i (0 - 48)) in
  let r = xx - x0 * 281474976710656.0 in
  let x1 = __fp_trunc (r * __fp_pow2i (0 - 24)) in
  let x2 = r - x1 * 16777216.0 in
  let k0 = (e - 7) / 24 + 1 in
  let (rh, rl) = __lm_ph_sum x0 x1 x2 k0 (e - 4 - 24 * k0) 0 0.0 0.0 in
  let n0 = __fp_trunc rh in
  let (fh, fl) = __dd_fast (rh - n0) rl in
  let up = fh >= 0.5 in
  let (gh, gl) = if up then __dd_fast (fh - 1.0) fl else (fh, fl) in
  let n = if up then n0 + 1.0 else n0 in
  let (y0, y1) = __dd_mul gh gl 1.5707963267948966 6.123233995736766e-17 in
  let q = int_of_float (n - 4.0 * __fp_trunc (n * 0.25)) in
  if __lm_is_neg x then (0.0 - y0, 0.0 - y1, if q == 0 then 0 else 4 - q) else (y0, y1, q);
let __lm_reduce = fn (x: float) ->
  if f_abs x >= 1048576.0 then __lm_ph_reduce x else __fp_trig_reduce x;
let sin = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 0.0 / 0.0
  else if f_abs x < 7.450580596923828e-9 then x
  else
    let (y0, y1, q) = __lm_reduce x in
    if q == 0 then (let (h, l) = __lm_sin_k y0 y1 in h + l)
    else if q == 1 then (let (h, l) = __lm_cos_k y0 y1 in h + l)
    else if q == 2 then (let (h, l) = __lm_sin_k y0 y1 in f_neg (h + l))
    else (let (h, l) = __lm_cos_k y0 y1 in f_neg (h + l));
let cos = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 0.0 / 0.0
  else if f_abs x < 7.450580596923828e-9 then 1.0
  else
    let (y0, y1, q) = __lm_reduce x in
    if q == 0 then (let (h, l) = __lm_cos_k y0 y1 in h + l)
    else if q == 1 then (let (h, l) = __lm_sin_k y0 y1 in f_neg (h + l))
    else if q == 2 then (let (h, l) = __lm_cos_k y0 y1 in f_neg (h + l))
    else (let (h, l) = __lm_sin_k y0 y1 in h + l);
let tan = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 0.0 / 0.0
  else if f_abs x < 7.450580596923828e-9 then x
  else
    let (y0, y1, q) = __lm_reduce x in
    let (sh, sl) = __lm_sin_k y0 y1 in
    let (ch, cl) = __lm_cos_k y0 y1 in
    let (h, l) = (if q == 0 || q == 2 then __dd_div sh sl ch cl
                  else __dd_div (0.0 - ch) (0.0 - cl) sh sl) in
    h + l;

// --- atan and what is built on it -------------------------------------------
// atan(u) for a pair 0 <= u <= 1: u is moved next to c = i/4 (atan(c) is a
// stored pair) by atan(u) = atan(c) + atan((u - c)/(1 + u c)), leaving
// |t| <= 1/8, where t - t^3 (1/3 - t^2/5 + ...) through t^21 is exact enough.
let __lm_atan_c_hi = fn (i: int) ->
  if i == 1 then 0.24497866312686414 else if i == 2 then 0.4636476090008061
  else if i == 3 then 0.6435011087932844 else if i == 4 then 0.7853981633974483 else 0.0;
let __lm_atan_c_lo = fn (i: int) ->
  if i == 1 then 1.0698755618734451e-17 else if i == 2 then 2.2698777452961687e-17
  else if i == 3 then 1.5834785051444286e-17 else if i == 4 then 3.061616997868383e-17 else 0.0;
let __lm_atan_core = fn (uh: float) -> fn (ul: float) ->
  let i = int_of_float (round (uh * 4.0)) in
  let c = float_of_int i * 0.25 in
  let (th, tl) =
    (if i == 0 then (uh, ul)
     else
       let (nh, nl) = __dd_add uh ul (0.0 - c) 0.0 in
       let (mh, ml) = __dd_mul_d uh ul c in
       let (dh, dl) = __dd_add 1.0 0.0 mh ml in
       __dd_div nh nl dh dl) in
  let z = th * th in
  let q = 0.047619047619047616 in
  let q = 0.05263157894736842 - z * q in
  let q = 0.058823529411764705 - z * q in
  let q = 0.06666666666666667 - z * q in
  let q = 0.07692307692307693 - z * q in
  let q = 0.09090909090909091 - z * q in
  let q = 0.1111111111111111 - z * q in
  let q = 0.14285714285714285 - z * q in
  let q = 0.2 - z * q in
  let q = 0.3333333333333333 - z * q in
  let s = th * z * q in
  let (ah, al) = __dd_add th tl (0.0 - s) 0.0 in
  __dd_add (__lm_atan_c_hi i) (__lm_atan_c_lo i) ah al;
// atan of a pair u >= 0
let __lm_atan_dd = fn (uh: float) -> fn (ul: float) ->
  if uh > 1.0 then
    (let (rh, rl) = __dd_div 1.0 0.0 uh ul in
     let (ah, al) = __lm_atan_core rh rl in
     __dd_add 1.5707963267948966 6.123233995736766e-17 (0.0 - ah) (0.0 - al))
  else __lm_atan_core uh ul;
let __lm_neg_if = fn (neg: bool) -> fn (v: float) -> if neg then f_neg v else v;
let __lm_is_neg = fn (x: float) -> __fp_hi_sign (float_bits_hi x) == 1;
let __libm_atan = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then __lm_neg_if (__lm_is_neg x) 1.5707963267948966
  else
    let a = f_abs x in
    if a < 7.450580596923828e-9 then x
    else if a > 1.152921504606847e18 then __lm_neg_if (__lm_is_neg x) 1.5707963267948966
    else (let (h, l) = __lm_atan_dd a 0.0 in __lm_neg_if (__lm_is_neg x) (h + l));
// (1 - a)(1 + a) as a pair, both factors exact by two_sum
let __lm_one_minus_sq = fn (a: float) ->
  let (ph, pl) = __fp_two_sum 1.0 (0.0 - a) in
  let (qh, ql) = __fp_two_sum 1.0 a in
  __dd_mul ph pl qh ql;
let __libm_asin = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if a > 1.0 then 0.0 / 0.0
    else if a == 1.0 then __lm_neg_if (__lm_is_neg x) 1.5707963267948966
    else if a < 7.450580596923828e-9 then x
    else
      let (wh, wl) = __lm_one_minus_sq a in
      let (sh, sl) = __dd_sqrt wh wl in
      let (rh, rl) = __dd_div a 0.0 sh sl in
      let (h, l) = __lm_atan_dd rh rl in
      __lm_neg_if (__lm_is_neg x) (h + l);
let __libm_acos = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if a > 1.0 then 0.0 / 0.0
    else if x == 1.0 then 0.0
    else if x == 0.0 - 1.0 then 3.141592653589793
    else if a < 5.551115123125783e-17 then 1.5707963267948966
    else
      let (wh, wl) = __lm_one_minus_sq a in
      let (sh, sl) = __dd_sqrt wh wl in
      let (rh, rl) = __dd_div sh sl a 0.0 in
      let (th, tl) = __lm_atan_dd rh rl in
      if x > 0.0 then th + tl
      else (let (h, l) = __dd_add 3.141592653589793 1.2246467991473532e-16 (0.0 - th) (0.0 - tl) in h + l);
let atan2 = fn (y: float) -> fn (x: float) ->
  let pi = 3.141592653589793 in
  if y != y then y else if x != x then x
  else
    let yneg = __lm_is_neg y in
    let xneg = __lm_is_neg x in
    if y == 0.0 then
      (if not xneg then (if yneg then 0.0 - 0.0 else 0.0)
       else (if yneg then 0.0 - pi else pi))
    else if x == 0.0 then __lm_neg_if yneg 1.5707963267948966
    else if __fp_is_inf y && __fp_is_inf x then
      __lm_neg_if yneg (if not xneg then 0.7853981633974483 else 2.356194490192345)
    else if __fp_is_inf y then __lm_neg_if yneg 1.5707963267948966
    else if __fp_is_inf x then
      (if not xneg then (if yneg then 0.0 - 0.0 else 0.0)
       else (if yneg then 0.0 - pi else pi))
    else
      let a0 = f_abs y in
      let b0 = f_abs x in
      // the angle is a/b to the bit (b > a 2^60), or pi/2 to the bit (a > b 2^60)
      if b0 > a0 * 1.152921504606847e18 then
        (if not xneg then __lm_neg_if yneg (a0 / b0) else __lm_neg_if yneg pi)
      else
        let (th, tl) =
          (if a0 > b0 * 1.152921504606847e18 then (1.5707963267948966, 6.123233995736766e-17)
           else
             // the pair's split multiplies by 2^27: keep both well inside range
             let big = a0 > 8.452712498170644e270 || b0 > 8.452712498170644e270 in
             let small = a0 < 1.1830521861667747e-271 || b0 < 1.1830521861667747e-271 in
             let a = if big then a0 * 2.4099198651028841e-181 else if small then a0 * 4.149515568880993e180 else a0 in
             let b = if big then b0 * 2.4099198651028841e-181 else if small then b0 * 4.149515568880993e180 else b0 in
             let (rh, rl) = __dd_div a 0.0 b 0.0 in
             __lm_atan_dd rh rl) in
        if not xneg then __lm_neg_if yneg (th + tl)
        else (let (h, l) = __dd_add 3.141592653589793 1.2246467991473532e-16 (0.0 - th) (0.0 - tl) in
              __lm_neg_if yneg (h + l));

// --- logarithms -------------------------------------------------------------
let __lm_log_special = fn (x: float) -> x != x || x <= 0.0 || __fp_is_inf x;
let __lm_log_special_v = fn (x: float) ->
  if x != x then x else if x < 0.0 then 0.0 / 0.0 else if x == 0.0 then 0.0 - 1.0 / 0.0 else x;
let __libm_log2 = fn (x: float) ->
  if __lm_log_special x then __lm_log_special_v x
  else
    let (h, t) = __fp_log2p x in
    let (rh, rl) = __dd_mul h t 1.4426950408889634 2.0355273740931033e-17 in
    rh + rl;
let __libm_log10 = fn (x: float) ->
  if __lm_log_special x then __lm_log_special_v x
  else
    let (h, t) = __fp_log2p x in
    let (rh, rl) = __dd_mul h t 0.4342944819032518 1.098319650216765e-17 in
    rh + rl;
// log(xh + xl) as a pair, and log1p of a pair
let __dd_log = fn (xh: float) -> fn (xl: float) ->
  let (h, t) = __fp_log2p xh in
  __dd_add h t (xl / xh) 0.0;
let __dd_log1p = fn (th: float) -> fn (tl: float) ->
  let (uh, ue) = __fp_two_sum 1.0 th in
  __dd_log uh (ue + tl);
let __libm_log1p = fn (x: float) ->
  if x != x then x
  else if x == 0.0 - 1.0 then 0.0 - 1.0 / 0.0
  else if x < 0.0 - 1.0 then 0.0 / 0.0
  else if __fp_is_inf x then x
  else if f_abs x < 5.551115123125783e-17 then x
  else (let (h, l) = __dd_log1p x 0.0 in h + l);

// --- e^x - 1 and the hyperbolics -------------------------------------------
// expm1 as a pair: below ln2/2 straight from the series (relative accuracy all
// the way down), above it e^x - 1 in pairs
let __lm_expm1_dd = fn (x: float) ->
  if f_abs x < 0.34657359027997264 then
    (
  let p = 7.647163731819816e-13 in
  let p = p * x + 1.1470745597729725e-11 in
  let p = p * x + 1.6059043836821613e-10 in
  let p = p * x + 2.08767569878681e-09 in
  let p = p * x + 2.505210838544172e-08 in
  let p = p * x + 2.755731922398589e-07 in
  let p = p * x + 2.7557319223985893e-06 in
  let p = p * x + 2.48015873015873e-05 in
  let p = p * x + 0.0001984126984126984 in
  let p = p * x + 0.001388888888888889 in
  let p = p * x + 0.008333333333333333 in
  let p = p * x + 0.041666666666666664 in
  let p = p * x + 0.16666666666666666 in
     let (sh, sl) = __fp_two_prod x x in
     let c3 = (sh * x) * p in
     let (a, ea) = __fp_two_sum x (sh * 0.5) in
     __dd_fast a ((ea + sl * 0.5) + c3))
  else
    (let (eh, el) = __dd_exp x 0.0 in __dd_add eh el (0.0 - 1.0) 0.0);
let __libm_expm1 = fn (x: float) ->
  if x != x then x
  else if x > 709.782712893384 then 1.0 / 0.0
  else if x < 0.0 - 38.0 then 0.0 - 1.0
  else if f_abs x < 5.551115123125783e-17 then x
  else (let (h, l) = __lm_expm1_dd x in h + l);
// e^a / 2 for a past 22, where e^-a is below the last bit; past e^709.78 it is
// e^(a - ln 2), which still fits
let __lm_half_exp = fn (a: float) ->
  if a <= 709.782712893384 then (let (h, l) = __dd_exp a 0.0 in (h + l) * 0.5)
  else if a <= 710.4758600739439 then __fp_exp2 (a - 0.6931471803691238) (0.0 - 1.9082149292705877e-10)
  else 1.0 / 0.0;
let __libm_sinh = fn (x: float) ->
  if x != x || __fp_is_inf x then x
  else
    let a = f_abs x in
    if a < 7.450580596923828e-9 then x
    else if a <= 22.0 then
      (let (eh, el) = __lm_expm1_dd a in
       let (dh, dl) = __dd_add eh el 1.0 0.0 in
       let (fh, fl) = __dd_div eh el dh dl in
       let (h, l) = __dd_add eh el fh fl in
       __lm_neg_if (__lm_is_neg x) ((h + l) * 0.5))
    else __lm_neg_if (__lm_is_neg x) (__lm_half_exp a);
let __libm_cosh = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if __fp_is_inf a then a
    else if a < 7.450580596923828e-9 then 1.0
    else if a <= 22.0 then
      (let (eh, el) = __lm_expm1_dd a in
       let (e1h, e1l) = __dd_add eh el 1.0 0.0 in
       let (ih, il) = __dd_div 1.0 0.0 e1h e1l in
       let (h, l) = __dd_add e1h e1l ih il in
       (h + l) * 0.5)
    else __lm_half_exp a;
let __libm_tanh = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if a < 7.450580596923828e-9 then x
    else if a > 22.0 then __lm_neg_if (__lm_is_neg x) 1.0
    else
      let (eh, el) = __lm_expm1_dd (2.0 * a) in
      let (dh, dl) = __dd_add eh el 2.0 0.0 in
      let (h, l) = __dd_div eh el dh dl in
      __lm_neg_if (__lm_is_neg x) (h + l);
let __lm_log_plus_ln2 = fn (a: float) ->
  let (h, t) = __fp_log2p a in
  let (rh, rl) = __dd_add h t 0.6931471805599453 2.3190468138462996e-17 in
  rh + rl;
let __libm_asinh = fn (x: float) ->
  if x != x || __fp_is_inf x then x
  else
    let a = f_abs x in
    if a < 7.450580596923828e-9 then x
    else if a > 268435456.0 then __lm_neg_if (__lm_is_neg x) (__lm_log_plus_ln2 a)
    else
      // log1p(a + a^2 / (1 + sqrt(1 + a^2))), all in pairs
      let (qh, ql) = __fp_two_prod a a in
      let (wh, wl) = __dd_add qh ql 1.0 0.0 in
      let (sh, sl) = __dd_sqrt wh wl in
      let (dh, dl) = __dd_add sh sl 1.0 0.0 in
      let (fh, fl) = __dd_div qh ql dh dl in
      let (th, tl) = __dd_add a 0.0 fh fl in
      let (h, l) = __dd_log1p th tl in
      __lm_neg_if (__lm_is_neg x) (h + l);
let __libm_acosh = fn (x: float) ->
  if x != x then x
  else if x < 1.0 then 0.0 / 0.0
  else if x == 1.0 then 0.0
  else if __fp_is_inf x then x
  else if x > 268435456.0 then __lm_log_plus_ln2 x
  else
    // log1p((x - 1) + sqrt((x - 1)(x + 1)))
    let (mh, ml) = __fp_two_sum x (0.0 - 1.0) in
    let (ph, pl) = __fp_two_sum x 1.0 in
    let (wh, wl) = __dd_mul mh ml ph pl in
    let (sh, sl) = __dd_sqrt wh wl in
    let (th, tl) = __dd_add mh ml sh sl in
    let (h, l) = __dd_log1p th tl in
    h + l;
let __libm_atanh = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if a > 1.0 then 0.0 / 0.0
    else if a == 1.0 then __lm_neg_if (__lm_is_neg x) (1.0 / 0.0)
    else if a < 7.450580596923828e-9 then x
    else
      // log1p(2a / (1 - a)) / 2
      let (dh, dl) = __fp_two_sum 1.0 (0.0 - a) in
      let (qh, ql) = __dd_div (2.0 * a) 0.0 dh dl in
      let (h, l) = __dd_log1p qh ql in
      __lm_neg_if (__lm_is_neg x) ((h + l) * 0.5);

// --- cbrt / hypot / fmod / ldexp --------------------------------------------
let __libm_cbrt = fn (x: float) ->
  if x != x || x == 0.0 || __fp_is_inf x then x
  else
    let a0 = f_abs x in
    // scaled by 2^+-999 (a cube) far from 1, so y^3 stays splittable
    let a = if a0 < 1.1830521861667747e-271 then a0 * 5.357543035931337e300
            else if a0 > 8.452712498170644e270 then a0 * 1.8665272370064378e-301 else a0 in
    let sc = if a0 < 1.1830521861667747e-271 then 0 - 333
             else if a0 > 8.452712498170644e270 then 333 else 0 in
    // e^(log a / 3), then one Newton step with y^3 - a in pairs
    let (lh, lt) = __fp_log2p a in
    let y0 = __fp_exp2 (lh / 3.0) (lt / 3.0) in
    let (y2h, y2l) = __fp_two_prod y0 y0 in
    let (y3h, y3l) = __dd_mul_d y2h y2l y0 in
    let (rh, rl) = __dd_add y3h y3l (0.0 - a) 0.0 in
    let y = y0 - (rh + rl) / (3.0 * y2h) in
    let y2 = if sc == 0 then y else y * __fp_pow2i sc in
    __lm_neg_if (__lm_is_neg x) y2;
let __libm_hypot = fn (x: float) -> fn (y: float) ->
  let a0 = f_abs x in
  let b0 = f_abs y in
  if __fp_is_inf a0 || __fp_is_inf b0 then 1.0 / 0.0
  else if a0 != a0 || b0 != b0 then 0.0 / 0.0
  else
    let a1 = if a0 < b0 then b0 else a0 in
    let b1 = if a0 < b0 then a0 else b0 in
    if b1 == 0.0 then a1
    else if b1 < a1 * 8.673617379884035e-19 then a1
    else
      let sc = if a1 > 3.273390607896142e150 then 600
               else if b1 < 3.054936363499605e-151 then 0 - 600 else 0 in
      let a = if sc == 0 then a1 else a1 * __fp_pow2i (0 - sc) in
      let b = if sc == 0 then b1 else b1 * __fp_pow2i (0 - sc) in
      let (ah, al) = __fp_two_prod a a in
      let (bh, bl) = __fp_two_prod b b in
      let (sh, sl) = __dd_add ah al bh bl in
      let (rh, rl) = __dd_sqrt sh sl in
      if sc == 0 then rh + rl else (rh + rl) * __fp_pow2i sc;
// the unbiased exponent of a finite non-zero x
let __lm_ilogb = fn (x: float) ->
  let e = __fp_hi_exp (float_bits_hi x) in
  if e == 0 then __fp_hi_exp (float_bits_hi (x * 18014398509481984.0)) - 1023 - 54
  else e - 1023;
// x * 2^n, rounded once: the significand is put at exponent 0 and multiplied
// by one power of two (two, for a subnormal answer, the first exact)
let __libm_ldexp = fn (x: float) -> fn (n0: int) ->
  if x != x || x == 0.0 || __fp_is_inf x then x
  else
    let n = if n0 > 2200 then 2200 else if n0 < 0 - 2200 then 0 - 2200 else n0 in
    let sub = __fp_hi_exp (float_bits_hi x) == 0 in
    let x1 = if sub then x * 18014398509481984.0 else x in
    let n1 = if sub then n - 54 else n in
    let hi = float_bits_hi x1 in
    let e = __fp_hi_exp hi - 1023 + n1 in
    let m = float_of_bits (bit_or (bit_shl (__fp_hi_sign hi) 31)
                                  (bit_or (bit_shl 1023 20) (bit_and hi 1048575)))
                          (float_bits_lo x1) in
    if e > 1023 then __lm_neg_if (__lm_is_neg x) (1.0 / 0.0)
    else if e >= 0 - 1022 then m * float_of_bits (bit_shl (e + 1023) 20) 0
    else if e < 0 - 1075 then __lm_neg_if (__lm_is_neg x) 0.0
    else (m * float_of_bits (bit_shl 1 20) 0) * float_of_bits (bit_shl (e + 2045) 20) 0;
// fmod is exact: every step subtracts b 2^k with r/2 < b 2^k <= r (Sterbenz)
let rec __lm_fmod_go = fn (r: float) -> fn (b: float) -> fn (eb: int) ->
  if r < b then r
  else
    let k = __lm_ilogb r - eb in
    let t0 = __libm_ldexp b k in
    let t = if t0 > r then __libm_ldexp b (k - 1) else t0 in
    __lm_fmod_go (r - t) b eb;
let __libm_fmod = fn (x: float) -> fn (y: float) ->
  if x != x || y != y || __fp_is_inf x || y == 0.0 then 0.0 / 0.0
  else if __fp_is_inf y then x
  else
    let a = f_abs x in
    let b = f_abs y in
    if a < b then x
    else __lm_neg_if (__lm_is_neg x) (__lm_fmod_go a b (__lm_ilogb b));

// --- erf / erfc ---------------------------------------------------------------
// erf for 0 < x < 2: (2/sqrt pi) e^(-x^2) sum (2x^2)^n x / (2n+1)!!, whose terms
// are all positive -- no cancellation, unlike the alternating Taylor series
let rec __lm_erf_go = fn (th: float) -> fn (tl: float) -> fn (sh: float) -> fn (sl: float) ->
                       fn (qh: float) -> fn (ql: float) -> fn (n: int) ->
  let (th1, tl1) = __dd_mul th tl (2.0 * qh) (2.0 * ql) in
  let (th2, tl2) = __dd_div th1 tl1 (2.0 * float_of_int n + 1.0) 0.0 in
  let (sh2, sl2) = __dd_add sh sl th2 tl2 in
  if f_abs th2 < f_abs sh2 * 1.0e-34 then (sh2, sl2)
  else __lm_erf_go th2 tl2 sh2 sl2 qh ql (n + 1);
let __lm_erf_series = fn (x: float) ->
  let (qh, ql) = __fp_two_prod x x in
  let (sh, sl) = __lm_erf_go x 0.0 x 0.0 qh ql 1 in
  let (eh, el) = __dd_exp (0.0 - qh) (0.0 - ql) in
  let (ph, pl) = __dd_mul sh sl eh el in
  __dd_mul ph pl 1.1283791670955126 1.533545961316588e-17;
// erfc for x >= 2: e^(-x^2) / sqrt pi / (x + (1/2)/(x + 1/(x + (3/2)/...))),
// 120 levels folded from the bottom (3e-25 relative at x = 2). The answer is
// (h, l) * 2^k, k left apart so an underflowing erfc rounds once.
let rec __lm_erfc_cf = fn (x: float) -> fn (fh: float) -> fn (fl: float) -> fn (n: int) ->
  if n < 1 then (fh, fl)
  else
    let (dh, dl) = __dd_div (float_of_int n * 0.5) 0.0 fh fl in
    let (gh, gl) = __dd_add x 0.0 dh dl in
    __lm_erfc_cf x gh gl (n - 1);
let __lm_erfc_big = fn (x: float) ->
  let (fh, fl) = __lm_erfc_cf x x 0.0 120 in
  let (qh, ql) = __fp_two_prod x x in
  let (b, lo, k) = __fp_exp_core (0.0 - qh) (0.0 - ql) in
  let (eh, el) = __dd_fast b lo in
  let (rh, rl) = __dd_div eh el fh fl in
  let (sh, sl) = __dd_mul rh rl 0.5641895835477563 7.66772980658294e-18 in
  (sh, sl, k);
let __libm_erf = fn (x: float) ->
  if x != x then x
  else
    let a = f_abs x in
    if __fp_is_inf a then __lm_neg_if (__lm_is_neg x) 1.0
    else if a < 7.450580596923828e-9 then
      (if a > 1.0e-300 then (let (h, l) = __dd_mul_d 1.1283791670955126 1.533545961316588e-17 x in h + l)
       else x * 1.1283791670955126)
    else if a >= 6.0 then __lm_neg_if (__lm_is_neg x) 1.0
    else if a < 2.0 then (let (h, l) = __lm_erf_series a in __lm_neg_if (__lm_is_neg x) (h + l))
    else
      (let (ch, cl, k) = __lm_erfc_big a in
       let s = __fp_pow2i k in
       let (h, l) = __dd_add 1.0 0.0 (0.0 - ch * s) (0.0 - cl * s) in
       __lm_neg_if (__lm_is_neg x) (h + l));
let __libm_erfc = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then (if __lm_is_neg x then 2.0 else 0.0)
  else
    let a = f_abs x in
    if a < 2.0 then
      (if a < 5.551115123125783e-17 then 1.0 - x
       else
         let (h, l) = __lm_erf_series a in
         let (rh, rl) = (if __lm_is_neg x then __dd_add 1.0 0.0 h l
                         else __dd_add 1.0 0.0 (0.0 - h) (0.0 - l)) in
         rh + rl)
    else if __lm_is_neg x then
      (if a >= 6.0 then 2.0
       else
         let (ch, cl, k) = __lm_erfc_big a in
         let s = __fp_pow2i k in
         let (h, l) = __dd_add 2.0 0.0 (0.0 - ch * s) (0.0 - cl * s) in
         h + l)
    else if a > 27.3 then 0.0
    else (let (ch, cl, k) = __lm_erfc_big a in __fp_scale (ch + cl) k);

// --- gamma / lgamma -----------------------------------------------------------
// ln Gamma(y) for a pair y >= 12: Stirling, (y - 1/2) ln y - y + ln sqrt(2 pi)
// + 1/(12 y) (a pair) + the rest of the series in 1/y through B_22
let __lm_lgamma_big = fn (yh: float) -> fn (yl: float) ->
  let (lh, ll) = __dd_log yh yl in
  let (ah, al) = __dd_add yh yl (0.0 - 0.5) 0.0 in
  let (p1h, p1l) = __dd_mul ah al lh ll in
  let (p2h, p2l) = __dd_add p1h p1l (0.0 - yh) (0.0 - yl) in
  let (p3h, p3l) = __dd_add p2h p2l 0.9189385332046728 (0.0 - 3.8782941580672414e-17) in
  let iy = 1.0 / yh in
  let z = iy * iy in
  let s = 13.402864044168393 in
  let s = s * z - 1.3924322169059011 in
  let s = s * z + 0.17964437236883057 in
  let s = s * z - 0.029550653594771242 in
  let s = s * z + 0.00641025641025641 in
  let s = s * z - 0.0019175269175269176 in
  let s = s * z + 0.0008417508417508417 in
  let s = s * z - 0.0005952380952380953 in
  let s = s * z + 0.0007936507936507937 in
  let s = s * z - 0.002777777777777778 in
  let s2 = s * z * iy in
  let (ih, il) = __dd_div 1.0 0.0 yh yl in
  let (th, tl) = __dd_mul ih il 0.08333333333333333 4.625929269271485e-18 in
  let (p4h, p4l) = __dd_add p3h p3l th tl in
  __dd_add p4h p4l s2 0.0;
// y = x + n >= 12 and prod = x (x+1) ... (x+n-1), as pairs
let rec __lm_shift_up = fn (yh: float) -> fn (yl: float) -> fn (ph: float) -> fn (pl: float) ->
  if yh >= 12.0 then (yh, yl, ph, pl)
  else
    let (ph2, pl2) = __dd_mul ph pl yh yl in
    let (yh2, yl2) = __dd_add yh yl 1.0 0.0 in
    __lm_shift_up yh2 yl2 ph2 pl2;
// Gamma of a pair 0 < y <= 171.6
let __lm_gamma_pos = fn (xh: float) -> fn (xl: float) ->
  let (yh, yl, ph, pl) = __lm_shift_up xh xl 1.0 0.0 in
  let (gh, gl) = __lm_lgamma_big yh yl in
  let (eh, el) = __dd_exp gh gl in
  // (nothing shifted: and a pair near 1e308 could not be split to divide)
  if ph == 1.0 && pl == 0.0 then (eh, el) else __dd_div eh el ph pl;
// sin(pi x) as a pair: x - round(x) is exact, and a quarter turn away from 0
// it is cos(pi (1/2 - |r|)) instead
let __lm_sinpi = fn (x: float) ->
  let n = round x in
  let r = x - n in
  let odd = __fp_is_odd_int_f n in
  let a = f_abs r in
  let (h, l) =
    (if a <= 0.25 then (let (th, tl) = __dd_mul_d 3.141592653589793 1.2246467991473532e-16 a in __lm_sin_k th tl)
     else (let (th, tl) = __dd_mul_d 3.141592653589793 1.2246467991473532e-16 (0.5 - a) in __lm_cos_k th tl)) in
  if (r < 0.0) != odd then (0.0 - h, 0.0 - l) else (h, l);
let __libm_tgamma = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then (if __lm_is_neg x then 0.0 / 0.0 else x)
  else if x == 0.0 then __lm_neg_if (__lm_is_neg x) (1.0 / 0.0)
  else if x < 0.0 && __fp_is_int_f x then 0.0 / 0.0
  else if x > 171.62437695630271 then 1.0 / 0.0
  // 1/x - euler, and the pair could not be split this far out
  else if f_abs x < 1.1830521861667747e-271 then 1.0 / x
  else if x > 0.0 then (let (h, l) = __lm_gamma_pos x 0.0 in h + l)
  else if x < 0.0 - 184.0 then (if __fp_is_odd_int_f (__fp_trunc x) then 0.0 else 0.0 - 0.0)
  else
    // pi / (sin(pi x) Gamma(1 - x)); past Gamma's range, the same in logs
    let (sh, sl) = __lm_sinpi x in
    let (oh, ol) = __fp_two_sum 1.0 (0.0 - x) in
    if oh > 171.0 then
      (let (gh, gl) = __lm_lgamma_big oh ol in
       let (ash, asl) = (if sh < 0.0 then (0.0 - sh, 0.0 - sl) else (sh, sl)) in
       let (lsh, lsl) = __dd_log ash asl in
       let (z1h, z1l) = __dd_add 1.1447298858494002 1.0265951162707826e-17 (0.0 - lsh) (0.0 - lsl) in
       let (z2h, z2l) = __dd_add z1h z1l (0.0 - gh) (0.0 - gl) in
       let (b, lo, k) = __fp_exp_core z2h z2l in
       let r = __fp_scale (b + lo) k in
       if sh < 0.0 then f_neg r else r)
    else
      (let (gh, gl) = __lm_gamma_pos oh ol in
       let (dh, dl) = __dd_mul sh sl gh gl in
       let (h, l) = __dd_div 3.141592653589793 1.2246467991473532e-16 dh dl in
       h + l);
// ln Gamma(1 + t) for |t| < 0.1: -euler t + sum_{k>=2} (-1)^k zeta(k)/k t^k,
// t and t^2 terms in pairs, the rest in double from t^3 (through t^21)
let __lm_lgamma1p = fn (t: float) ->
  let p = 0.0 in
  let p = p * t - 0.047619070330142226 in
  let p = p * t + 0.05000004769810169 in
  let p = p * t - 0.05263167937961666 in
  let p = p * t + 0.055555767627403614 in
  let p = p * t - 0.058823978658684585 in
  let p = p * t + 0.06250095514121304 in
  let p = p * t - 0.06666870588242046 in
  let p = p * t + 0.07143294629536133 in
  let p = p * t - 0.0769325164113522 in
  let p = p * t + 0.083353840546109 in
  let p = p * t - 0.09095401714582904 in
  let p = p * t + 0.1000994575127818 in
  let p = p * t - 0.11133426586956469 in
  let p = p * t + 0.12550966952474304 in
  let p = p * t - 0.1440498967688461 in
  let p = p * t + 0.1695571769974082 in
  let p = p * t - 0.20738555102867398 in
  let p = p * t + 0.27058080842778454 in
  let p = p * t - 0.40068563438653143 in
  let (t2h, t2l) = __fp_two_prod t t in
  let tail = t2h * t * p in
  let (ah, al) = __dd_mul_d 0.5772156649015329 (0.0 - 4.942915152430645e-18) t in
  let (bh, bl) = __dd_mul t2h t2l 0.8224670334241132 1.5724194992319794e-17 in
  let (h, l) = __dd_add (0.0 - ah) (0.0 - al) bh bl in
  __dd_add h l tail 0.0;
let __libm_lgamma = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 1.0 / 0.0
  else if x == 0.0 then 1.0 / 0.0
  else if x < 0.0 && __fp_is_int_f x then 1.0 / 0.0
  else if x == 1.0 || x == 2.0 then 0.0
  else if f_abs x < 1.1830521861667747e-271 then (let (h, l) = __fp_log2p (f_abs x) in f_neg (h + l))
  else if x > 0.0 then
    (if f_abs (x - 1.0) < 0.1 then (let (h, l) = __lm_lgamma1p (x - 1.0) in h + l)
     else if f_abs (x - 2.0) < 0.1 then
       (let t = x - 2.0 in
        let (h, l) = __lm_lgamma1p t in
        let (ph, pl) = __dd_log1p t 0.0 in
        let (rh, rl) = __dd_add h l ph pl in
        rh + rl)
     else if x >= 4503599627370496.0 then
       // x (ln x - 1) - (ln x)/2 + ln sqrt(2 pi); past 2^900, x scaled into
       // the pair's range and the product scaled back
       (let (lh, ll) = __fp_log2p x in
        let (th, tl) = __dd_add lh ll (0.0 - 1.0) 0.0 in
        if x > 8.452712498170644e270 then
          (let (ph, pl) = __dd_mul_d th tl (x * 2.4099198651028841e-181) in
           (ph + pl) * 4.149515568880993e180)
        else
          (let (ph, pl) = __dd_mul_d th tl x in
           let (qh, ql) = __dd_add ph pl (0.0 - 0.5 * lh) (0.0 - 0.5 * ll) in
           let (rh, rl) = __dd_add qh ql 0.9189385332046728 (0.0 - 3.8782941580672414e-17) in
           rh + rl))
     else
       (let (yh, yl, ph, pl) = __lm_shift_up x 0.0 1.0 0.0 in
        let (gh, gl) = __lm_lgamma_big yh yl in
        let (lh, ll) = __dd_log ph pl in
        let (h, l) = __dd_add gh gl (0.0 - lh) (0.0 - ll) in
        h + l))
  else
    // ln pi - ln |sin(pi x)| - ln Gamma(1 - x)
    let (sh0, sl0) = __lm_sinpi x in
    let (sh, sl) = (if sh0 < 0.0 then (0.0 - sh0, 0.0 - sl0) else (sh0, sl0)) in
    let (lsh, lsl) = __dd_log sh sl in
    let (oh, ol) = __fp_two_sum 1.0 (0.0 - x) in
    let (yh, yl, ph, pl) = __lm_shift_up oh ol 1.0 0.0 in
    let (gh, gl) = __lm_lgamma_big yh yl in
    let (lph, lpl) = __dd_log ph pl in
    let (g2h, g2l) = __dd_add gh gl (0.0 - lph) (0.0 - lpl) in
    let (h1, l1) = __dd_add 1.1447298858494002 1.0265951162707826e-17 (0.0 - lsh) (0.0 - lsl) in
    let (h2, l2) = __dd_add h1 l1 (0.0 - g2h) (0.0 - g2l) in
    h2 + l2;
|mere}
