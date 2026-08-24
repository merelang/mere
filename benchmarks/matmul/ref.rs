// matmul reference, Rust. rustc does not contract a*b+c into an FMA, so this
// needs no flag to agree bit-for-bit with the others.
use std::env;

fn mk(n: i64, seed: i64) -> Vec<f64> {
    let mut v = Vec::with_capacity((n * n) as usize);
    let mut x = seed;
    for _ in 0..n * n {
        x = (1103515245i64 * x + 12345i64) % 2147483648i64;
        v.push((x % 2001 - 1000) as f64 / 1000.0);
    }
    v
}

fn main() {
    let n: i64 = env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(128);
    let a = mk(n, 20260825);
    let b = mk(n, 77770707);
    let mut c = vec![0.0f64; (n * n) as usize];
    for i in 0..n {
        for j in 0..n {
            let mut acc = 0.0f64;
            for k in 0..n {
                acc = acc + a[(i * n + k) as usize] * b[(k * n + j) as usize];
            }
            c[(i * n + j) as usize] = acc;
        }
    }
    let mut s = 0.0f64;
    for i in 0..n * n { s = s + c[i as usize]; }
    let bits = s.to_bits();
    println!("n {}", n);
    println!("checksum {} {}", bits >> 32, bits & 0xFFFF_FFFF);
}
