#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
IMAGE="${NODELITE_BUILD_IMAGE:-}"
PLATFORM=""

case "$ARCH" in
  amd64)
    # manylinux2014 = glibc 2.17 基线，覆盖 CentOS 7 / Ubuntu 18.04 / Debian 9+。
    # 镜像自带的 Python 全是静态编译（PyInstaller 用不了），所以额外挂一个
    # 带共享库的 standalone Python，见 fetch-standalone-python.sh。
    IMAGE="${IMAGE:-quay.io/pypa/manylinux2014_x86_64}"
    PLATFORM=linux/amd64
    ;;
  arm64)
    IMAGE="${IMAGE:-quay.io/pypa/manylinux2014_aarch64}"
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

# 内置静态 dnsmasq：老发行版（Debian 11 / CentOS 7/8）的系统包没有 filter-rr。
bash "$ROOT/scripts/build-dnsmasq-static.sh" "$ARCH" "$ROOT/build-artifacts/dnsmasq-$ARCH"

bash "$ROOT/scripts/fetch-standalone-python.sh" "$ARCH" "$ROOT/build-artifacts/python-$ARCH"

docker run --rm --platform "$PLATFORM" \
  -e DEBIAN_FRONTEND=noninteractive \
  -e PYTHON=/opt/standalone-python/bin/python3 \
  -e NODELITE_DNSMASQ_BIN="/src/build-artifacts/dnsmasq-$ARCH" \
  -e GITHUB_SHA="${GITHUB_SHA:-local}" \
  -e NODELITE_RELEASE_TAG="$RELEASE_TAG" \
  -e GITHUB_REF_NAME="$RELEASE_TAG" \
  -e NODELITE_GLIBC_MAX="${NODELITE_GLIBC_MAX:-2.17}" \
  -v "$ROOT:/src" \
  -v "$ROOT/build-artifacts/python-$ARCH:/opt/standalone-python:ro" \
  -w /src \
  "$IMAGE" \
  bash -lc '/src/scripts/build-native-release.sh "'"$ARCH"'"'
