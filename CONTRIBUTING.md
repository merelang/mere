# Contributing to Mere

Contributions to Mere are welcome.

## License (Important)

Mere is currently released under the **MIT License** (see [LICENSE](LICENSE)).

This project may in the future transition to a **MIT OR Apache-2.0 dual
license**. Therefore, by submitting a pull request / patch / commit, you
are deemed to agree to the following:

1. Your contribution will be distributed under the **MIT License**.
2. If Mere later adds Apache License 2.0 and becomes dual-licensed,
   your contribution will also be distributed under the **Apache License 2.0**.

This is to preserve room to reconsider the project's license strategy
shortly after public release. For current users, only the MIT License is
effective.

## Development Flow

1. Fork and create a branch (`git checkout -b your-feature`)
2. Make your changes and ensure tests (`dune runtest`) pass. `mere check <file>`
   runs every check the compile path runs without emitting anything
3. Open a pull request

Please include in your PR:
- The motivation for the change (what problem it solves / what feature it adds)
- Which backends are affected: interpreter, C, LLVM IR, Wasm, or RISC-V
  (RV32IM / RV64IM)
- A description of any new tests you added

State which checks actually ran and which required tools were unavailable.
The default parity suite compares the interpreter, C, LLVM and Wasm; RISC-V
has separate hosted-execution and QEMU checks. Feature support and execution
models differ by backend; see [the memory and concurrency contract](docs/memory-model.md#concurrency-and-sharing).

## Bug Reports / Feature Requests

Please file them on GitHub Issues. Reproduction steps plus the output of
`dune exec ./bin/mere.exe -- --version` are helpful.

## Design Discussions

Discuss large language-design changes in a public Issue before opening a PR.
Include a small example, the proposed behavior and the affected backends.
Use public specifications, code and tests as references.

## Code Style

- The OCaml core has no `.ocamlformat`, so `dune fmt` does not apply to it;
  follow the style of the surrounding code
- `.mere` files can be normalized with `mere fmt` (`mere fmt --check` lists
  the files that would change). Examples should follow the style of existing
  files. Compare output across the supported backends and record any
  backend-specific limitations.

## Checks that guard the documentation

Some documentation is held to the code by CI, so a change to one usually needs
the other:

- A new builtin must be named in a hand-written page under `docs/`
  (`scripts/doc_coverage_check.sh`). A deliberately undocumented internal
  name goes in `docs/UNDOCUMENTED_ALLOW` with the reason.
- `docs/host-matrix.md` is generated: run `sh scripts/host_matrix.sh --update`
  after changing which backend lowers which builtin.
- A reserved word must appear in `docs/language-reference.md` and
  `docs/reserved-names.md` (`scripts/keywords_doc_check.sh`).
- The README's quick-example transcript, its parity program count (the files
  in `test/parity/`) and its test count are re-derived by
  `scripts/first_run_check.sh`.
