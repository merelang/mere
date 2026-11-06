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

## Audited operations

| Operation | Boundary |
| --- | --- |
| `bytes_slice` | Start and count against the existing byte length |
| `substring` | Ordered start/end positions against the string's byte length |
| `bytes_get`, `bytebuf_get`, `bytebuf_set` | Full-width index before storage access |
| `vec_get`, `vec_set` | Full-width index before element addressing |
| `str_index_from` | Offset before searching; negative offsets begin at zero |

`test/parity/range_limits.mere` covers each integer model's maximum and
minimum, overflowing slice sums, empty end slices, embedded NUL bytes and
storage preserved after refused writes. Its results agree across interpreter,
C, LLVM, Wasm, RV32 and RV64. `range_limits_wide.mere` additionally exercises
arguments at 2^32 on the four native/hosted backends and RV64; RV32 cannot
represent that literal. The existing parity and RISC-V execution gates include
both files. Interpreter unit tests independently assert the slice outcomes.

These checks concern ranges in existing storage. Allocation requests such as
`bytebuf_new` and `str_repeat`, exhaustion behaviour and maximum object sizes
have separate contracts; they are not equivalent to an invalid slice.
