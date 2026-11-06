# C allocation alignment

The C representation of `f64x2`, `f32x4` and `u8x16` requires 16-byte
alignment. A closure environment, record, tuple or variant containing one
inherits that requirement from C. A valid language program must satisfy it
when allocating or copying the value, including on machines that tolerate
some misaligned loads.

Since v0.1.709, typed allocations pass `__alignof__` to the region allocator.
Ordinary values retain 8-byte allocation rounding. A SIMD allocation aligns
the current bump pointer and charges its payload and padding to the region;
forwarded allocation sites receive the same charge. The shared default region
holds its allocation lock while calculating and consuming that padding.

Region block headers have 16-byte alignment, so every new payload begins on
that boundary. This applies to the initial block, a new bump block and a
dedicated large block. Buffer growth preserves its requested alignment in
place, on relocation and when reallocating a dedicated block. The generated
types require at most 16-byte alignment.

| Allocation path | Alignment source |
| --- | --- |
| Closure construction and local function environments | Environment type |
| Environment copies between regions | Copied environment type |
| Coroutine-owned environments | Environment type and malloc alignment |
| Boxed variants, list cells and ListBuf nodes | Node type |
| Recursive copies and decoded boxed values | Destination node type |
| References and views | Referent or view type |
| Map keys and values during growth, compaction and reuse | Key or value type |
| Vec storage during growth, compaction and reuse | Element type |

Records and tuples passed by value receive their alignment from C. When
nested inside one of these allocated objects, their alignment is inherited
by the enclosing type and used by that allocation path.

`test/parity/simd_capture.mere` compares captured SIMD values across the
interpreter, C, LLVM and Wasm. The C compiler bundle additionally runs
`test/c_compiler/simd_alignment.mere` and `alignment_runtime.c` under UBSan.
These cover region copies, odd-sized Map compaction, Vec relocation,
container reuse, coroutine environments, block transitions and concurrent
allocation. Controls that discard type alignment, misalign block payloads or
discard alignment during buffer relocation must fail the same checks.
