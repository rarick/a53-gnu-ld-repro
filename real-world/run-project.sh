#!/usr/bin/env bash
# Run inside the a53-ld-realworld container. Builds one unmodified project with
# a plain debug `cargo build`, then relinks its binary once per case and records
# link time, whether ld was given the flag, veneer count and .text size.
#
# Between cases the binary's root source file is touched, i.e. the usual
# edit-rebuild loop: cargo recompiles that one crate (incrementally) and relinks.
# Dependencies are never rebuilt, since REPRO_LD / REPRO_A53 are not part of
# cargo's fingerprint.
#
# Usage: run-project.sh <name> <package> <bin> [case ...]
#   expects the checkout at /src/<name>, writes to $RESULTS (default /results)
set -uo pipefail
name=$1; pkg=$2; binname=$3; shift 3
cases=("$@")
[[ ${#cases[@]} -eq 0 ]] && cases=(lld/keep patched/strip patched/keep patched/optout stock/keep debian/keep debian/optout debian/strip)

cd "/src/$name" || exit 1
: "${CARGO_TARGET_DIR:=/work/target-$name}"; export CARGO_TARGET_DIR
: "${RESULTS:=/results}"; mkdir -p "$RESULTS"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=/repro/repro-cc
# Use the image's toolchain even if the project pins another (rust-toolchain.toml).
RUSTUP_TOOLCHAIN=$(rustup default | cut -d' ' -f1); export RUSTUP_TOOLCHAIN
export REPRO_LOG="$RESULTS/link.log"
bin="$CARGO_TARGET_DIR/debug/$binname"
src=$(cargo metadata --no-deps --format-version 1 \
  | jq -r --arg p "$pkg" --arg b "$binname" \
      '.packages[] | select(.name==$p) | .targets[] | select(.name==$b and (.kind|index("bin"))) | .src_path')

{
  echo "project: $name $(git rev-parse HEAD) ($(git log -1 --format=%cs))"
  echo "command: cargo build -p $pkg --bin $binname   (dev profile)"
  echo "relink by touching: ${src#/src/$name/}"
  rustc -V; cargo -V
  echo "host: $(uname -m), $(nproc) cpus"
  for v in stock patched; do echo "binutils-$v: $(/opt/binutils-$v/bin/ld --version | head -1)"; done
  echo "debian ld: $(ld --version | head -1)"
  echo "lld: $(ld.lld --version)"
} | tee "$RESULTS/env.txt"

echo "== initial build (linked with lld)"
t0=$(date +%s)
if ! REPRO_LD=lld REPRO_A53=keep cargo build --quiet -p "$pkg" --bin "$binname" > "$RESULTS/build.log" 2>&1; then
  tail -30 "$RESULTS/build.log"; exit 1
fi
echo "initial build: $(( $(date +%s) - t0 ))s" | tee -a "$RESULTS/env.txt"

printf '%-15s %8s %11s %8s %9s\n' case link_s ld_gets_fix veneers text_MiB | tee "$RESULTS/summary.txt"
for c in "${cases[@]}"; do
  ld=${c%/*}; a53=${c#*/}
  touch "$src"
  REPRO_LD=$ld REPRO_A53=$a53 cargo build --quiet -p "$pkg" --bin "$binname" >> "$RESULTS/build.log" 2>&1 || { echo "$c: build failed"; exit 1; }
  # The link log names the output <crate>-<hash>; the crate name uses '_' for '-'.
  line=$(grep -E "^(${binname}|${binname//-/_})-[0-9a-f]+ " "$REPRO_LOG" | tail -1)
  link_s=$(sed -n 's/.* link_s=\([0-9.]*\).*/\1/p' <<<"$line")
  fix=$(sed -n 's/.* ld_gets_fix=\([0-9]*\).*/\1/p' <<<"$line")
  veneers=$(nm "$bin" | grep -c -E '_veneer$|__AArch64[A-Za-z]*Thunk_' || true)
  text=$(size -A "$bin" | awk '$1==".text"{printf "%.0f", $2/1048576}')
  printf '%-15s %8s %11s %8s %9s\n' "$c" "$link_s" "$fix" "$veneers" "$text" | tee -a "$RESULTS/summary.txt"
done
