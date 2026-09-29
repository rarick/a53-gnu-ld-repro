//! Generated workload for the GNU ld / Cortex-A53 843419 link-time repro.
//!
//! `build.rs` writes `gen.rs` with three groups of functions, in this order:
//!
//! 1. `REPRO_CALLERS` callers, `caller_i() -> target_i()`.
//! 2. `REPRO_PAD_MIB` padding functions of 1 MiB each (an inline-asm `.space`).
//!    They are never called; they only move the targets out of `BL` range
//!    (+/-128 MiB on AArch64).
//! 3. `REPRO_CALLERS` targets, `target_i() -> i`.
//!
//! Every call therefore needs a long-branch veneer, so the linker's stub table
//! holds about `REPRO_CALLERS` entries (N), and the link has about
//! `2 * REPRO_CALLERS + REPRO_PAD_MIB + REPRO_FILLERS` input sections from this
//! crate (S), because rustc emits one `.text.*` section per function.
//! `REPRO_FILLERS` adds leaf functions that raise S without adding veneers.

include!(concat!(env!("OUT_DIR"), "/gen.rs"));
