# Map read boundaries

A Map belongs to the thread that creates it. A foreign storage read permanently
marks it shared, including an empty Map or one whose entries were all deleted.
A subsequent write fails even in the original owner after joining the reader.
Owner-side reads leave the Map writable. These checks run at access boundaries;
they do not lock an entire traversal against concurrent mutation.

## Access inventory

| Path | Boundary |
| --- | --- |
| `map_len`, generic `len` | Before reading the live length |
| `map_get` | At full application, before hashing or searching, including a missing key |
| `map_has` | At full application, before hashing or searching, including an absent key |
| `map_iter` | At full application, before reading length, tombstones, keys or values, and before either callback stage |
| Interpreter `show` and `to_json` | When visiting the Map, including nested Maps and mutable values |
| C region-loop carry copy | Before copying each source Map or Vec, recursively through supported carry values |
| `map_bytes` | Arena allocation measurement, with no entry read; does not mark the Map shared |
| Ordinary handle storage/promotion | Retains identity and lifetime; does not copy entries or mark a contents read |

`map_set`, `map_delete`, `map_clear`, `map_recycle` and `map_compact` are
mutation or upkeep paths, with their existing ownership rules. A rejected
foreign write is not a successful read and does not by itself freeze the Map.
Metadata-only constant/no-op implementations do not inspect element storage.

For curried readers, saving the Map in a partial application is not an access.
The mark runs when the remaining arguments have been evaluated and the operation
begins inspecting storage. A delayed call sees the latest contents. The callback
factory runs before `map_iter` enters; a callback that then fails has already
read the Map and leaves it shared.

## Layouts and copies

LLVM chooses the iteration guard with the same predicate that chooses the
runtime layout. Hash-safe scalar/compound keys use owner field 10 and
insertion-ordered slots with tombstones. The linear fallback, including
payload-bearing variant keys, uses owner field 5 and has no tombstone array.
The guard precedes both layouts' raw loads. Deleted slots produce no callback;
a reinserted key appears at its new insertion position.

C deep-copies supported Map/Vec carries between region-loop iterations.
The copier marks the original containers before inspecting their live slots,
including nested Maps and Vecs. The new containers have independent storage
and belong to the copying thread; the source's shared flag is not copied.
Other backends can retain container identity in a region loop instead. The
common carry cases read the carried Map afterward, and C-specific cases also
verify that the copied Map/Vec is writable and leaves the original data intact.

The missing-key path on both Wasm Map layouts raises the language's catchable
failure. A failed lookup still marks its source before inspecting storage.
As of v0.1.704, the linear layout follows this path rather than trapping. Wasm
iteration also checks failure after producing the inner closure and after
either value-callback path. A failure stops traversal before dereferencing a
failed closure result or calling the callback for the next entry.

## Validation and limits

`scripts/map_read_check.py --poison` checks explicit expected output across
interpreter, C, LLVM and Wasm. Its seven key families cover integers, booleans,
strings, tuples, records, nullary variants and payload-bearing variants.
Cases cover empty/full/deleted storage, failed lookup, membership, both length
forms, iteration order, reinserted keys, partial applications, callback failure,
evaluation count/order, snapshots and region-loop copies.

The direct builtin partial forms are interpreter cases; explicit `fn` wrappers
exercise supported compiled forms. A callback-factory barrier verifies that
argument evaluation does not prematurely freeze the Map. Formatting traversals
are interpreter cases: C/LLVM currently return placeholders for Maps rather
than traversing their entries, Wasm has no Map formatting/JSON representation,
and RISC-V rejects Map formatting. The gate does not add new serializers or
pretend those paths inspect contents.

`--rv-only --poison` uses the same catalogue for supported RV32/RV64 cases and
requires the C reference to satisfy the explicit expected output first. Negative
controls remove iterator entry guards on C/LLVM/Wasm, remove C carry read guards,
restore the Wasm linear lookup trap or remove callback failure checks,
remove RISC-V read helpers and duplicate
logical thread identities. Required tools and failed cases are errors, not skips.
