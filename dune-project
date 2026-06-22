(lang dune 3.0)
(name mere)
(generate_opam_files true)

(source
 (github 284km/mere))

(license MIT)

(package
 (name mere)
 (synopsis "Make Explicit Region-bound Effects — an ML-family language with region memory, capability effects, and 3 codegen backends")
 (description "Mere is a small ML-family programming language implemented in OCaml. It features Hindley-Milner type inference with let-polymorphism, a region/view-based memory model with refined borrow modes, capability-passing effects, and feature-parity codegen to C / LLVM IR / Wasm in addition to the tree-walking interpreter. 1488+ tests, 118+ example programs.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))))
