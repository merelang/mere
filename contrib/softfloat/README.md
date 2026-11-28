# contrib/softfloat

An IEEE 754 double, held as integers narrow enough for a backend that has no
float, with correctly rounded arithmetic and exact decimal conversion computed
in those integers. **The library never mentions `float`** (one bridge file,
`bits.mere`, is the named exception) — that is the point, and
`scripts/softfloat_check.sh` checks it as a test.

The RV32I backend's float operators are this library: it is baked into the
compiler as `lib/rv_softfloat.ml` by `scripts/gen_rv_softfloat.sh` (an
installed compiler has no `contrib/` to import from).

```mere
import "github.com/merelang/mere/contrib/softfloat/softfloat.mere";

let one = mk 0 1023 0 0 0 0;      // sign, exponent, then the fraction limbs
let _ = print_int (if lt (neg one) one then 1 else 0);   // 1
```

The arithmetic files import `softfloat.mere` themselves:

```mere
import "contrib/softfloat/add.mere";
import "contrib/softfloat/sqrt.mere";
import "contrib/softfloat/conv.mere";
import "contrib/softfloat/dec.mere";

let _ = print (dec_of_sf (add (sf_of_dec "0.1") (sf_of_dec "0.2")));  // 0.30000000000000004
let _ = print (dec_of_sf (fsqrt (of_int 2)));                         // 1.4142135623730951
```

## The representation

A double is 64 bits: sign(1), exponent(11), fraction(52). Here the fraction is
four **15-bit limbs**, little-endian (`f0` lowest).

15 is not a round number, and it is not a taste. A product of two limbs has to
fit the narrowest int any backend has, which is RV32I's **signed 32-bit** word:
15 + 15 = 30 bits, and the sign bit is left alone.

The obvious alternative is the split the compiler already offers —
`float_bits_hi` / `float_bits_lo`, two 32-bit halves — and it does not work on
the target that needs this library. Those halves are *unsigned*
(`float_bits_hi (-1.0)` is 3220176896), and an unsigned 32-bit value does not
fit a signed 32-bit int. It is the same answer as the one that produced the
halves, one target further down: one accessor did not fit an interpreter's
63-bit int, and two do not fit a 32-bit one.

## What is here

| file | exports |
|---|---|
| `softfloat.mere` | the `Sf` record and everything in the table below |
| `limbs.mere` | `L6`, a 90-bit unsigned integer as six 15-bit limbs — the working width for the operations (`l6_add` / `l6_sub` / `l6_cmp` / shifts / `l6_of_int` / `l6_to_int` …) |
| `add.mere` | `add`, `sub` (round to nearest, ties to even) |
| `mul.mere` | `mul` |
| `div.mere` | `fdiv` (restoring long division) |
| `sqrt.mere` | `fsqrt` (correctly rounded) |
| `conv.mere` | `of_int` (rounds to nearest even), `to_int` (truncates toward zero) |
| `dec.mere` | `sf_of_dec` (decimal or hex string → double, with the interpreter's `float_of_str` contract) and `dec_of_sf` (the shortest `%.{p}g`, p = 12..17, that reads back to the same bits) |
| `bits.mere` | the bridge to hardware doubles: `sf_of_float` / `float_of_sf` / `sf_of_hi_lo` / `hi_of_sf` / `lo_of_sf` — the one file that mentions `float` |

`softfloat.mere` itself:

| | |
|---|---|
| `mk sign exp f3 f2 f1 f0` | the raw fields, masked to width |
| `zero` `neg_zero` `inf` `neg_inf` `nan` | the named values |
| `is_nan` `is_inf` `is_zero` `is_subnormal` `is_finite` `frac_is_zero` | classification |
| `neg` `abs` `is_neg` | sign, as a bit operation — defined on NaN too |
| `cmp_mag` `eq` `lt` `gt` `le` `ge` | ordering, with IEEE's two exceptions |

`eq` and `lt` are not bit comparisons. `-0.0` equals `+0.0` and a NaN equals
nothing, including itself; neither falls out of comparing the fields.

The representation and its round-trip gate came first, because an operation
checked against a round trip that is itself wrong is checked against nothing.
The operations followed, each held to the hardware bit for bit.

## The gate

`sh scripts/softfloat_check.sh` — every value in
`test/float/softfloat_roundtrip.mere` goes to limbs and back as **the same 64
bits**, and the interpreter and the C backend print the same bytes; `add` /
`sub`, `mul`, `fdiv`, `fsqrt` and the integer conversions produce the
hardware's bits (`test/float/softfloat_{add,mul,div,sqrt,conv}.mere`, plus
`softfloat_limbs.mere` for `L6`); the decimal conversions agree with the
platform's `strtod` / `printf` (`softfloat_dec.mere`, compiled through C); no
file but `bits.mere` names `float`; and every exported name compiles with
`mere -rv`.

The inputs are built from bit patterns, not written as decimals. A table of
decimal literals covers whichever doubles the author thought of; the boundaries
of the format — the largest subnormal, the smallest normal, the limb split that
straddles the two 32-bit halves — are the ones nobody writes down.
