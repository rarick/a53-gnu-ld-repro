#!/usr/bin/env bash
# Minimal reproduction: build the synthetic crate (../crates) with a plain
# `cargo build` in the official rust:1.98-bookworm image, changing nothing, and
# see how long linking the binary takes. The image's default linker is Debian's
# GNU ld 2.40. See README.md.
#
# Needs Docker running natively on AArch64. Writes nothing to the host: the
# source is mounted read-only and the build happens in a throwaway container.
set -euo pipefail

# Same image as the top-level Dockerfile, pinned by digest.
image=rust:1.98-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e

arch=$(docker info --format '{{.Architecture}}')
if [[ $arch != aarch64 && $arch != arm64 ]]; then
  echo "This needs Docker running natively on AArch64, not $arch." >&2
  exit 1
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
echo "== $image"

# Only the crates are copied in. The repository's .cargo/config.toml, which
# sends links through the case matrix's wrapper, stays behind, so cargo uses
# the default linker (cc, which runs GNU ld) with rustc's default arguments.
docker run --rm -i -v "$repo:/src:ro" "$image" bash -s <<'EOF'
set -euo pipefail
mkdir /work
cp -r /src/Cargo.toml /src/crates /work
cd /work
rustc -V
ld -v
echo "== Compiling the generated crate (no link yet)"
cargo build -p repro-gen
echo "== Compiling main.rs and linking the binary (nearly all of this is the link)"
cargo build -p repro
echo "long-branch veneers in the binary: $(nm target/debug/repro | grep -c '_veneer$')"
EOF
