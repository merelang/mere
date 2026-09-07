// mat4xvec4_f32 reference, Rust. No mul_add anywhere, so nothing is contracted
// into an FMA and the arithmetic is unfused as written, like every other row.
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
    let md = mk(16, 20260907);
    let vd = mk(4 * n, 77770707);
    // The same narrowing the lanes do: the inputs are doubles, a lane is an f32.
    let m: Vec<f32> = md.iter().map(|&x| x as f32).collect();
    let vs: Vec<f32> = vd.iter().map(|&x| x as f32).collect();

    let (mut a0, mut a1, mut a2, mut a3) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    for _ in 0..5000 {
        for i in 0..n {
            let (x, y) = (vs[4 * i], vs[4 * i + 1]);
            let (z, w) = (vs[4 * i + 2], vs[4 * i + 3]);
            a0 += m[0] * x + m[4] * y + m[8] * z + m[12] * w;
            a1 += m[1] * x + m[5] * y + m[9] * z + m[13] * w;
            a2 += m[2] * x + m[6] * y + m[10] * z + m[14] * w;
            a3 += m[3] * x + m[7] * y + m[11] * z + m[15] * w;
        }
    }
    // Folded left to right, which is what f32x4_reduce_add is specified to do.
    let mut sf = a0 + a1; sf = sf + a2; sf = sf + a3;
    let bits = (sf as f64).to_bits();
    println!("n {}", n);
    println!("checksum {} {}", bits >> 32, bits & 0xFFFF_FFFF);
}
