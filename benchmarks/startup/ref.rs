// startup reference, Rust.
fn main() {
    let n: i64 = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(0);
    println!("startup {}", n * n + 1);
}
