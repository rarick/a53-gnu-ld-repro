# GNU ld + `--fix-cortex-a53-843419`: link time scales as sections × stubs on AArch64

A self-contained Docker reproducer. It shows that on AArch64, GNU ld's Cortex-A53
erratum 843419 workaround costs time proportional to **(input sections) × (linker
stubs)**, even when no erratum site exists. It also shows that since Rust 1.98
([rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453)) there is
no way to turn the workaround off from `rustc`/Cargo.

On the workload below, patched GNU ld links in **1.3 s** without the workaround
and **82.9 s** with it. Rust 1.97 users could opt out of the workaround; Rust 1.98
users cannot.

## Methodology

### Requirements

- **An aarch64 (arm64) Linux host.** The workload is built and linked natively for
  `aarch64-unknown-linux-gnu`, and the binaries are run to check them. Running on
  x86-64 under emulation has not been tested.
- **Docker** with BuildKit (the default builder since Docker 23). Tested with Docker 25.
- **Network access** during the image build, to Docker Hub, the Debian package
  mirrors and `ftp.gnu.org`.
- **Disk:** about 2 GB per built image, plus the Cargo target directory inside
  the running container.
- **Time:** on 64 vCPU, the image build takes about 2 min, the case matrix about
  8 min and the scaling sweep about 15 min. Links are single-threaded, so fewer
  cores mostly slows the image build and the one-off compile.

Results below are from an AWS Graviton3 instance (Neoverse V1, 64 vCPU).

### Provenance

Every input is public and pinned:

- **Base image:** the official Docker Hub `rust:1.98-bookworm` (rustc 1.98.1,
  Debian bookworm), pinned by digest in the `Dockerfile`. `rust:1.97-bookworm`,
  also pinned by digest, is used for the before-#155453 comparison.
- **GNU binutils 2.47:** the release tarball `binutils-2.47.tar.xz` from
  `ftp.gnu.org`, sha256 `154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff`.
  It is built twice inside the image, installing only `ld`:
  - `/opt/binutils-stock`: unmodified.
  - `/opt/binutils-fixed`: with `binutils-errat-none-fix.patch` applied. That's
    upstream binutils master commit 6e72ff251801 ("aarch64: ERRAT_NONE is not zero,
    so test against it"), vendored verbatim with its origin noted in the file.
    It is not yet in any binutils release.
- **System linker:** Debian bookworm's binutils 2.40, as shipped in the base image.
- **lld:** Debian bookworm's LLD 14.0.6 package.

`results/env.txt` records the exact tool versions seen at run time;
`results/base-image.txt` and `results/image-id.txt` record the image digests.

### Workload

`crates/repro-gen/build.rs` generates one crate, compiled into a single codegen
unit, containing, in this order:

1. `REPRO_CALLERS` caller functions, `a_call_i() -> z_targ_i()`.
2. `REPRO_PAD_MIB` never-executed 1 MiB functions (`asm!(".space 1048576")`),
   default 160. These push the targets more than 128 MiB away from the callers,
   which is beyond the ±128 MiB range of an AArch64 `BL`.
3. `REPRO_CALLERS` target functions.
4. Optionally, `REPRO_FILLERS` leaf functions that need no veneer.

rustc gives each function its own `.text.*` section, and emits items in a
deterministic order; the function names are chosen so that this order matches
the layout above. As a result:

- every caller needs one long-branch veneer (stub), so **N ≈ `REPRO_CALLERS`**;
- each caller and target is its own input section, so **S ≈ 2 × `REPRO_CALLERS` +
  `REPRO_FILLERS`**, plus the padding and the standard library.

No code in the workload is shaped to trigger erratum 843419, so every linker
creates zero erratum stubs. Whatever the workaround costs here is overhead, not
patching.

`crates/repro/src/main.rs` calls every caller, through its veneer, and checks the
sum. Each linked binary is run, and every result below printed `ok=true`.

### Cases

Each case is named `<linker>/<workaround>`. `.cargo/config.toml` sets the
`repro-cc` wrapper as rustc's linker driver, and two environment variables select
the case:

**`REPRO_LD`: which linker gcc runs**

| value | linker |
|---|---|
| `fixed` | GNU ld 2.47 + upstream fix 6e72ff2 (`/opt/binutils-fixed`, via `gcc -B`) |
| `stock` | GNU ld 2.47 release (`/opt/binutils-stock`, via `gcc -B`) |
| `system` | Debian bookworm's GNU ld 2.40 |
| `lld` | LLD 14 (`-fuse-ld=lld`) |

**`REPRO_A53`: how the 843419 workaround is requested**

| value | what the wrapper does | what it represents |
|---|---|---|
| `keep` | Passes rustc's link arguments through unchanged. On Rust 1.98 they include `-Wl,--fix-cortex-a53-843419`. | A default `cargo build`. |
| `optout` | Keeps rustc's arguments and appends `-mno-fix-cortex-a53-843419`. | The only opt-out a user has, `-C link-arg=-mno-fix-cortex-a53-843419`. |
| `strip` | Removes `-Wl,--fix-cortex-a53-843419` from rustc's arguments (including inside `@` response files) and adds `-mno-fix-cortex-a53-843419`. | A link where nothing asks for the workaround. Both are needed, because Debian's gcc adds the flag itself by default (`check-gcc-default.sh`). |

For every link, the wrapper dry-runs the gcc driver with `cc -###` to see whether
ld itself will receive `--fix-cortex-a53-843419`. That's the "does ld get the
flag?" column below. It shows what the linker was actually asked to do, rather
than what was intended.

### Measurement

- The workload is compiled once (linked with lld, so the one-off compile isn't
  slowed down). Each case then touches `main.rs` and relinks, so only the link
  changes between cases.
- **Link time** is the wall-clock time of the wrapper's single `cc` invocation,
  which runs gcc, collect2 and the linker.
- **Veneers** are counted from the symbol table of the linked binary. GNU ld names
  them `__<symbol>_veneer`, and lld `__AArch64*Thunk_<symbol>`.
- Each case and each sweep point was run once. Run-to-run variance was not measured.

Per-link records are in `results/link.log`; per-case results are in
`results/summary.txt`, `results/sweep.txt` and `results/rust-1.97-final/summary.txt`.

### Running it

```sh
./run.sh                                 # build image, 40k-caller case matrix, scaling sweep
REPRO_CALLERS=20000 SWEEP=0 ./run.sh     # quicker: case matrix only
```

Rust 1.97 comparison:

```sh
docker build --build-arg RUST_IMAGE=rust:1.97-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97 \
  -t a53-ld-repro:rust-1.97 .
docker run --rm a53-ld-repro:rust-1.97 ./run-cases.sh fixed/strip fixed/keep fixed/optout system/keep lld/keep
```

Profile of the slow case, as 30 stack samples of the running ld:

```sh
./profile-case.sh fixed keep 40000 30
```

`run-cases.sh <case> ...` and `run-sweep.sh <CALLERS:FILLERS> ...` run inside the
container and accept explicit cases or sweep points.

## Results

### Case matrix, Rust 1.98.1

`REPRO_CALLERS=40000`: 162 MiB `.text`, about 80k input sections from the
generated crate, and 40,178 veneers with GNU ld (40,021 with lld).

| case | linker | workaround | does ld get the flag? | **link time** |
|---|---|---|---|---|
| `fixed/strip` | GNU ld 2.47 + 6e72ff2 | not requested | no | **1.3 s** |
| `fixed/keep` | GNU ld 2.47 + 6e72ff2 | rustc default | yes | **82.9 s** |
| `fixed/optout` | GNU ld 2.47 + 6e72ff2 | rustc default + user opt-out | yes (rustc's `-Wl,` wins) | **84.6 s** |
| `stock/strip` | GNU ld 2.47 | not requested | no | 82.5 s |
| `stock/keep` | GNU ld 2.47 | rustc default | yes | 81.4 s |
| `system/strip` | Debian ld 2.40 | not requested | no | 61.4 s |
| `system/keep` | Debian ld 2.40 | rustc default | yes | 61.6 s |
| `lld/strip` | LLD 14 | not requested | no | 0.2 s |
| `lld/keep` | LLD 14 | rustc default | yes, and applied | 0.3 s |

### Case matrix, Rust 1.97

Same workload. Rust 1.97 does not add the flag itself, but Debian's gcc does,
because it's configured with `--enable-fix-cortex-a53-843419`.

| case | linker | does ld get the flag? | link time |
|---|---|---|---|
| `fixed/strip` | GNU ld 2.47 + 6e72ff2 | no | 1.3 s |
| `fixed/keep` | GNU ld 2.47 + 6e72ff2 | yes (gcc default) | 67.8 s |
| `fixed/optout` | GNU ld 2.47 + 6e72ff2 | **no: the opt-out works on 1.97** | **1.3 s** |
| `system/keep` | Debian ld 2.40 | yes (gcc default) | 62.4 s |
| `lld/keep` | LLD 14 | yes | 0.3 s |

The same user opt-out, `-C link-arg=-mno-fix-cortex-a53-843419`, gives
**1.3 s on Rust 1.97 and 84.6 s on Rust 1.98**.

### Scaling, Rust 1.98.1

Patched GNU ld (`fixed`). The two time columns are `fixed/strip` and
`fixed/keep`, so the workaround is the only difference between them. `CALLERS`
raises both N and S; `FILLERS` raises only S.

| callers | fillers | veneers (N) | no workaround | with workaround | slowdown |
|---|---|---|---|---|---|
| 5,000 | 0 | 5,178 | 0.5 s | 1.5 s | 3× |
| 10,000 | 0 | 10,178 | 0.6 s | 4.5 s | 7.5× |
| 20,000 | 0 | 20,178 | 0.8 s | 17.3 s | 22× |
| 40,000 | 0 | 40,178 | 1.3 s | 85.9 s | 66× |
| 80,000 | 0 | 80,178 | 2.4 s | 332.2 s | 138× |
| 20,000 | 40,000 | 20,178 | 1.3 s | 33.4 s | 26× |
| 20,000 | 160,000 | 20,178 | 2.6 s | 85.7 s | 33× |

- Doubling `CALLERS`, which doubles both S and N, roughly quadruples the extra time.
- Adding `FILLERS` at fixed N grows the extra time roughly linearly in S.
- That's the S × N shape. The extra time works out to about 25 ns per
  (section, stub) pair.

## Explanation

This is our reading of the binutils and rustc sources, consistent with the
results above.

1. **GNU ld's 843419 workaround walks every stub, for every input section.**
   `bfd_elf_final_link` → `elf_link_input_bfd` calls the backend
   `write_section` hook once per input section. On AArch64,
   `elfNN_aarch64_write_section` then runs
   `bfd_hash_traverse(&globals->stub_hash_table, _bfd_aarch64_erratum_843419_branch_to_stub, …)`
   over the **entire** stub table, to find the few erratum stubs that belong to
   that one section. The table also holds every long-branch veneer. So the cost is
   O(S × N), single-threaded, whether or not any erratum site exists; here none
   does. A profile of the slow case (`profile-case.sh fixed keep`) put 30 of 30
   stack samples in that walk. For contrast, the 32-bit Arm backend keeps its
   erratum veneers in per-section lists (`elf32_arm_write_section` walks
   `arm_data->erratumlist`).
2. **Large Rust binaries have both a large S and a large N.** rustc emits one
   `.text.*` section per function. Once `.text` exceeds `BL`'s ±128 MiB range, the
   linker needs a veneer for many out-of-range calls.
3. **binutils 2.33 through 2.47 run the walk even when the workaround is off.**
   Since binutils 2.33 (PR ld/24373), `fix_erratum_843419` is an enum whose "off"
   value is `ERRAT_NONE = 1`. So `if (globals->fix_erratum_843419)` is always true
   (`stock/strip`, `system/strip`). This is fixed on master by commit
   [6e72ff2](https://inbox.sourceware.org/binutils/20260806054354.27168-1-ktkachov@nvidia.com/),
   which is not yet in a release. With that fix, turning the workaround off takes
   the link from 82.9 s to 1.3 s (`fixed/strip`).
4. **Since Rust 1.98, users cannot turn the workaround off.**
   [rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453) adds
   `-Wl,--fix-cortex-a53-843419` to `pre_link_args` for the AArch64 Linux targets.
   GNU ld has no `--no-fix-cortex-a53-843419`, and the driver option
   `-mno-fix-cortex-a53-843419` does not cancel a `-Wl,` argument
   (`fixed/optout`). The PR discussion noted this, and expected the cost to be
   negligible because the erratum rarely occurs. With GNU ld, the cost does not
   depend on how often the erratum occurs.
5. **On distros whose gcc already enables the workaround, the regression is in
   the opt-out, not the default.** Debian's gcc is configured with
   `--enable-fix-cortex-a53-843419`, so Rust 1.97 on Debian already asked ld for
   the workaround. What 1.98 removed is the escape hatch:
   `-C link-arg=-mno-fix-cortex-a53-843419` worked on 1.97 and no longer does on
   1.98. On toolchains whose gcc does *not* enable it by default (for example the
   Arm GNU toolchain cited in the PR), 1.98 also changes the default.

## Real-world data point

A production Rust test binary (debug, about 5.15M input sections, 565 MB `.text`,
38,435 veneers) took about 71 minutes per link with GNU ld on Graviton, and 4 s
with mold. The same S × N walk accounted for all stack samples.
