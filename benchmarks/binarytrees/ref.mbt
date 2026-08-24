// binarytrees reference, MoonBit. An enum with a two-field constructor, which
// is the same shape as the Mere row's `Branch of tree * tree` -- both are
// tagged allocations, and the interesting difference is what each runtime does
// with them afterwards.
enum Tree {
  Leaf
  Branch(Tree, Tree)
}

fn build(d : Int) -> Tree {
  if d == 0 { Leaf } else { Branch(build(d - 1), build(d - 1)) }
}

fn check(t : Tree) -> Int64 {
  match t {
    Leaf => 1L
    Branch(l, r) => 1L + check(l) + check(r)
  }
}

fn main {
  let args = @env.args()
  let maxdepth = if args.length() > 1 {
    @strconv.parse_int(args[1]) catch { _ => 14 }
  } else {
    14
  }
  let longlived = build(maxdepth)
  let mut d = 4
  while d <= maxdepth {
    let iters = 1L << (maxdepth - d + 4)
    let mut acc = 0L
    let mut i = 0L
    while i < iters {
      acc = acc + check(build(d))
      i = i + 1L
    }
    println("\{iters} trees of depth \{d} check \{acc}")
    d = d + 2
  }
  println("long-lived tree of depth \{maxdepth} check \{check(longlived)}")
}
