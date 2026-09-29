# GNU ld + `--fix-cortex-a53-843419`: link time scales as sections × stubs on AArch64

A self-contained Docker reproducer. It shows that on AArch64, GNU ld's Cortex-A53
erratum 843419 pass costs time proportional to **(input sections) × (linker
stubs)**, even when no erratum site exists. It also shows that since Rust 1.98
([rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453)) there is
no way to turn the pass off from `rustc`/Cargo.

On the workload below, a GNU ld patched so that the pass can be turned off links
in **1.3 s** with it off and **79.7 s** with it on. The user opt-out
`-C link-arg=-mno-fix-cortex-a53-843419` turns it off on Rust 1.97 (1.3 s), but not
on Rust 1.98 (83.0 s).

## Methodology

### Requirements

- **An aarch64 (arm64) Linux host.** The workload is built and linked natively for
  `aarch64-unknown-linux-gnu`, and the binaries are run to check them. Running on
  x86-64 under emulation has not been tested.
- **Docker** with BuildKit (the default builder since Docker 23). Tested with Docker 25.
- **Network access** during the image builds, to Docker Hub, the Debian package
  mirrors and `ftp.gnu.org` (falling back to `ftpmirror.gnu.org`).
- **Disk:** about 2 GB per built image (two images), plus the Cargo target
  directory inside each running container.
- **Time:** on 64 vCPU, a full `./run.sh` takes about 45 minutes: two image
  builds, two 12-case matrices, two profiles and the scaling sweep. Links are
  single-threaded, so fewer cores mostly slows the image builds and the one-off
  compile.

Results below are from an AWS Graviton3 instance (Neoverse V1, 64 vCPU).

### Provenance

Every input is public and pinned:

- **Base images:** the official Docker Hub `rust:1.98-bookworm` (rustc 1.98.1) and
  `rust:1.97-bookworm` (rustc 1.97), both Debian bookworm and both pinned by digest
  in `run.sh`. `results/base-image*.txt` and `results/image-id*.txt` record what was used.
- **GNU binutils 2.47:** the release tarball `binutils-2.47.tar.xz`, sha256
  `154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff`, which is
  checked in the `Dockerfile`. It is built twice inside each image, installing
  only `ld`:
  - `/opt/binutils-stock`: unmodified.
  - `/opt/binutils-patched`: with `binutils-errat-none-fix.patch` applied. That's
    upstream binutils master commit 6e72ff251801 ("aarch64: ERRAT_NONE is not zero,
    so test against it"), vendored verbatim with its origin noted in the file.
    It is not yet in any binutils release.
- **Debian's GNU ld:** binutils 2.40, as shipped in the base images.
- **lld:** Debian bookworm's LLD 14.0.6 package.

`results/env.txt` and `results/rust-1.97/env.txt` record the tool versions seen at
run time.

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

No code in the workload is shaped to trigger erratum 843419, and no linker
created an erratum stub in any run (`erratum_stubs` in `results/*summary.txt`).
So whatever the erratum pass costs here is overhead, not patching.

`crates/repro/src/main.rs` calls every caller, through its veneer, and checks the
sum. Each linked binary is run, and every result below printed `ok=true`.

### Cases

Each case is named `<linker>/<request>`. `.cargo/config.toml` sets the `repro-cc`
wrapper as rustc's linker driver, and two environment variables select the case.

**`REPRO_LD`: which linker gcc runs**

| value | linker | why it's here |
|---|---|---|
| `patched` | GNU ld 2.47 + upstream commit 6e72ff2 (`/opt/binutils-patched`, via `gcc -B`) | The only GNU ld that skips the erratum pass when it isn't asked for, so it isolates the cost of the flag. |
| `stock` | GNU ld 2.47 release (`/opt/binutils-stock`, via `gcc -B`) | The same source without the patch: the latest release. |
| `debian` | Debian bookworm's GNU ld 2.40, unmodified | What a user of this image gets out of the box. Also GNU ld, also without the patch. |
| `lld` | LLD 14 (`-fuse-ld=lld`) | A linker that implements the same workaround differently, for comparison. |

**`REPRO_A53`: what is done about the erratum flag**

| value | what the wrapper does | what it represents |
|---|---|---|
| `keep` | Passes rustc's link arguments through unchanged. On Rust 1.98 they include `-Wl,--fix-cortex-a53-843419`. | A default `cargo build`. |
| `optout` | Keeps rustc's arguments and appends `-mno-fix-cortex-a53-843419`. | The only opt-out a user has, `-C link-arg=-mno-fix-cortex-a53-843419`. |
| `strip` | Removes `-Wl,--fix-cortex-a53-843419` from rustc's arguments (including inside `@` response files) and adds `-mno-fix-cortex-a53-843419`. | Nothing asks ld for the erratum fix. Both steps are needed, because Debian's gcc adds the flag itself by default (`check-gcc-default.sh`). |

On Rust 1.97, rustc passes no flag of its own, so `strip` and `optout` do the same
thing there.

### What the result columns mean

- **ld given the flag:** whether ld's own command line contains
  `--fix-cortex-a53-843419`. The wrapper checks this for every link by dry-running
  the gcc driver with `cc -###` (column `ld_gets_fix` in the raw summaries).
- **Erratum pass runs:** whether GNU ld executes the per-section erratum-843419
  pass (see [Explanation](#explanation)). It runs when ld is given the flag, **or**
  when ld lacks commit 6e72ff2: unpatched GNU ld runs it whether or not it is
  given the flag. So it is "no" only for `patched/strip` (and `patched/optout` on
  Rust 1.97). This column comes from the source; the stack profiles
  (`results/profile-*.txt`) confirm it for `patched/keep` (flag given) and for
  `stock/strip` (flag not given). In both, all 30 samples are in the pass. For
  lld the column is "lld's": lld applies its own implementation of the fix
  whenever it's given the flag.
- **Link time:** the wall-clock time of the wrapper's single `cc` invocation,
  which runs gcc, collect2 and the linker.

### Measurement

- The workload is compiled once (linked with lld, so the one-off compile isn't
  slowed down). Each case then touches `main.rs` and relinks, so only the link
  changes between cases.
- **Veneers** are counted from the symbol table of the linked binary. GNU ld names
  them `__<symbol>_veneer`, and lld `__AArch64*Thunk_<symbol>`.
- Each case and each sweep point was run once. Run-to-run variance was not
  measured, beyond comparing with an earlier run of the same cases, which agreed
  to within about 5%.

Per-link records are in `results/link.log` and `results/rust-1.97/link.log`.

### Running it

```sh
./run.sh                                       # everything, about 45 min on 64 vCPU
REPRO_CALLERS=20000 RUST197=0 PROFILE=0 SWEEP=0 ./run.sh   # quick: Rust 1.98 matrix only
```

Individual pieces, once the images are built:

```sh
docker run --rm a53-ld-repro ./run-cases.sh patched/strip patched/keep   # chosen cases
docker run --rm a53-ld-repro ./run-sweep.sh 20000:0 40000:0              # chosen sweep points
./profile-case.sh stock strip 40000 30                                   # stack samples of the running ld
```

## Results

Both matrices use `REPRO_CALLERS=40000`: 162 MiB `.text`, about 80k input sections
from the generated crate, and 40,178 veneers with GNU ld (40,021 with lld).

### Case matrix, Rust 1.98.1

rustc passes `-Wl,--fix-cortex-a53-843419` on every link.

| case | ld given the flag | erratum pass runs | **link time** |
|---|---|---|---|
| `patched/strip` | no | **no** | **1.3 s** |
| `patched/keep` | yes | yes | **79.7 s** |
| `patched/optout` | yes (rustc's `-Wl,` wins over `-mno-fix`) | yes | **83.0 s** |
| `stock/strip` | no | yes (unpatched) | 82.3 s |
| `stock/keep` | yes | yes | 79.4 s |
| `stock/optout` | yes | yes | 81.2 s |
| `debian/strip` | no | yes (unpatched) | 61.4 s |
| `debian/keep` | yes | yes | 63.1 s |
| `debian/optout` | yes | yes | 61.3 s |
| `lld/strip` | no | no | 0.2 s |
| `lld/keep` | yes | lld's | 0.3 s |
| `lld/optout` | yes | lld's | 0.3 s |

### Case matrix, Rust 1.97

rustc passes no flag. In `keep`, the flag comes from Debian's gcc, which is
configured with `--enable-fix-cortex-a53-843419`.

| case | ld given the flag | erratum pass runs | **link time** |
|---|---|---|---|
| `patched/strip` | no | **no** | **1.3 s** |
| `patched/keep` | yes (gcc default) | yes | 70.6 s |
| `patched/optout` | **no: the opt-out works** | **no** | **1.3 s** |
| `stock/strip` | no | yes (unpatched) | 70.5 s |
| `stock/keep` | yes (gcc default) | yes | 72.0 s |
| `stock/optout` | no | yes (unpatched) | 68.4 s |
| `debian/strip` | no | yes (unpatched) | 60.1 s |
| `debian/keep` | yes (gcc default) | yes | 60.9 s |
| `debian/optout` | no | yes (unpatched) | 61.3 s |
| `lld/strip` | no | no | 0.2 s |
| `lld/keep` | yes (gcc default) | lld's | 0.3 s |
| `lld/optout` | no | no | 0.2 s |

What changed between the two tables is `patched/optout`. The same user opt-out,
`-C link-arg=-mno-fix-cortex-a53-843419`, gives **1.3 s on Rust 1.97 and 83.0 s on
Rust 1.98**. In every other row both versions agree on whether the pass runs; the
slow GNU ld links are 10-20% slower on the Rust 1.98 image, which we have not
investigated. Unpatched GNU ld is slow on both versions whatever is passed.

### Scaling, Rust 1.98.1

Patched GNU ld, so that the erratum pass is the only difference between the two
time columns. `CALLERS` raises both N and S; `FILLERS` raises only S.

| callers | fillers | veneers (N) | `patched/strip` (pass off) | `patched/keep` (pass on) | slowdown |
|---|---|---|---|---|---|
| 5,000 | 0 | 5,178 | 0.5 s | 1.5 s | 3× |
| 10,000 | 0 | 10,178 | 0.6 s | 4.4 s | 7.3× |
| 20,000 | 0 | 20,178 | 0.8 s | 17.0 s | 21× |
| 40,000 | 0 | 40,178 | 1.4 s | 80.6 s | 58× |
| 80,000 | 0 | 80,178 | 2.4 s | 343.3 s | 143× |
| 20,000 | 40,000 | 20,178 | 1.3 s | 32.6 s | 25× |
| 20,000 | 160,000 | 20,178 | 2.7 s | 85.4 s | 32× |

- Doubling `CALLERS`, which doubles both S and N, multiplies the extra time
  (pass on minus pass off) by about 4-5×.
- At fixed N, adding `FILLERS` grows the extra time roughly linearly in S: about
  2× for twice the sections and 5× for five times the sections.
- That is the S × N shape. The extra time works out to about 25 ns per
  (section, stub) pair.

## Explanation

This is our reading of the binutils and rustc sources, consistent with the
results above.

1. **GNU ld's 843419 pass walks every stub, for every input section.**
   `bfd_elf_final_link` → `elf_link_input_bfd` calls the backend
   `write_section` hook once per input section. On AArch64,
   `elfNN_aarch64_write_section` then runs
   `bfd_hash_traverse(&globals->stub_hash_table, _bfd_aarch64_erratum_843419_branch_to_stub, …)`
   over the **entire** stub table, to find the few erratum stubs that belong to
   that one section. The table also holds every long-branch veneer. So the cost is
   O(S × N), single-threaded, whether or not any erratum site exists; here none
   does. The profiles put every sample in that walk. For contrast, the 32-bit Arm
   backend keeps its erratum veneers in per-section lists
   (`elf32_arm_write_section` walks `arm_data->erratumlist`).
2. **Large Rust binaries have both a large S and a large N.** rustc emits one
   `.text.*` section per function. Once `.text` exceeds `BL`'s ±128 MiB range, the
   linker needs a veneer for many out-of-range calls.
3. **binutils 2.33 through 2.47 run the pass even when it is not requested.**
   Since binutils 2.33 (PR ld/24373), `fix_erratum_843419` is an enum whose "off"
   value is `ERRAT_NONE = 1`. So `if (globals->fix_erratum_843419)` is always true
   (`stock/strip`, `debian/strip`). This is fixed on master by commit
   [6e72ff2](https://inbox.sourceware.org/binutils/20260806054354.27168-1-ktkachov@nvidia.com/),
   which is not yet in a release. With that fix, not requesting the pass takes the
   link from 79.7 s to 1.3 s (`patched/strip`).
4. **Since Rust 1.98, users cannot stop rustc from requesting the pass.**
   [rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453) adds
   `-Wl,--fix-cortex-a53-843419` to `pre_link_args` for the AArch64 Linux targets.
   GNU ld has no `--no-fix-cortex-a53-843419`, and the driver option
   `-mno-fix-cortex-a53-843419` does not cancel a `-Wl,` argument
   (`patched/optout`). The PR discussion noted this, and expected the cost to be
   negligible because the erratum rarely occurs. With GNU ld, the cost does not
   depend on how often the erratum occurs.
5. **On distros whose gcc already enables the fix, the regression is in the
   opt-out, not the default.** Debian's gcc is configured with
   `--enable-fix-cortex-a53-843419`, so Rust 1.97 on Debian already asked ld for the
   fix (`keep` rows of the Rust 1.97 table). What 1.98 removed is the escape hatch:
   `-C link-arg=-mno-fix-cortex-a53-843419` worked on 1.97 and no longer does on
   1.98. On toolchains whose gcc does *not* enable it by default (for example the
   Arm GNU toolchain cited in the PR), 1.98 also changes the default.

## Real-world data point

A production Rust test binary (debug, about 5.15M input sections, 565 MB `.text`,
38,435 veneers) took about 71 minutes per link with GNU ld on Graviton, and 4 s
with mold. The same S × N walk accounted for all stack samples.
