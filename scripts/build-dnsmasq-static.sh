#!/usr/bin/env bash
# 构建静态链接的 dnsmasq，供 release 包内置使用。
#
# 为什么需要：SVCB/HTTPS 记录过滤依赖 dnsmasq 的 filter-rr（2.86+），而
# Debian 11 只有 2.85、CentOS 7 只有 2.76、CentOS Stream 8 只有 2.79 —— 这些
# 发行版的包永远不会支持 filter-rr。release 包里带一份我们自己编译的静态
# 二进制（musl，无动态依赖，拷到任何 x86_64/aarch64 Linux 都能跑），安装器在
# 系统 dnsmasq 太旧时改用它。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
OUT="${2:-$ROOT/build-artifacts/dnsmasq-$ARCH}"
DNSMASQ_VERSION="2.90"
# 上游 tarball 的 sha256，升级版本时一起改。
DNSMASQ_SHA256="8e50309bd837bfec9649a812e066c09b6988b73d749b7d293c06c57d46a109e4"

case "$ARCH" in
  amd64) PLATFORM=linux/amd64 ;;
  arm64) PLATFORM=linux/arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 64 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

docker run --rm --platform "$PLATFORM" \
  -e DNSMASQ_VERSION="$DNSMASQ_VERSION" \
  -e DNSMASQ_SHA256="$DNSMASQ_SHA256" \
  -e OUT_NAME="$(basename "$OUT")" \
  -v "$ROOT:/src:ro" \
  -v "$(dirname "$OUT"):/out" \
  alpine:3.20 sh -c '
set -eu
apk add -q --no-cache build-base linux-headers curl xz coreutils >/dev/null
work="$(mktemp -d)"
trap "rm -rf \"$work\"" EXIT
url="https://thekelleys.org.uk/dnsmasq/dnsmasq-$DNSMASQ_VERSION.tar.xz"
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 "$url" -o "$work/dnsmasq.tar.xz"
echo "$DNSMASQ_SHA256  $work/dnsmasq.tar.xz" | sha256sum -c - >/dev/null
tar -xJf "$work/dnsmasq.tar.xz" -C "$work"
cd "$work/dnsmasq-$DNSMASQ_VERSION"
# get-version 从 VERSION 文件读版本号（没有 git 时）；tarball 里是未替换的
# $Format:%d$，不写的话二进制会报空版本，安装器认不出 >= 2.86。
printf "v%s\n" "$DNSMASQ_VERSION" > VERSION
make -s \
  COPTS="-DNO_DNSSEC -DNO_LUA -DNO_IDN -DNO_DBUS -DNO_TFTP -DNO_DHCP -DNO_AUTH -DNO_IPSET -DNO_NFTSET" \
  LDFLAGS="-static" >/dev/null
test -x src/dnsmasq
if readelf -d src/dnsmasq 2>/dev/null | grep -q NEEDED; then
  echo "dnsmasq 不是静态链接" >&2
  exit 1
fi
src/dnsmasq --version | head -n1 | grep -q "version $DNSMASQ_VERSION" || {
  echo "dnsmasq 版本字符串不对：$(src/dnsmasq --version | head -n1)" >&2
  exit 1
}
cp src/dnsmasq "/out/$OUT_NAME"
chmod 0755 "/out/$OUT_NAME"
' >&2

[[ -x "$OUT" ]] || { echo "构建产物缺失：$OUT" >&2; exit 1; }
printf 'built %s (%s bytes, dnsmasq %s, static)\n' "$OUT" "$(stat -c %s "$OUT")" "$DNSMASQ_VERSION"
