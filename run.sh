#!/usr/bin/env bash
# Host-side driver. Builds the Rust 1.98 and Rust 1.97 images, runs the
# real-world projects and the full synthetic case matrix on each, profiles the two slow GNU ld cases that differ in whether ld
# is given the flag, then runs the scaling sweep (Rust 1.98).
#
# Results land in ./results/:
#   env.txt summary.txt link.log                  Rust 1.98 case matrix
#   rust-1.97/{env,summary,link}.*                Rust 1.97 case matrix
#   profile-<ld>-<a53>.txt                        stack samples of the running ld
#   sweep.txt                                     scaling sweep
#   image-id*.txt base-image*.txt                 image digests
#   real-world/<project>/rust-<ver>/              real-world projects (real-world/run.sh)
#
#   REPRO_CALLERS  size of the case-matrix workload (default 40000)
#   RUST197=0      skip the Rust 1.97 matrix
#   PROFILE=0      skip the profiles
#   SWEEP=0        skip the sweep; SWEEP_POINTS="C:F ..." to choose points
#   REALWORLD=0    skip the real-world projects (real-world/run.sh; needs both images)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
callers=${REPRO_CALLERS:-40000}
# Must match the digests in the Dockerfile.
IMAGE_198=rust:1.98-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e
IMAGE_197=rust:1.97-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97

build() {  # <tag> <base image> <suffix>
  docker pull -q "$2" > /dev/null
  docker build --build-arg RUST_IMAGE="$2" -t "$1" . > "results/docker-build$3.log" 2>&1
  docker image inspect "$1" --format '{{.Id}}' > "results/image-id$3.txt"
  echo "$2" > "results/base-image$3.txt"
}
run() { docker run --rm -v "$PWD/results:/results" "$@"; }

build a53-ld-repro "$IMAGE_198" ""
[[ ${RUST197:-1} != 0 ]] && build a53-ld-repro:rust-1.97 "$IMAGE_197" "-rust-1.97"

if [[ ${REALWORLD:-1} != 0 ]]; then
  real-world/run.sh
fi

run -e REPRO_CALLERS="$callers" a53-ld-repro ./run-cases.sh

if [[ ${RUST197:-1} != 0 ]]; then
  run -e REPRO_CALLERS="$callers" -e RESULTS=/results/rust-1.97 a53-ld-repro:rust-1.97 ./run-cases.sh
fi

if [[ ${PROFILE:-1} != 0 ]]; then
  # patched/keep: ld is given the flag. stock/strip: ld is not, but runs the pass anyway.
  for c in patched/keep stock/strip; do
    ./profile-case.sh "${c%/*}" "${c#*/}" "$callers" 30 > "results/profile-${c/\//-}.txt"
  done
fi

if [[ ${SWEEP:-1} != 0 ]]; then
  # shellcheck disable=SC2086
  run a53-ld-repro ./run-sweep.sh ${SWEEP_POINTS:-}
fi
