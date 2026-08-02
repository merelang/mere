# contrib/bignum

Arbitrary-precision natural numbers in pure Mere — a reusable library, not an
application. A big natural is a little-endian list of base-1e9 limbs
(`int list`), normalized so 0 is uniquely the empty list. Everything is an
ordinary immutable value: no mutation, no region parameters to thread, so a
big number is something you can return, compare, and print like any other
value.

```mere
import "github.com/merelang/mere/contrib/bignum/bignum.mere";

Bignum.to_str (Bignum.fact 100)         // "9332621544...000000"
Bignum.to_str (Bignum.fib 200)          // "280571172992510140037611932413038677189525"
Bignum.to_str (Bignum.mul a b)          // full schoolbook product
Bignum.cmp x y                          // -1 / 0 / 1
```

## API

| function | type | notes |
|----------|------|-------|
| `from_int` | `int -> big` | naturals only (n ≤ 0 → 0) |
| `add` | `big -> big -> big` | limb-carry addition |
| `mul_small` | `big -> int -> big` | multiply by a machine int |
| `mul` | `big -> big -> big` | schoolbook multiply |
| `cmp` | `big -> big -> int` | -1 / 0 / 1 |
| `to_str` | `big -> str` | decimal, MSB-first |
| `fact` | `int -> big` | n! |
| `fib` | `int -> big` | nth Fibonacci |

`big = int list`. Naturals only — no sign, subtraction, or division yet.

## Verification

`examples/bignum_demo.mere` imports this library and prints `100!`, `fib 200`,
a product, and a comparison; the output matches `python3`'s bignum exactly on
the interpreter and the C backend.

## Backend support

- **interp / C / LLVM**: full, exact (all three use 64-bit ints, so a base-1e9
  limb product stays in range).
- **Wasm**: `add` (and `fib`, `from_int`, `to_str`) work, but `mul` overflows:
  Wasm ints are 32-bit and a base-1e9 limb product is ~1e18. A Wasm build would
  need a smaller base (e.g. 1e4) at ~2× the limb count.

The base is 1e9 so that a limb product stays under 2^63 on the 64-bit
backends; addition's limb sum stays under 2^31, which is why it survives even
the 32-bit Wasm backend.
