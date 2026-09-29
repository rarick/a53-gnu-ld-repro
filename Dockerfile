# syntax=docker/dockerfile:1
#
# Reproducer: GNU ld link time on aarch64 with rustc's default
# -Wl,--fix-cortex-a53-843419 (rust-lang/rust#155453, Rust 1.98).
#
# Base: the official Docker Hub Rust image (Debian bookworm). On top of it we
# build GNU ld from the binutils-2.47 release tarball twice:
#   /opt/binutils-stock  unmodified 2.47
#   /opt/binutils-patched  2.47 + upstream commit 6e72ff2 ("aarch64: ERRAT_NONE is
#                        not zero, so test against it"), which stops ld from
#                        running the 843419 stub walk when the fix is NOT asked for
# and install Debian's lld for comparison.
# Pinned by digest for reproducibility (linux/arm64 manifest list as pulled on
# 2026-09-28). Override with --build-arg RUST_IMAGE=rust:1.97-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97
# for the pre-#155453 comparison.
ARG RUST_IMAGE=rust:1.98-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e
FROM ${RUST_IMAGE}

ARG BINUTILS_VERSION=2.47
# sha256 of binutils-2.47.tar.xz (from ftp.gnu.org; any GNU mirror copy must match)
ARG BINUTILS_SHA256=154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff

RUN apt-get update \
 && apt-get install -y --no-install-recommends bison flex patch bc lld elfutils \
 && rm -rf /var/lib/apt/lists/*

COPY binutils-errat-none-fix.patch /tmp/binutils-errat-none-fix.patch
RUN set -eux; \
    cd /tmp; \
    tarball="binutils-${BINUTILS_VERSION}.tar.xz"; \
    curl -fsSLO --retry 5 --retry-all-errors --connect-timeout 30 "https://ftp.gnu.org/gnu/binutils/$tarball" \
      || curl -fsSLO --retry 5 --retry-all-errors --connect-timeout 30 "https://ftpmirror.gnu.org/binutils/$tarball"; \
    if [ -n "${BINUTILS_SHA256}" ]; then \
      echo "${BINUTILS_SHA256}  binutils-${BINUTILS_VERSION}.tar.xz" | sha256sum -c -; \
    fi; \
    for variant in stock patched; do \
      mkdir "src-$variant" "build-$variant"; \
      tar -xJf "binutils-${BINUTILS_VERSION}.tar.xz" -C "src-$variant" --strip-components=1; \
      if [ "$variant" = patched ]; then \
        (cd "src-$variant" && patch -p1 < /tmp/binutils-errat-none-fix.patch); \
      fi; \
      (cd "build-$variant" && \
        "../src-$variant/configure" --prefix="/opt/binutils-$variant" \
          --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
          --disable-gold --disable-nls --disable-werror && \
        make -j"$(nproc)" MAKEINFO=true all-ld && \
        make MAKEINFO=true install-ld); \
    done; \
    rm -rf /tmp/src-* /tmp/build-* /tmp/binutils-*.tar.xz

WORKDIR /repro
COPY . /repro
RUN chmod +x /repro/repro-cc /repro/run-cases.sh /repro/run-sweep.sh
