#!/usr/bin/env bash
# Scaling sweep. Rebuilds the workload at several sizes and times the link with
# the patched GNU ld, with and without the Cortex-A53 843419 fix, so the fix is
# the only difference between the two columns. Run inside the container.
#
# Each point is CALLERS:FILLERS.
#   CALLERS raises both N (one veneer per caller) and S (two sections per caller)
#   FILLERS raises S only (leaf functions that need no veneer)
#
# Usage: run-sweep.sh [CALLERS:FILLERS ...]
set -euo pipefail
cd /repro
: "${RESULTS:=/results}"; mkdir -p "$RESULTS"
points=("$@")
[[ ${#points[@]} -eq 0 ]] && points=(5000:0 10000:0 20000:0 40000:0 80000:0 20000:40000 20000:160000)
out="$RESULTS/sweep.txt"
printf '%-8s %-8s %-11s %8s %12s %12s %8s\n' callers fillers text_MiB veneers no_fix_s fix_s ratio | tee "$out"
for p in "${points[@]}"; do
  c=${p%:*}; f=${p#*:}
  d="$RESULTS/sweep-$c-$f"
  RESULTS=$d REPRO_CALLERS=$c REPRO_FILLERS=$f CARGO_TARGET_DIR=/tmp/target-$c-$f \
    ./run-cases.sh patched/strip patched/keep > /dev/null
  read -r _ s0 _ v _ t _ < <(sed -n 2p "$d/summary.txt")
  read -r _ s1 _ _ _ _ _ < <(sed -n 3p "$d/summary.txt")
  printf '%-8s %-8s %-11s %8s %12s %12s %8s\n' "$c" "$f" "$t" "$v" "$s0" "$s1" \
    "$(echo "scale=1; $s1 / $s0" | bc)" | tee -a "$out"
  rm -rf "/tmp/target-$c-$f"
done
