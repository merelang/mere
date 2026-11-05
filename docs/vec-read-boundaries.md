# Vec read boundaries

A Vec belongs to the thread that creates it. An owner read leaves it writable;
a foreign read permanently marks it shared. Subsequent writes fail, including
writes by the original owner after joining the reader. Reading an empty Vec
still reads its length and must mark it shared.

The mark precedes the first length or element access in the operation. For
curried operations it runs at full application, after evaluating arguments,
before copying slots or calling a callback. Merely capturing a Vec in a
closure does not read it. A closure completed later observes the current
length and contents, rather than a snapshot taken when it was created.

## Inventory

| Operation | Read boundary |
| --- | --- |
| `vec_len`, generic `len` | Before reading the length |
| `vec_get` | Before checking bounds, including a failing lookup |
| `vec_iter`, `vec_fold`, `vec_map`, `vec_filter` | At full application, before reading length or invoking the first callback; empty input counts too |
| `vec_concat` | At full application, mark both inputs before reading either length, including empty inputs and two aliases of one Vec |
| `vec_to_list`, `vec_to_owned`, `bytes_of_vec` | Before reading length or copying any slots |
| `show`, `to_json` | When visiting the Vec, including one nested in a record, tuple, list or variant; see [formatting ownership](memory-model.md) for supported representations |
| `f64x2_load` | Before checking the lane bounds, including failure |
| `write_file_bytes`, `file_pwrite` | Before inspecting Vec storage to write or convert it to bytes |
| `vec_bytes` | No element-storage read: measures arena allocation, so it does not mark the Vec shared |

File operations may fail before inspecting the Vec: for example, opening or
seeking can fail on native backends before a length is read. Wasm converts
the Vec to bytes before calling its host file operation. The rule follows
the actual storage access; an I/O failure alone is not evidence of a read.

The internal `__vec_get_unchecked` and `__f64x2_load_unchecked` operations are
optimizer entry points. C and LLVM omit their per-element checks because the
range-versioning guard reads `vec_len` first and marks the source there.
They are not public alternatives to checked access. Interpreter, Wasm and
RISC-V implementations retain checks for these internal operations.

## Copies and backend support

Conversions copy the live slots into separate storage. A new mutable result
has its own ownership metadata; sharing that result does not freeze the
source. Owner-side source mutation after conversion does not change the
copied slots. This is not a recursive clone of mutable values stored inside
the Vec: their identities remain shared. Immutable list or byte snapshots
can be read by another thread without reading the source Vec.

As of v0.1.703, the interpreter guards filter, concatenation, Vec-to-OwnedVec
and byte conversion, and Vec-based file output. Failed get and SIMD bounds
checks also mark their length read. C guards map, filter and both concatenation
inputs at entry, including empty inputs, and Vec-based file output before its
raw storage loop. LLVM guards iteration, folding, map, filter, concatenation,
list conversion and Vec-to-OwnedVec conversion before their raw copies.
Wasm already marks these supported paths through entry guards or checked
length/get helpers.

`scripts/vec_read_check.py --poison` checks interpreter, C, LLVM and Wasm
against explicit expected output. It covers empty/full inputs, failed access,
callback failures, string elements, independent copies, single argument and
callback evaluation, and late execution through closures. A `bytes_of_vec`
alias runs on all backends. Direct `vec_to_owned`/`vec_to_list` aliases and
builtin partial applications are interpreter cases; explicit `fn` wrappers
exercise the supported compiled forms. Vec `show` and `to_json` cases run on interpreter and C;
the existing formatting gate checks nested representations. File-output
ownership cases run on interpreter, C, LLVM and RISC-V: the Node Wasm worker
bootstrap currently lacks file imports, so a module with file I/O cannot
instantiate in that worker. Wasm's emitted file-output helpers call checked
Vec length/byte conversion; this gate does not execute foreign Wasm file I/O.

`--rv-only --poison` runs the supported cases at RV32 and RV64 and checks the
C reference against the same explicit expectations first. RISC-V currently
rejects `vec_map`, `vec_filter` and `vec_concat`; the gate does not substitute
an implementation for them. Negative controls remove C, LLVM and Wasm entry
marks and RISC-V read guards, and duplicate logical thread identities, so a missed read
must be observable as an incorrectly permitted source write.
