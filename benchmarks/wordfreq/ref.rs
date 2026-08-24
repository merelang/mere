// wordfreq reference, Rust. std HashMap, the idiomatic answer.
use std::collections::HashMap;
use std::env;
use std::fs;

fn main() {
    let path = env::args().nth(1).expect("usage: ref <file>");
    let text = fs::read_to_string(&path).expect("read");
    let mut counts: HashMap<&str, i64> = HashMap::new();
    let mut total: i64 = 0;
    for w in text.split(|c| c == ' ' || c == '\n') {
        if w.is_empty() { continue; }
        *counts.entry(w).or_insert(0) += 1;
        total += 1;
    }
    let mut pairs: Vec<(&str, i64)> = counts.iter().map(|(k, v)| (*k, *v)).collect();
    pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    println!("words {}", total);
    println!("unique {}", pairs.len());
    for (w, c) in pairs.iter().take(10) {
        println!("{} {}", w, c);
    }
}
