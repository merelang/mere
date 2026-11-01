(lang dune 3.0)
(name mere)
(generate_opam_files true)

(source
 (github merelang/mere))

(license MIT)
(authors "Kazuma Furuhashi <k.furuhashi10@gmail.com>")
(maintainers "Kazuma Furuhashi <k.furuhashi10@gmail.com>")

(package
 (name mere)
 (synopsis "An ML-family language with explicit regions and capability effects")
 (description "Mere is a small ML-family programming language implemented in OCaml. It features Hindley-Milner type inference with let-polymorphism, a region/view-based memory model with refined borrow modes, capability-passing effects, a tree-walking interpreter, and code generation for C, LLVM IR, Wasm and RISC-V. The repository documents backend-specific support and validation.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))))
