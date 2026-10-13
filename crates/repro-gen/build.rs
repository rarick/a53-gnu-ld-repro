use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

fn knob(name: &str, default: usize) -> usize {
    println!("cargo:rerun-if-env-changed={name}");
    env::var(name)
        .ok()
        .map(|v| v.parse().unwrap_or_else(|_| panic!("{name} must be an integer, got {v:?}")))
        .unwrap_or(default)
}

fn main() {
    let callers = knob("REPRO_CALLERS", 40_000);
    let pad_mib = knob("REPRO_PAD_MIB", 160);
    let fillers = knob("REPRO_FILLERS", 0);
    assert!(pad_mib > 128, "REPRO_PAD_MIB must exceed 128 so calls leave BL range");

    let mut s = String::with_capacity((callers * 2 + fillers) * 80);
    writeln!(s, "pub const CALLERS: usize = {callers};").unwrap();
    writeln!(s, "pub const PAD_MIB: usize = {pad_mib};").unwrap();
    writeln!(s, "pub const FILLERS: usize = {fillers};").unwrap();

    // rustc emits these in name order (a_call, b_fill, m_padd, z_targ), not in
    // the order they are written here. The prefixes set the layout.
    for i in 0..fillers {
        writeln!(s, "#[inline(never)] pub fn b_fill_{i:07}() -> u64 {{ {i} }}").unwrap();
    }
    for i in 0..callers {
        writeln!(s, "#[inline(never)] pub fn a_call_{i:07}() -> u64 {{ z_targ_{i:07}() }}").unwrap();
    }
    for i in 0..pad_mib {
        // 1 MiB of zero bytes inside a function that is never executed.
        writeln!(
            s,
            "#[inline(never)] pub fn m_padd_{i:07}() {{ unsafe {{ core::arch::asm!(\".space 1048576\", options(nomem, nostack)) }} }}"
        )
        .unwrap();
    }
    for i in 0..callers {
        writeln!(s, "#[inline(never)] pub fn z_targ_{i:07}() -> u64 {{ {i} }}").unwrap();
    }

    // Tables keep every function alive through --gc-sections.
    let table = |s: &mut String, name: &str, ty: &str, prefix: &str, n: usize| {
        writeln!(s, "pub static {name}: [{ty}; {n}] = [").unwrap();
        for i in 0..n {
            writeln!(s, "    {prefix}_{i:07},").unwrap();
        }
        writeln!(s, "];").unwrap();
    };
    table(&mut s, "CALLER_FNS", "fn() -> u64", "a_call", callers);
    table(&mut s, "PAD_FNS", "fn()", "m_padd", pad_mib);
    table(&mut s, "FILLER_FNS", "fn() -> u64", "b_fill", fillers);

    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("gen.rs");
    fs::write(out, s).unwrap();
}
