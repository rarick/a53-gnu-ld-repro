#!/usr/bin/env bash
# Host-side driver for the real-world projects. Needs the reproducer images from
# ../run.sh (a53-ld-repro and a53-ld-repro:rust-1.97). Clones each project in
# projects.txt at its pinned commit, then runs run-project.sh for it.
#
# Results: ../results/real-world/<name>/<rust-version>/{env,summary}.txt, link.log
#
#   PROJECTS="deno uv"   only these projects (default: all in projects.txt)
#   RUST197=0            skip Rust 1.97 entirely
#   ALL_197=1            also run the other projects on Rust 1.97 (default: only deno)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p src work ../results/real-world
docker build -q --build-arg BASE=a53-ld-repro -t a53-ld-realworld . > /dev/null
if [[ ${RUST197:-1} != 0 ]]; then
  docker build -q --build-arg BASE=a53-ld-repro:rust-1.97 -t a53-ld-realworld:rust-1.97 . > /dev/null
fi

want=" ${PROJECTS:-} "
while read -r name url commit pkg bin; do
  [[ -z $name ]] && continue
  [[ $want != "  " && $want != *" $name "* ]] && continue
  if [[ ! -d src/$name ]]; then
    git init -q "src/$name"
    git -C "src/$name" remote add origin "$url"
  fi
  git -C "src/$name" fetch -q --depth 1 origin "$commit"
  git -C "src/$name" checkout -q --detach "$commit"

  versions=(1.98 1.97)
  if [[ ${RUST197:-1} == 0 ]] || [[ $name != deno && ${ALL_197:-0} == 0 ]]; then versions=(1.98); fi
  for v in "${versions[@]}"; do
    tag=latest; [[ $v == 1.97 ]] && tag=rust-1.97
    echo "=== $name, Rust $v"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work -e CARGO_HOME=/work/cargo-home \
      -e CARGO_TARGET_DIR="/work/target-$name-$v" -e RESULTS="/results/$name/rust-$v" \
      -v "$PWD/src:/src" -v "$PWD/work:/work" -v "$PWD/../results/real-world:/results" \
      "a53-ld-realworld:$tag" run-project.sh "$name" "$pkg" "$bin" < /dev/null
  done
done < <(grep -v '^#' projects.txt)
