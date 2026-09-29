# GNU ld + `--fix-cortex-a53-843419`: link time scales as sections × stubs on AArch64

A self-contained Docker reproducer. It shows that on AArch64, GNU ld's Cortex-A53
erratum 843419 workaround costs time proportional to **(input sections) × (linker
stubs)**, even when no erratum site exists. It also shows that since Rust 1.98
([rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453)) there is
no way to turn the workaround off from `rustc`/Cargo.

Everything here runs natively on an aarch64 Linux host with Docker. The inputs are
public: the official `rust` Docker Hub image, the GNU binutils 2.47 release
tarball (checksum pinned), and an upstream binutils commit vendored as a patch.

## Results (Graviton3, 64 vCPU, workload `REPRO_CALLERS=40000`)

Link time of one binary: 162 MiB `.text`, 40,178 long-branch veneers, and about
80k input sections from the generated crate. The binary is identical across
cases apart from the linker's choices. Every case runs correctly (`ok=true`).

| case | linker | does ld get `--fix-cortex-a53-843419`? | erratum stubs created | **link time** |
|---|---|---|---|---|
| `fixed/strip` | GNU ld 2.47 + upstream fix 6e72ff2 | no | 0 | **1.3 s** |
| `fixed/keep` | GNU ld 2.47 + upstream fix 6e72ff2 | yes (rustc 1.98 default) | 0 | **82.9 s** |
| `fixed/optout` | same, plus `-C link-arg=-mno-fix-cortex-a53-843419` | yes (rustc's `-Wl,` wins) | 0 | **84.6 s** |
| `stock/strip` | GNU ld 2.47 release | no | 0 | 82.5 s |
| `stock/keep` | GNU ld 2.47 release | yes | 0 | 81.4 s |
| `system/strip` | Debian bookworm ld 2.40 | no | 0 | 61.4 s |
| `system/keep` | Debian bookworm ld 2.40 | yes | 0 | 61.6 s |
| `lld/keep` | LLD 14 (Debian) | yes, and applied | 0 | 0.3 s |

The same workload with **Rust 1.97**, which does not pass the flag itself
([results/rust-1.97-final/summary.txt](results/rust-1.97-final/summary.txt)):

| case | linker | does ld get the fix? | link time |
|---|---|---|---|
| `fixed/keep` | GNU ld 2.47 + 6e72ff2 | yes: Debian's gcc adds it by default (`--enable-fix-cortex-a53-843419`) | 67.8 s |
| `fixed/optout` | same, plus `-C link-arg=-mno-fix-cortex-a53-843419` | **no**: the opt-out works on 1.97 | **1.3 s** |
| `system/keep` | Debian ld 2.40 | yes (gcc default) | 62.4 s |
| `lld/keep` | LLD 14 | yes | 0.3 s |

The same user-level opt-out, `-C link-arg=-mno-fix-cortex-a53-843419`, gives
**1.3 s on Rust 1.97 and 84.6 s on Rust 1.98**.

### Scaling (patched GNU ld; the flag is the only difference between columns)

`CALLERS` raises both N (one veneer each) and S (two sections each). `FILLERS`
raises only S.

| callers | fillers | veneers (N) | no fix | with fix | slowdown |
|---|---|---|---|---|---|
| 5,000 | 0 | 5,178 | 0.5 s | 1.5 s | 3× |
| 10,000 | 0 | 10,178 | 0.6 s | 4.5 s | 7.5× |
| 20,000 | 0 | 20,178 | 0.8 s | 17.3 s | 22× |
| 40,000 | 0 | 40,178 | 1.3 s | 85.9 s | 66× |
| 80,000 | 0 | 80,178 | 2.4 s | 332.2 s | 138× |
| 20,000 | 40,000 | 20,178 | 1.3 s | 33.4 s | 26× |
| 20,000 | 160,000 | 20,178 | 2.6 s | 85.7 s | 33× |

- Doubling `CALLERS`, which doubles both S and N, quadruples the extra time.
- Adding `FILLERS` at fixed N grows it linearly in S.
- That is the S × N shape. The extra time works out to roughly 25 ns per (section, stub) pair.

## What is going on

1. **GNU ld's 843419 workaround walks every stub, for every input section.**
   `bfd_elf_final_link` → `elf_link_input_bfd` calls the backend
   `write_section` hook once per input section. On AArch64,
   `elfNN_aarch64_write_section` then runs
   `bfd_hash_traverse(&globals->stub_hash_table, _bfd_aarch64_erratum_843419_branch_to_stub, …)`
   over the **entire** stub table to find the few erratum stubs that belong to
   that one section. The table also holds every long-branch veneer. So the cost is
   O(S × N), single-threaded, whether or not any erratum site exists. Here none
   exists: 0 erratum stubs were created. A profile of the slow case
   (`profile-case.sh fixed keep`) shows 30 of 30 stack samples in that walk.
   For contrast, the 32-bit Arm backend keeps its erratum veneers in per-section
   lists (`elf32_arm_write_section` walks `arm_data->erratumlist`).
2. **Large Rust binaries have both a large S and a large N.** rustc emits one
   `.text.*` section per function. Once `.text` exceeds `BL`'s ±128 MiB range, the
   linker needs a veneer for many out-of-range calls.
3. **binutils 2.33 through 2.47 run the walk even when the fix is off.** Since
   binutils 2.33 (PR ld/24373), `fix_erratum_843419` is an enum whose "off" value
   is `ERRAT_NONE = 1`. So `if (globals->fix_erratum_843419)` is always true
   (`stock/strip`, `system/strip`). This is fixed on master by commit
   [6e72ff2](https://inbox.sourceware.org/binutils/20260806054354.27168-1-ktkachov@nvidia.com/)
   ("aarch64: ERRAT_NONE is not zero, so test against it"), which is not yet in a
   release. With that fix, turning the workaround off takes the link from 82.9 s
   to 1.3 s (`fixed/strip`).
4. **Since Rust 1.98, users cannot turn the workaround off.**
   [rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453) adds
   `-Wl,--fix-cortex-a53-843419` to `pre_link_args` for the AArch64 Linux targets.
   GNU ld has no `--no-fix-cortex-a53-843419`, and the driver option
   `-mno-fix-cortex-a53-843419` does not cancel a `-Wl,` argument
   (`fixed/optout`). The PR discussion noted this, and expected the cost to be
   negligible because the erratum rarely occurs. With GNU ld, the cost does not
   depend on how often the erratum occurs.
5. **The regression is in the opt-out, not in the default, on distros whose gcc
   already enables the fix.** Debian's gcc is configured with
   `--enable-fix-cortex-a53-843419` (`check-gcc-default.sh`), so Rust 1.97 on
   Debian already asked ld for the fix. What 1.98 removed is the escape hatch:
   `-C link-arg=-mno-fix-cortex-a53-843419` worked on 1.97 and no longer does on 1.98.
   On toolchains whose gcc does *not* enable it by default (for example the Arm
   GNU toolchain cited in the PR), 1.98 also changes the default.

## The workload

`crates/repro-gen/build.rs` generates, in one codegen unit, in this order:

- `REPRO_CALLERS` callers, `a_call_i() -> z_targ_i()`;
- `REPRO_PAD_MIB` never-executed 1 MiB functions (`asm!(".space 1048576")`) that
  push the targets more than 128 MiB away;
- `REPRO_CALLERS` targets;
- optionally, `REPRO_FILLERS` leaf functions.

Functions are named so that rustc's deterministic item order equals this layout.
`crates/repro/src/main.rs` calls every caller through its veneer and checks the
sum, so each linked binary is verified to run correctly.

## Running it

```sh
./run.sh                                 # build image, 40k-caller matrix, scaling sweep
REPRO_CALLERS=20000 SWEEP=0 ./run.sh     # quicker: matrix only
docker build --build-arg RUST_IMAGE=rust:1.97-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97 \
  -t a53-ld-repro:rust-1.97 .
docker run --rm a53-ld-repro:rust-1.97 ./run-cases.sh fixed/keep fixed/optout
./profile-case.sh fixed keep 40000 30    # stack samples of the running ld
```

Cases are `<ld>/<a53>`, handled by the `repro-cc` linker wrapper:

- `<ld>` is one of `fixed`, `stock`, `system` or `lld`.
- `<a53>` is one of:
  - `keep`: rustc's arguments unchanged.
  - `strip`: drop rustc's flag and pass `-mno-fix-...`, so neither rustc nor gcc asks for the fix.
  - `optout`: keep rustc's arguments and add `-mno-fix-...`, which is what a user can do today.
- The wrapper records, via `cc -###`, whether ld actually receives `--fix-cortex-a53-843419`.

Timings: image build about 2 min, matrix about 8 min, sweep about 15 min on 64 vCPU.

## Provenance

- Base images, pinned by digest in the `Dockerfile`: `rust:1.98-bookworm` (rustc
  1.98.1) and, for the comparison, `rust:1.97-bookworm`.
- binutils: `binutils-2.47.tar.xz` from ftp.gnu.org, sha256 `154ab23b…4cff`,
  built twice: stock, and with `binutils-errat-none-fix.patch`, which is upstream
  commit 6e72ff251801 verbatim.
- System linker: Debian bookworm binutils 2.40. lld: Debian LLD 14.0.6.
- Raw per-link logs: `results/link.log`. Environment: `results/env.txt`.

## Real-world data point

A production Rust test binary (debug, about 5.15M input sections, 565 MB `.text`,
38,435 veneers) took about 71 minutes per link with GNU ld on Graviton, and 4 s
with mold. The same S × N walk accounted for all stack samples.
