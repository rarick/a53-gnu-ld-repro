use repro_gen::{CALLERS, CALLER_FNS, FILLERS, FILLER_FNS, PAD_FNS, PAD_MIB};
use std::hint::black_box;

fn main() {
    // Call every caller, which calls its target through a long-branch veneer.
    // The sum checks the linked binary is correct: sum(0..CALLERS).
    let sum: u64 = CALLER_FNS.iter().map(|f| f()).sum();
    let expected = (CALLERS as u64) * (CALLERS as u64 - 1) / 2;

    // Reference the padding and filler tables (so --gc-sections keeps them)
    // without executing padding, which is zero bytes.
    let keep = black_box(&PAD_FNS).len() + black_box(&FILLER_FNS).len();

    println!(
        "callers={CALLERS} pad_mib={PAD_MIB} fillers={FILLERS} sum={sum} ok={} ({keep} kept)",
        sum == expected
    );
    assert_eq!(sum, expected);
}
