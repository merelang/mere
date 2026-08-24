// crc32 reference, Rust. Bitwise, no table, no crate.
use std::env;
use std::fs;

fn main() {
    let path = env::args().nth(1).expect("usage: ref <file>");
    let buf = fs::read(&path).expect("read");
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in buf.iter() {
        let mut c = crc ^ (b as u32);
        for _ in 0..8 {
            c = if c & 1 == 1 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
        }
        crc = c;
    }
    crc ^= 0xFFFF_FFFF;
    println!("bytes {}", buf.len());
    println!("crc32 {}", crc);
}
