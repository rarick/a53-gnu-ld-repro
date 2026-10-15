# Minimal reproduction

One default link of a large AArch64 binary with GNU ld. `run.sh` builds the
synthetic crate in [`../crates`](../crates) with a plain `cargo build`, in the
official `rust:1.98-bookworm` Docker image, and changes nothing else. It uses the
image's default linker, Debian's GNU ld 2.40, and rustc's default link arguments,
which since Rust 1.98 include `-Wl,--fix-cortex-a53-843419`.

It needs Docker on an AArch64 host and pulls a 1.5 GB image on first use. The
build runs in a throwaway container with the repository mounted read-only.

```sh
./minimal/run.sh
```

On a Graviton3 (Neoverse V1), the crate compiles in about 11 s and the link
takes about a minute:

```text
== rust:1.98-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e
rustc 1.98.1 (48a229cea 2026-09-01)
GNU ld (GNU Binutils for Debian) 2.40
== Compiling the generated crate (no link yet)
   Compiling repro-gen v0.1.0 (/work/crates/repro-gen)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 11.33s
== Compiling main.rs and linking the binary (nearly all of this is the link)
   Compiling repro v0.1.0 (/work/crates/repro)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1m 00s
long-branch veneers in the binary: 40178
```

For comparison, the same workload links in 1.3 s with a GNU ld that skips the
erratum pass, and in 0.3 s with lld (case matrix in the
[top-level README](../README.md)).

## The workload

`../crates/repro-gen/build.rs` generates 40,000 small caller functions, then 160
MiB of padding that is never executed, then the 40,000 functions they call. Each
call target is farther away than the ±128 MiB an AArch64 `BL` can reach, so the
linker adds a long-branch veneer for every call: about 40,000 stubs (N). rustc
gives every function its own section, so the generated crate contributes about
80,000 input sections (S).

GNU ld's Cortex-A53 843419 pass walks the whole stub table once per input
section, so its cost grows with S × N. Nothing in this binary needs the erratum
fix, so the time the pass takes is pure overhead.

## What this doesn't show

Here the link is slow whatever rustc passes. Debian's gcc requests the erratum
fix by default, and every GNU ld release from 2.33 through 2.47 runs the pass
even when it isn't requested. The fix for that, binutils commit 6e72ff2, isn't
in a release yet. To see the link become fast without the flag, you need a GNU
ld that has the fix. The top-level `Dockerfile` builds one, and its
`patched/strip` and `patched/optout` cases show the difference on both Rust
1.97 and 1.98.
