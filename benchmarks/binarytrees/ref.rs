// binarytrees reference, Rust. Box per node, dropped when the tree leaves scope.
use std::env;

enum Tree {
    Leaf,
    Branch(Box<Tree>, Box<Tree>),
}

fn build(d: i32) -> Tree {
    if d == 0 { Tree::Leaf } else { Tree::Branch(Box::new(build(d - 1)), Box::new(build(d - 1))) }
}

fn check(t: &Tree) -> i64 {
    match t {
        Tree::Leaf => 1,
        Tree::Branch(l, r) => 1 + check(l) + check(r),
    }
}

fn main() {
    let maxdepth: i32 = env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(14);
    let longlived = build(maxdepth);
    let mut d = 4;
    while d <= maxdepth {
        let iters: i64 = 1i64 << (maxdepth - d + 4);
        let mut acc: i64 = 0;
        for _ in 0..iters {
            acc += check(&build(d));
        }
        println!("{} trees of depth {} check {}", iters, d, acc);
        d += 2;
    }
    println!("long-lived tree of depth {} check {}", maxdepth, check(&longlived));
}
