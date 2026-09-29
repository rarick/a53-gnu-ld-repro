#!/usr/bin/env bash
# Run inside the container. Compiles the workload once, then relinks the same
# binary once per case and records link time, the linker used, whether rustc's
# Cortex-A53 flag reached the driver, the veneer count, and that the binary runs.
#
# Usage: run-cases.sh [case ...]    case = <ld>/<a53>, e.g. fixed/strip
set -euo pipefail
cd /repro
: "${CARGO_TARGET_DIR:=/tmp/target}"; export CARGO_TARGET_DIR
: "${RESULTS:=/results}"; mkdir -p "$RESULTS"
export REPRO_LOG="$RESULTS/link.log"
bin="$CARGO_TARGET_DIR/debug/repro"

cases=("$@")
[[ ${#cases[@]} -eq 0 ]] && cases=(fixed/strip fixed/keep fixed/optout stock/strip stock/keep system/strip system/keep lld/strip lld/keep)

{
  echo "== environment"
  rustc -V; cargo -V
  echo "host: $(uname -m), $(nproc) cpus"
  for v in stock fixed; do echo "binutils-$v: $(/opt/binutils-$v/bin/ld --version | head -1)"; done
  echo "system ld: $(ld --version | head -1)"
  echo "lld: $(ld.lld --version)"
  echo "workload: REPRO_CALLERS=${REPRO_CALLERS:-40000} REPRO_PAD_MIB=${REPRO_PAD_MIB:-160} REPRO_FILLERS=${REPRO_FILLERS:-0}"
} | tee "$RESULTS/env.txt"

echo "== compile (linked with lld so the one-off compile is not slowed by the linker)"
t0=$(date +%s)
REPRO_LD=lld REPRO_A53=keep cargo build --quiet
echo "compile+first link: $(( $(date +%s) - t0 ))s"

printf '%-14s %-10s %-11s %8s %13s %9s  %s\n' case link_s ld_gets_fix veneers erratum_stubs text_MiB run | tee "$RESULTS/summary.txt"
for c in "${cases[@]}"; do
  ld=${c%/*}; a53=${c#*/}
  touch crates/repro/src/main.rs          # relink only; the workload is not rebuilt
  REPRO_LD=$ld REPRO_A53=$a53 cargo build --quiet
  line=$(grep '^repro-' "$REPRO_LOG" | tail -1)
  link_s=$(sed -n 's/.* link_s=\([0-9.]*\).*/\1/p' <<<"$line")
  flag=$(sed -n 's/.* ld_gets_fix=\([0-9]*\).*/\1/p' <<<"$line")
  # GNU ld names long-branch stubs __<sym>_veneer; lld names them __AArch64*Thunk_<sym>.
  veneers=$(nm "$bin" | grep -c -E '_veneer$|__AArch64[A-Za-z]*Thunk_' || true)
  # GNU ld puts each 843419 veneer in a section named e843419@...; lld emits __CortexA53843419_* symbols.
  errata=$(( $(readelf -S -W "$bin" | grep -c e843419 || true) + $(nm "$bin" | grep -c __CortexA53843419_ || true) ))
  text=$(size -A "$bin" | awk '$1==".text"{printf "%.0f", $2/1048576}')
  run=$("$bin" | grep -o 'ok=[a-z]*')
  printf '%-14s %-10s %-11s %8s %13s %9s  %s\n' "$c" "$link_s" "$flag" "$veneers" "$errata" "$text" "$run" | tee -a "$RESULTS/summary.txt"
done
