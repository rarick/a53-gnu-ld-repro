#!/usr/bin/env bash
# Host-side profiler: start one link case in a container, then sample stacks of
# the running ld from inside the same container (docker exec + eu-stack). The
# container's binutils are built with -g, so frames resolve to functions.
# Usage: profile-case.sh <ld> <a53> [callers] [samples]
set -u
ld=$1; a53=$2; callers=${3:-40000}; samples=${4:-30}
cd "$(dirname "$0")"
name=a53-prof-$$
docker run -d --rm --cap-add SYS_PTRACE --name "$name" -e REPRO_CALLERS="$callers" \
  a53-ld-repro ./run-cases.sh "$ld/$a53" > /dev/null
inside() { docker exec "$name" bash -c "$1"; }
# Wait for the big link: an ld process that has been running for >= 3s.
pid=
for _ in $(seq 1 900); do
  pid=$(inside 'for p in $(pgrep -x ld); do echo "$(ps -o etimes= -p $p) $p"; done | sort -n | tail -1 | awk "\$1>=3{print \$2}"' 2>/dev/null)
  [[ -n $pid ]] && break
  sleep 1
done
echo "ld pid in container=$pid"
inside "for i in \$(seq 1 $samples); do eu-stack -p $pid 2>/dev/null | grep -E '^#[0-9]+ ' | head -6 | awk '{print \$3}' | tr '\n' ' '; echo; sleep 0.5; done" \
  | sort | uniq -c | sort -rn | head -12
docker stop "$name" > /dev/null 2>&1
