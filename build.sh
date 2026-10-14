#!/usr/bin/env sh
# Build the nginx reverse-proxy + certbot container for MikroTik RouterOS,
# producing a single container-archive tar.
#
# Mirrors ../tor-mikrotik/build.sh, but ARM64 ONLY:
#
#   nginx-arm64.tar  linux/arm64  ARMv8  -> RB5009 (Cortex-A72) & aarch64
#
# arm32 is intentionally DROPPED: this project targets only the RB5009 router,
# which is arm64. (The tor/tailscale images ship an arm32v5 variant for the
# hAP ax S / EN7562CT boards; nginx here has no such target.)
#
# nginx and certbot are installed from the Debian archive, so there is no
# cross-compile step — the whole build runs in the target-arch base image. The
# Mac build host is native arm64, so no QEMU is needed. On a non-arm64 host,
# register QEMU once first:
#   docker run --privileged --rm tonistiigi/binfmt --install all
#
# Requires Docker Buildx and skopeo.
#
# Usage:
#   ./build.sh          # -> nginx-arm64.tar

VERSION=0.1.0

set -eu

build_arch() {
    _name="$1"
    _platform="$2"
    _runtime_base="$3"
    _out="nginx-${_name}.tar"

    echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
    rm -f "${_out}"

    docker buildx build \
      --no-cache \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "nginx-mikrotik:${VERSION}-${_name}" .

    skopeo copy \
      "docker-daemon:nginx-mikrotik:${VERSION}-${_name}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

# Single arch (arm64) — no arch matrix to iterate.
build_arch arm64 "linux/arm64" "arm64v8/debian:bookworm-slim"

echo ">>> Build complete."
ls -lh nginx-*.tar 2>/dev/null || true
