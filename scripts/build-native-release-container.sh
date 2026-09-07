#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
IMAGE="${NODELITE_BUILD_IMAGE:-}"
PLATFORM=""

case "$ARCH" in
  amd64)
    IMAGE="${IMAGE:-python:3.12-slim-bullseye}"
    PLATFORM=linux/amd64
    ;;
  arm64)
    IMAGE="${IMAGE:-python:3.12-slim-bullseye}"
    PLATFORM=linux/arm64
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 64
    ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

# The release tag must reach the in-container build, otherwise VERSION falls
# back to "dev" and the installer rejects the package (version mismatch).
RELEASE_TAG="${NODELITE_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
if [[ -z "$RELEASE_TAG" ]]; then
  echo "NODELITE_RELEASE_TAG (or GITHUB_REF_NAME) is required" >&2
  exit 65
fi

docker run --rm --platform "$PLATFORM" \
  -e DEBIAN_FRONTEND=noninteractive \
  -e GITHUB_SHA="${GITHUB_SHA:-local}" \
  -e NODELITE_RELEASE_TAG="$RELEASE_TAG" \
  -e GITHUB_REF_NAME="$RELEASE_TAG" \
  -e NODELITE_GLIBC_MAX="${NODELITE_GLIBC_MAX:-2.31}" \
  -v "$ROOT:/src" \
  -w /src \
  "$IMAGE" \
  bash -lc 'apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc binutils patchelf curl ca-certificates >/dev/null && /src/scripts/build-native-release.sh "'"$ARCH"'"'
