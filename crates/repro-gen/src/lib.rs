//! Generated workload for the GNU ld / Cortex-A53 843419 link-time repro.
//!
//! `build.rs` writes `gen.rs`. rustc emits its functions in name order, so in
//! the linked binary they appear as:
//!
//! 1. `REPRO_CALLERS` callers, `a_call_i() -> z_targ_i()`.
//! 2. `REPRO_FILLERS` leaf functions, `b_fill_i() -> i`, which need no veneer.
//! 3. `REPRO_PAD_MIB` padding functions of 1 MiB each (an inline-asm `.space`),
//!    `m_padd_i()`. They are never called; they only move the targets out of
//!    `BL` range (+/-128 MiB on AArch64).
//! 4. `REPRO_CALLERS` targets, `z_targ_i() -> i`.
//!
//! Every call therefore needs a long-branch veneer, so the linker's stub table
//! holds about `REPRO_CALLERS` entries (N), and the link has about
//! `2 * REPRO_CALLERS + REPRO_PAD_MIB + REPRO_FILLERS` input sections from this
//! crate (S), because rustc emits one `.text.*` section per function.
//! `REPRO_FILLERS` adds leaf functions that raise S without adding veneers.

include!(concat!(env!("OUT_DIR"), "/gen.rs"));
