#!/usr/bin/env bash
# 下载固定版本的 python-build-standalone（带共享库 libpython），供老发行版构建使用。
#
# 为什么不用 manylinux 镜像自带的 Python：它们全是 --disable-shared 静态编译，
# PyInstaller 直接拒绝（"Python was built without a shared library"）。而系统自带的
# 共享库 Python 版本太老。standalone 版本是 --enable-shared，并且 x86_64/aarch64
# 都按 glibc 2.17 编译，正好能让 CentOS 7 / Ubuntu 18.04 这类机器跑起来。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
DEST="${2:-$ROOT/build-artifacts/python-$ARCH}"

PY_VERSION="3.12.16"
PBS_RELEASE="20261110"

case "$ARCH" in
  amd64) PBS_ARCH="x86_64"; SHA256="c2f87d4b4e8db3abddb0f116c6ccfc503d0cbdbb9ee8faacddad1b679ec12e99" ;;
  arm64) PBS_ARCH="aarch64"; SHA256="4792f81750282597fb2a3389fe18b945ed2ba6aad5e45ad406d122c58cb33081" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 64 ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_RELEASE}-${PBS_ARCH}-unknown-linux-gnu-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${ASSET//+/%2B}"

if [[ -x "$DEST/bin/python3" ]] && "$DEST/bin/python3" -c 'import sysconfig,sys; sys.exit(0 if sysconfig.get_config_var("Py_ENABLE_SHARED") else 1)' 2>/dev/null; then
  printf 'standalone python already present: %s\n' "$DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "downloading $URL" >&2
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 600 "$URL" -o "$work/python.tar.gz"
echo "$SHA256  $work/python.tar.gz" | sha256sum -c - >/dev/null
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$work/python.tar.gz" -C "$DEST" --strip-components=1
"$DEST/bin/python3" -c 'import sysconfig,sys; print("standalone python", sys.version.split()[0], "shared=", sysconfig.get_config_var("Py_ENABLE_SHARED"))'
"$DEST/bin/python3" -c 'import sysconfig,sys; sys.exit(0 if sysconfig.get_config_var("Py_ENABLE_SHARED") else 1)' \
  || { echo "standalone python 不是共享库构建，PyInstaller 用不了" >&2; exit 1; }
