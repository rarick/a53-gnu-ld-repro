# GNU ld's Cortex-A53 843419 pass on AArch64: 4× slower links for large Rust binaries, and no opt-out since Rust 1.98

On AArch64 Linux, GNU ld's Cortex-A53 erratum 843419 pass costs time proportional
to **(input sections) × (linker stubs)**, even when the binary contains no erratum
site at all. Large Rust binaries have plenty of both. Since Rust 1.98
([rust-lang/rust#155453](https://github.com/rust-lang/rust/pull/155453)), rustc
requests the pass on every link and there is no way to turn it off from
`rustc`/Cargo.

**[Deno](https://github.com/denoland/deno), unmodified, plain `cargo build`
(debug), Graviton3:**

| | Rust 1.97.1 | Rust 1.98.1 |
|---|---|---|
| GNU ld, erratum pass off | 32.5 s | 32.8 s |
| GNU ld, default arguments | 136.6 s | 139.9 s |
| GNU ld, default + `-C link-arg=-mno-fix-cortex-a53-843419` | **32.6 s** | **144.5 s** |

That's about 105 extra seconds on every relink of the `deno` binary, i.e. on every
edit-rebuild cycle. On Rust 1.97, gcc's opt-out (`-C link-arg=-mno-fix-cortex-a53-843419`)
removes it; on Rust 1.98 it no longer does. "GNU ld" here is GNU ld 2.47 plus an
upstream fix that lets the pass be turned off at all ([below](#explanation)).
Released GNU ld (2.33 through 2.47) runs the pass whether or not it is requested;
once a release includes that fix, rustc's flag is what keeps the pass on, with no
opt-out.

The repository has three parts:

- **Deno** ([`real-world/`](real-world/)): the headline measurement above.
- **Four other popular projects** (same scripts): how far the effect reaches.
  Binaries below ~128 MiB of `.text` need no stubs and pay a much smaller cost.
- **A synthetic crate** ([`crates/`](crates/)): not a real-world case, but a way
  to vary sections and stubs independently, to show the S × N scaling and to
  isolate each linker and flag combination.

## Methodology

### Requirements

- **An aarch64 (arm64) Linux host.** Everything is built and linked natively for
  `aarch64-unknown-linux-gnu`. Running on x86-64 under emulation has not been tested.
- **Docker** with BuildKit (the default builder since Docker 23). Tested with Docker 25.
- **Network access** during the image builds and project builds, to Docker Hub,
  the Debian package mirrors, `sourceware.org` (falling back to `ftp.gnu.org` and
  `ftpmirror.gnu.org`), GitHub and crates.io.
- **Disk:** about 2 GB per image (four images), plus about 65 GB of Cargo target
  directories and checkouts under `real-world/work` and `real-world/src`, most of
  it the two Deno debug builds.
- **Time:** on 64 vCPU, a full `./run.sh` takes about 1.5-2 hours: about 40
  minutes for Deno, 15 for the other projects and 45 for the synthetic workload.
  Links are single-threaded, so fewer cores mostly slows the compiles.

All results are from an AWS Graviton3 instance (Neoverse V1, 64 vCPU).

### Provenance

Every input is public and pinned:

- **Base images:** the official Docker Hub `rust:1.98-bookworm` (rustc 1.98.1) and
  `rust:1.97-bookworm` (rustc 1.97.1), both Debian bookworm and both pinned by
  digest in `run.sh`. `results/base-image*.txt` and `results/image-id*.txt` record
  what was used.
- **GNU binutils 2.47:** the release tarball `binutils-2.47.tar.xz`, sha256
  `154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff`, downloaded
  from sourceware.org or ftp.gnu.org and checked in the `Dockerfile`. It is built
  twice inside each image, installing only `ld`:
  - `/opt/binutils-stock`: unmodified.
  - `/opt/binutils-patched`: with `binutils-errat-none-fix.patch` applied. That's
    upstream binutils master commit 6e72ff251801 ("aarch64: ERRAT_NONE is not zero,
    so test against it"), vendored verbatim with its origin noted in the file.
    It is not yet in any binutils release.
- **Debian's GNU ld:** binutils 2.40, as shipped in the base images.
- **lld:** Debian bookworm's LLD 14.0.6 package.
- **Real-world projects:** cloned from GitHub at the commits in
  `real-world/projects.txt` (Deno at `1b48a20`, 2026-09-28), unmodified. Their
  build dependencies (cmake, clang, protobuf-compiler and a few `-dev` packages)
  come from Debian, via `real-world/Dockerfile`.

Each results directory has an `env.txt` with the tool versions (and, for the
projects, the commit) seen at run time.

### Cases

Every measurement is one link, run through the `repro-cc` wrapper, which rustc
uses as its linker driver. Two environment variables select the case, named
`<linker>/<request>`.

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
  the gcc driver with `cc -###` (column `ld_gets_fix` in the raw summaries: the
  number of times it appears).
- **Erratum pass runs:** whether GNU ld executes the per-section erratum-843419
  pass (see [Explanation](#explanation)). It runs when ld is given the flag, **or**
  when ld lacks commit 6e72ff2: unpatched GNU ld runs it whether or not it is
  given the flag. So among the GNU ld cases it is "no" only for `patched/strip`,
  and for `patched/optout` on Rust 1.97. This column comes from the source. The
  stack profiles (`results/profile-*.txt`, synthetic workload) confirm it for
  `patched/keep` (flag given) and for `stock/strip` (flag not given): in both,
  all 30 samples are in the pass. For lld the column reads "lld's": lld applies
  its own implementation of the fix whenever it is given the flag.
- **Link time:** the wall-clock time of the wrapper's single `cc` invocation,
  which runs gcc, collect2 and the linker.
- **Veneers:** long-branch stubs, counted from the linked binary's symbol table.
  GNU ld names them `__<symbol>_veneer`, and lld `__AArch64*Thunk_<symbol>`.

### Real-world workload

`real-world/run-project.sh` runs inside the container, for each project in
`real-world/projects.txt`:

1. `cargo build -p <package> --bin <bin>` with the default dev profile, linked with
   lld so that the one-off full build isn't slowed down. Nothing about the project
   is changed. Its `rust-toolchain.toml`, if any, is overridden so that the image's
   rustc is used.
2. For each case: touch the binary's root source file (`cli/main.rs` for Deno)
   and run the same `cargo build` again. Cargo recompiles that one crate
   incrementally and relinks; no dependency is rebuilt, because `REPRO_LD` and
   `REPRO_A53` are not part of Cargo's fingerprint. This is the ordinary
   edit-rebuild loop, and the recorded time is that relink.

Deno runs on both Rust versions; the other projects run on Rust 1.98 only
(`ALL_197=1` adds 1.97).

### Synthetic workload

The synthetic crate lets S and N be set independently, which no real project
allows. It is shaped to need many stubs, not to trigger the erratum.

`crates/repro-gen/build.rs` generates one crate, compiled into a single codegen
unit. In the linked binary its functions appear in this order:

1. `REPRO_CALLERS` caller functions, `a_call_i() -> z_targ_i()`.
2. Optionally, `REPRO_FILLERS` leaf functions, `b_fill_i()`, which need no veneer.
3. `REPRO_PAD_MIB` never-executed 1 MiB functions, `m_padd_i()`
   (`asm!(".space 1048576")`), default 160. These stand in for 160 MiB of other
   code: they push the targets more than 128 MiB away from the callers, beyond
   the ±128 MiB range of an AArch64 `BL`.
4. `REPRO_CALLERS` target functions, `z_targ_i()`.

rustc gives each function its own `.text.*` section. It emits these functions in
name order rather than source order, which is what the `a_`, `b_`, `m_` and `z_`
prefixes are for; `nm -n` on the linked binary shows the layout. As a result:

- every caller needs one long-branch veneer (stub), so **N ≈ `REPRO_CALLERS`**;
- each caller and target is its own input section, so **S ≈ 2 × `REPRO_CALLERS` +
  `REPRO_FILLERS`**, plus the padding and the standard library.

No linker created an erratum stub in any synthetic run (`erratum_stubs` in
`results/summary.txt` and `results/rust-1.97/summary.txt`), so whatever the
erratum pass costs is overhead, not patching. `crates/repro/src/main.rs` calls
every caller through its veneer and checks the sum; every linked binary printed
`ok=true`.

The workload is compiled once, then each case touches `main.rs` and relinks.

### Measurement notes

- Each case and sweep point was run once. Run-to-run variance was not measured
  formally. The Deno cases were also run once during an earlier survey with a
  near-identical script, and agreed to within 5%.
- Per-link records, including build-script links, are in the `link.log` next to
  each summary.

### Running it

```sh
./run.sh                                     # everything, about 1.5-2 h on 64 vCPU
REALWORLD=0 ./run.sh                         # synthetic workload only
```

Individual pieces, once the images are built:

```sh
PROJECTS=deno real-world/run.sh                                          # Deno, Rust 1.98 and 1.97
docker run --rm a53-ld-repro ./run-cases.sh patched/strip patched/keep   # chosen synthetic cases
docker run --rm a53-ld-repro ./run-sweep.sh 20000:0 40000:0              # chosen sweep points
docker run --rm a53-ld-repro ./check-gcc-default.sh                      # does the image's gcc request the fix by default?
./profile-case.sh stock strip 40000 30                                   # stack samples of the running ld
```

## Results

### Deno

Debug `deno` binary: 182 MiB `.text`; about 5,400 veneers with GNU ld and 5,100
with lld on Rust 1.98 (5,200 and 4,600 on Rust 1.97). Results in
`results/real-world/deno/`.

| case | ld given the flag (1.97 / 1.98) | erratum pass runs (1.97 / 1.98) | Rust 1.97.1 | Rust 1.98.1 |
|---|---|---|---|---|
| `patched/strip` | no / no | **no / no** | **32.5 s** | **32.8 s** |
| `patched/keep` | yes (gcc default) / yes | yes / yes | 136.6 s | 139.9 s |
| `patched/optout` | **no / yes** | **no / yes** | **32.6 s** | **144.5 s** |
| `stock/keep` | yes (gcc default) / yes | yes / yes | 136.1 s | 141.5 s |
| `debian/keep` | yes (gcc default) / yes | yes / yes | 128.1 s | 127.1 s |
| `debian/optout` | no / yes | yes (unpatched) / yes | 120.2 s | 126.2 s |
| `debian/strip` | no / no | yes (unpatched) / yes (unpatched) | 118.9 s | 127.9 s |
| `lld/keep` | yes (gcc default) / yes | lld's / lld's | 5.7 s | 5.7 s |

- With the pass on, a Deno relink takes about 4.3× as long: roughly 105 s extra.
- `patched/optout` is the one row that changes between versions. The opt-out
  works on Rust 1.97 and does nothing on Rust 1.98.
- The distro and release linkers (`debian`, `stock`) are slow whatever is passed,
  because of the `ERRAT_NONE` bug (explanation, point 3).

### Other projects

Rust 1.98.1, debug build of each project's main binary, relinked after touching
its root source file. Results in `results/real-world/<project>/`.

| project | `.text` | veneers | `patched/strip` (pass off) | `patched/keep` (pass on) | extra |
|---|---|---|---|---|---|
| Deno | 182 MiB | 5,431 | 32.8 s | 139.9 s | +327% |
| nushell | 80 MiB | 0 | 15.1 s | 17.6 s | +17% |
| uv | 66 MiB | 0 | 9.1 s | 11.5 s | +26% |
| rust-analyzer | 47 MiB | 0 | 8.0 s | 9.8 s | +23% |
| ruff | 18 MiB | 0 | 3.4 s | 4.2 s | +24% |

- Below about 128 MiB of `.text`, every call is within `BL` range, so there are
  no veneers and no large S × N term. The pass still adds about 17-26% to these
  links, although none of them contains an erratum site.
- Deno is the only one of these five above that size. We also tried Zed,
  Databend and RisingWave, which we expected to be larger, but could not build
  them in this image: Zed's prebuilt WebRTC needs a newer compiler runtime,
  Databend failed in a build script, and RisingWave needs nightly Cargo.

### Synthetic workload: case matrix

`REPRO_CALLERS=40000`: 162 MiB `.text`, about 80k input sections from the
generated crate, and about 40,180 veneers with GNU ld (40,021 with lld). Results
in `results/summary.txt` (Rust 1.98) and `results/rust-1.97/summary.txt`.

| case | ld given the flag (1.97 / 1.98) | erratum pass runs (1.97 / 1.98) | Rust 1.97.1 | Rust 1.98.1 |
|---|---|---|---|---|
| `patched/strip` | no / no | **no / no** | **1.3 s** | **1.3 s** |
| `patched/keep` | yes (gcc default) / yes | yes / yes | 70.6 s | 79.7 s |
| `patched/optout` | **no / yes** | **no / yes** | **1.3 s** | **83.0 s** |
| `stock/strip` | no / no | yes (unpatched) / yes (unpatched) | 70.5 s | 82.3 s |
| `stock/keep` | yes (gcc default) / yes | yes / yes | 72.0 s | 79.4 s |
| `stock/optout` | no / yes | yes (unpatched) / yes | 68.4 s | 81.2 s |
| `debian/strip` | no / no | yes (unpatched) / yes (unpatched) | 60.1 s | 61.4 s |
| `debian/keep` | yes (gcc default) / yes | yes / yes | 60.9 s | 63.1 s |
| `debian/optout` | no / yes | yes (unpatched) / yes | 61.3 s | 61.3 s |
| `lld/strip` | no / no | no / no | 0.2 s | 0.2 s |
| `lld/keep` | yes (gcc default) / yes | lld's / lld's | 0.3 s | 0.3 s |
| `lld/optout` | no / yes | no / lld's | 0.2 s | 0.3 s |

The same pattern as Deno: `patched/optout` is 1.3 s on Rust 1.97 and 83.0 s on
Rust 1.98. With GNU ld 2.47 (`stock`, `patched`), the slow links are 10-20% slower
on the Rust 1.98 image than on the 1.97 one; with Debian's ld 2.40 they differ by
at most 4%. We have not investigated this, and Deno does not show it.

### Synthetic workload: scaling

Rust 1.98.1, patched GNU ld, so that the erratum pass is the only difference
between the two time columns. `CALLERS` raises both N and S; `FILLERS` raises
only S. Results in `results/sweep.txt`.

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
   O(S × N), single-threaded, whether or not any erratum site exists. The
   profiles put every sample in that walk. For contrast, the 32-bit Arm backend
   keeps its erratum veneers in per-section lists (`elf32_arm_write_section`
   walks `arm_data->erratumlist`).
2. **Large Rust binaries have both a large S and a large N.** rustc emits one
   `.text.*` section per function. Once `.text` exceeds `BL`'s ±128 MiB range, the
   linker needs a veneer for many out-of-range calls. Smaller binaries have
   N ≈ 0, which is why the other projects pay much less.
3. **binutils 2.33 through 2.47 run the pass even when it is not requested.**
   Since binutils 2.33 (PR ld/24373), `fix_erratum_843419` is an enum whose "off"
   value is `ERRAT_NONE = 1`. So `if (globals->fix_erratum_843419)` is always true
   (`stock/strip`, `debian/strip`). This is fixed on master by commit
   [6e72ff2](https://sourceware.org/git/?p=binutils-gdb.git;a=commit;h=6e72ff251801b05ec10bed36130647985658d7c3)
   ([patch posting](https://inbox.sourceware.org/binutils/20260806054354.27168-1-ktkachov@nvidia.com/)),
   which is not yet in a release. With that fix, not requesting the pass takes a
   Deno relink from 139.9 s to 32.8 s (`patched/strip`).
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
   fix (`keep` rows on Rust 1.97). What 1.98 removed is the escape hatch:
   `-C link-arg=-mno-fix-cortex-a53-843419` worked on 1.97 and no longer does on
   1.98. On toolchains whose gcc does *not* enable it by default (for example the
   Arm GNU toolchain cited in the PR), 1.98 also changes the default.
