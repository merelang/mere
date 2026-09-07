// mat4xvec4 reference, Rust. Rust does not contract a*b + c into an FMA
// without an explicit `mul_add`, so no flag is needed here -- the arithmetic
// is unfused as written, like every other row.
fn mk(count: usize, seed: i64) -> Vec<f64> {
    let mut v = Vec::with_capacity(count);
    let mut x = seed;
    for _ in 0..count {
        x = (1103515245i64 * x + 12345) % 2147483648;
        v.push((x % 2001 - 1000) as f64 / 1000.0);
    }
    v
}

fn main() {
    let n: usize = std::env::args().nth(1)
        .and_then(|a| a.parse().ok()).unwrap_or(20000);
    let m = mk(16, 20260907);
    let vs = mk(4 * n, 77770707);
    let (mut ax, mut ay, mut az, mut aw) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
    for _ in 0..5000 {
        for i in 0..n {
            let (x, y) = (vs[4 * i], vs[4 * i + 1]);
            let (z, w) = (vs[4 * i + 2], vs[4 * i + 3]);
            ax += m[0] * x + m[4] * y + m[8] * z + m[12] * w;
            ay += m[1] * x + m[5] * y + m[9] * z + m[13] * w;
            az += m[2] * x + m[6] * y + m[10] * z + m[14] * w;
            aw += m[3] * x + m[7] * y + m[11] * z + m[15] * w;
        }
    }
    let s = ax + ay + az + aw;
    let bits = s.to_bits();
    println!("n {}", n);
    println!("checksum {} {}", bits >> 32, bits & 0xFFFF_FFFF);
}
