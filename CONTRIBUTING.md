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
2. Make your changes and ensure tests (`dune runtest`) pass
3. Open a pull request

Please include in your PR:
- The motivation for the change (what problem it solves / what feature it adds)
- Which of the 4 backends (interp + C + LLVM + Wasm) are affected
- A description of any new tests you added

## Bug Reports / Feature Requests

Please file them on GitHub Issues. Reproduction steps plus the output of
`dune exec ./bin/mere.exe -- --version` are helpful.

## Design Discussions

Language-design OPEN_QUESTIONS and paper-validated decisions are
managed in a separate repository (see the README for details). Proposals
that involve large design changes should first be discussed in an Issue
before opening a PR.

## Code Style

- The OCaml core uses dune's standard formatting (`dune fmt`)
- `.mere` examples should follow the style of existing files (a test to
  maintain diff = 0 across the 4 backends may be required)
