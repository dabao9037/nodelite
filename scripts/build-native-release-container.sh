#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
IMAGE="${NODELITE_BUILD_IMAGE:-}"
PLATFORM=""

case "$ARCH" in
  amd64)
    IMAGE="${IMAGE:-debian:11-slim}"
    PLATFORM=linux/amd64
    ;;
  arm64)
    IMAGE="${IMAGE:-debian:11-slim}"
    PLATFORM=linux/arm64
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 64
    ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

docker run --rm --platform "$PLATFORM" \
  -e DEBIAN_FRONTEND=noninteractive \
  -e GITHUB_SHA="${GITHUB_SHA:-local}" \
  -e NODELITE_GLIBC_MAX="${NODELITE_GLIBC_MAX:-2.31}" \
  -v "$ROOT:/src" \
  -w /src \
  "$IMAGE" \
  bash -lc 'apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 python3-venv python3-dev gcc binutils patchelf curl ca-certificates >/dev/null && /src/scripts/build-native-release.sh "'"$ARCH"'"'
