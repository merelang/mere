// churn reference, Rust. std HashMap; remove is O(1) amortized.
use std::collections::HashMap;
use std::env;

fn main() {
    let a: Vec<String> = env::args().collect();
    let n: i64 = a[1].parse().unwrap();
    let live: i64 = a[2].parse().unwrap();
    let pad = "------------------------------------------";
    let mut m: HashMap<String, String> = HashMap::new();
    for i in 0..n {
        m.insert(format!("s{}", i), format!("{}{}", i, pad));
        if i >= live {
            m.remove(&format!("s{}", i - live));
        }
    }
    let mut acc: i64 = 0;
    for j in (n - live)..n {
        acc += m[&format!("s{}", j)].len() as i64;
    }
    println!("live {}", m.len());
    println!("checksum {}", acc);
}
