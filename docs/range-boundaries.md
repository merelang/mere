# Integer range boundaries

An existing buffer's range must be validated before allocation, pointer
arithmetic, copying or narrowing an argument to the target's address width.
An invalid range is a language failure that `try_or` can catch.

For `bytes_slice b start count`, require `0 <= start <= bytes_len b` and
`0 <= count <= bytes_len b - start`. An empty slice at the end is valid;
an empty slice starting past the end is not. Adding `start + count` for the
check can overflow even when both arguments are nonnegative.

As of v0.1.708, the interpreter and C check the start before subtracting it.
LLVM and Wasm use full-width unsigned comparisons against the size and the
remaining length. Negative arguments fail those comparisons too. Their
unflagged subtraction may wrap for an invalid start; the start comparison
already rejects that case. Wasm narrows the arguments only after validation.
RISC-V already rejects negative arguments and compares their sum unsigned:
two nonnegative signed integers cannot overflow the unsigned word. Its
existing guard is retained and exercised at both widths.

Fixed-width SIMD accesses check that the container holds a complete span,
then compare the index against `length - span`: two float elements for
`f64x2_load/store`, sixteen bytes for `u8x16_load`. C, LLVM, both boxed and
unboxed Wasm paths and RISC-V's float prelude follow this rule. Interpreter
failure messages compute the displayed endpoint in Int64, preserving the
existing message format without overflowing its 63-bit integer model.
The RISC-V load marks its Vec read before validating even a negative index;
stores retain their owner check before reading the length or checking bounds.
Wasm's unboxed SIMD helpers return immediately after recording a catchable
failure, before any access or write using the rejected index.

Range-check versioning uses the same remaining-length rule when selecting an
unchecked loop, including its plain-index and derived-index endpoint guards.
`test/range_version/span_overflow.mere` compares the checked and optimized loops
at each integer model's upper bound and checks that refused stores preserve data.

## Audited operations

| Operation | Boundary |
| --- | --- |
| `bytes_slice` | Start and count against the existing byte length |
| `substring` | Ordered start/end positions against the string's byte length |
| `bytes_get`, `bytebuf_get`, `bytebuf_set` | Full-width index before storage access |
| `vec_get`, `vec_set` | Full-width index before element addressing |
| `f64x2_load`, `f64x2_store`, `u8x16_load` | A complete fixed-width span before any element access |
| `f64x2_extract`, `u8x16_extract` | Full-width lane index before narrowing |
| `str_index_from` | Offset before searching; negative offsets begin at zero |

`test/parity/range_limits.mere` covers each integer model's maximum and
minimum, overflowing slice sums, empty end slices, embedded NUL bytes and
storage preserved after refused writes. Its results agree across interpreter,
C, LLVM, Wasm, RV32 and RV64. `range_limits_wide.mere` additionally exercises
arguments at 2^32 on the four native/hosted backends and RV64; RV32 cannot
represent that literal. The existing parity and RISC-V execution gates include
both files. Interpreter unit tests independently assert slice and SIMD outcomes.

These checks concern ranges in existing storage. Allocation requests such as
`bytebuf_new` and `str_repeat`, exhaustion behaviour and maximum object sizes
have separate contracts; they are not equivalent to an invalid slice.
