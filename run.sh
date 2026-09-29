#!/usr/bin/env bash
# Host-side driver: build the image, run the case matrix, then the scaling sweep.
# Results land in ./results/ (env.txt, summary.txt, sweep.txt, link.log).
#   REPRO_CALLERS  size of the case-matrix workload (default 40000)
#   SWEEP=0        skip the sweep; SWEEP_POINTS="C:F ..." to choose points
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
docker pull -q rust:1.98-bookworm > /dev/null
docker build -t a53-ld-repro . > results/docker-build.log 2>&1
docker image inspect a53-ld-repro --format '{{.Id}}' > results/image-id.txt
docker image inspect rust:1.98-bookworm --format '{{index .RepoDigests 0}}' > results/base-image.txt
run() { docker run --rm -v "$PWD/results:/results" "$@"; }
run -e REPRO_CALLERS="${REPRO_CALLERS:-40000}" a53-ld-repro ./run-cases.sh
if [[ ${SWEEP:-1} == 1 ]]; then
  # shellcheck disable=SC2086
  run a53-ld-repro ./run-sweep.sh ${SWEEP_POINTS:-}
fi
