# syntax=docker/dockerfile:1
#
# Real-world projects: the reproducer image (GNU ld stock/patched, Debian ld,
# lld and the repro-cc wrapper) plus the build dependencies of the projects in
# projects.txt. Build context is this directory.
#
#   docker build --build-arg BASE=a53-ld-repro            -t a53-ld-realworld .
#   docker build --build-arg BASE=a53-ld-repro:rust-1.97  -t a53-ld-realworld:rust-1.97 .
ARG BASE=a53-ld-repro
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cmake clang protobuf-compiler pkg-config jq \
      libssl-dev libzstd-dev libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
COPY run-project.sh /usr/local/bin/run-project.sh
