// matmul reference, MoonBit. Native target, release build.
//
// MoonBit's native backend lowers to C, so the contraction question that made
// the C row need -ffp-contract=off applies here too -- see the MANIFEST for
// what this row actually does about it.
fn mk(n : Int, seed : Int64) -> Array[Double] {
  let v = Array::make(n * n, 0.0)
  let mut x = seed
  let mut i = 0
  while i < n * n {
    x = (1103515245L * x + 12345L) % 2147483648L
    v[i] = (x % 2001L - 1000L).to_double() / 1000.0
    i = i + 1
  }
  v
}

fn main {
  let args = @env.args()
  let n = if args.length() > 1 {
    @strconv.parse_int(args[1]) catch { _ => 128 }
  } else {
    128
  }
  let a = mk(n, 20260825L)
  let b = mk(n, 77770707L)
  let c = Array::make(n * n, 0.0)
  let mut i = 0
  while i < n {
    let mut j = 0
    while j < n {
      let mut acc = 0.0
      let mut k = 0
      while k < n {
        acc = acc + a[i * n + k] * b[k * n + j]
        k = k + 1
      }
      c[i * n + j] = acc
      j = j + 1
    }
    i = i + 1
  }
  let mut s = 0.0
  let mut t = 0
  while t < n * n {
    s = s + c[t]
    t = t + 1
  }
  let bits = s.reinterpret_as_uint64()
  println("n \{n}")
  println("checksum \{bits >> 32} \{bits & 0xFFFFFFFFUL}")
}
