#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
XRAY_VERSION="26.6.27"
PYTHON="${PYTHON:-python3}"
BUILD="$ROOT/build/native-$ARCH"
PYI_DIST="$BUILD/pyinstaller-dist"
PYI_WORK="$BUILD/pyinstaller-work"
PKG="$BUILD/package"
OUT="$ROOT/dist/nodelite-linux-$ARCH.tar.gz"

case "$ARCH" in
  amd64) XRAY_ARCH=64 ;;
  arm64) XRAY_ARCH=arm64-v8a ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 64 ;;
esac

command -v "$PYTHON" >/dev/null 2>&1 || { echo "$PYTHON is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$PYI_DIST" "$PYI_WORK" "$PKG/bin" "$PKG/lib" "$PKG/config" \
  "$PKG/data" "$PKG/xray-config" "$PKG/systemd" "$ROOT/dist"

"$PYTHON" -m venv "$BUILD/venv"
"$BUILD/venv/bin/python" -m pip install --disable-pip-version-check -q --upgrade pip wheel
"$BUILD/venv/bin/python" -m pip install --disable-pip-version-check -q -r "$ROOT/requirements-native.txt" pyinstaller

build_one() {
  local name="$1" entry="$2"
  shift 2
  "$BUILD/venv/bin/pyinstaller" --noconfirm --clean --onedir \
    --name "$name" \
    --paths "$ROOT" \
    --distpath "$PYI_DIST" \
    --workpath "$PYI_WORK/$name" \
    --specpath "$BUILD/spec" \
    "$@" \
    "$ROOT/$entry"
  test -x "$PYI_DIST/$name/$name"
  cp -a "$PYI_DIST/$name" "$PKG/lib/$name"
  ln -s "../lib/$name/$name" "$PKG/bin/$name"
}

build_one nodelite-panel native/panel_entry.py \
  --hidden-import app.main \
  --add-data "$ROOT/app/static:app/static"
build_one nodelite-gateway native/gateway_entry.py
build_one nodelite-netguard native/netguard_entry.py \
  --hidden-import netguard.netguard

download_xray() {
  local asset="Xray-linux-${XRAY_ARCH}.zip"
  local direct="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/$asset"
  local payload id api_url
  if curl -fL --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 600 "$direct" -o "$BUILD/xray.zip"; then
    return 0
  fi
  echo "Xray direct download failed; retrying via GitHub API asset" >&2
  payload="$(curl -fsSL --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${XRAY_VERSION}" 2>/dev/null || true)"
  [[ -n "$payload" ]] || { echo "cannot read Xray release metadata" >&2; return 1; }
  id="$(printf '%s' "$payload" | grep -B40 -F "\"browser_download_url\": \"$direct\"" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "cannot resolve Xray asset id" >&2; return 1; }
  api_url="https://api.github.com/repos/XTLS/Xray-core/releases/assets/$id"
  curl -fL --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 600 \
    -H 'Accept: application/octet-stream' "$api_url" -o "$BUILD/xray.zip"
}

download_xray
"$PYTHON" - "$BUILD/xray.zip" "$PKG/bin" <<'PY'
import pathlib, sys, zipfile
archive, destination = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(archive) as bundle:
    wanted = {"xray", "geoip.dat", "geosite.dat"}
    names = {pathlib.PurePosixPath(name).name: name for name in bundle.namelist()}
    missing = wanted - names.keys()
    if missing:
        raise SystemExit(f"Xray archive missing: {sorted(missing)}")
    for basename in wanted:
        target = destination / basename
        target.write_bytes(bundle.read(names[basename]))
PY
chmod 0755 "$PKG/bin/xray"
chmod 0644 "$PKG/bin/geoip.dat" "$PKG/bin/geosite.dat"

# 内置 dnsmasq：SVCB/HTTPS 过滤要 filter-rr（2.86+），Debian 11（2.85）、
# CentOS 7（2.76）、CentOS Stream 8（2.79）的系统包都没有。静态 musl 二进制，
# 安装器在系统版本不够时改用它，不覆盖发行版的 /usr/sbin/dnsmasq。
DNSMASQ_BIN="${NODELITE_DNSMASQ_BIN:-$ROOT/build-artifacts/dnsmasq-$ARCH}"
if [[ ! -x "$DNSMASQ_BIN" ]]; then
  echo "缺少静态 dnsmasq：$DNSMASQ_BIN（先跑 scripts/build-dnsmasq-static.sh $ARCH）" >&2
  exit 68
fi
install -m 0755 "$DNSMASQ_BIN" "$PKG/bin/dnsmasq"
"$PKG/bin/dnsmasq" --version | head -n1 | grep -q '2\.90' \
  || { echo "内置 dnsmasq 版本不对：$("$PKG/bin/dnsmasq" --version | head -n1)" >&2; exit 68; }

cp "$ROOT"/packaging/systemd/*.service "$PKG/systemd/"
cp "$ROOT/install.sh" "$PKG/install.sh"
cp "$ROOT/install-docker.sh" "$PKG/install-docker.sh"
chmod 0755 "$PKG/install.sh" "$PKG/install-docker.sh"

# Include source/config needed by the optional Docker compatibility installer
# and for auditable release contents. Native systemd services use only bin/lib.
mkdir -p "$PKG/source"
cp "$ROOT/docker-compose.yml" "$ROOT/Dockerfile" "$ROOT/entrypoint.sh" \
  "$ROOT/requirements.txt" "$ROOT/.env.example" \
  "$PKG/source/"
cp -a "$ROOT/app" "$ROOT/gateway" "$ROOT/netguard" "$PKG/source/"
find "$PKG/source" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$PKG/source" -type f -name '*.pyc' -delete

# standalone Python 的 libpython 带调试符号（单份 119MB，三个服务各一份）。
# 不 strip 的话压缩包会从 ~65MB 涨到 ~140MB。
strip_payload() {
  local file
  while IFS= read -r -d '' file; do
    readelf -h "$file" >/dev/null 2>&1 || continue
    strip --strip-unneeded "$file" 2>/dev/null || true
  done < <(find "$PKG/lib" -type f -print0)
}
strip_payload

printf '%s\n' "$XRAY_VERSION" > "$PKG/XRAY_VERSION"
printf '%s\n' "$ARCH" > "$PKG/ARCH"
# 实测包里真正需要的最低 GLIBC，别再把拍脑袋的 2.31 写进去：
# 实测值是多少，安装器就放行到哪个版本（Debian 10 是 2.28、CentOS 7 是 2.17）。
MEASURED_GLIBC="$("$PYTHON" "$ROOT/scripts/glibc-required.py" "$PKG")"
printf '%s\n' "$MEASURED_GLIBC" > "$PKG/GLIBC_MAX"
echo "measured GLIBC_MAX=$MEASURED_GLIBC"
printf '%s\n' "${NODELITE_RELEASE_TAG:-${GITHUB_REF_NAME:-dev}}" > "$PKG/VERSION"
printf '%s\n' "${GITHUB_SHA:-local}" > "$PKG/BUILD_COMMIT"

# A "dev" VERSION ships a package the installer will reject with a version
# mismatch. Fail the build instead of publishing an uninstallable asset.
if [[ "$(cat "$PKG/VERSION")" == "dev" && -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "refusing to build release package with VERSION=dev" >&2
  exit 66
fi

# Validate the exact package before compression.
test -x "$PKG/bin/nodelite-panel"
test -x "$PKG/bin/nodelite-gateway"
test -x "$PKG/bin/nodelite-netguard"
test -x "$PKG/bin/xray"
test -x "$PKG/bin/dnsmasq"
test -x "$PKG/install.sh"
test -s "$PKG/VERSION"
test -s "$PKG/BUILD_COMMIT"
for unit in panel gateway xray netguard; do test -s "$PKG/systemd/nodelite-$unit.service"; done
"$ROOT/scripts/verify-glibc-compat.sh" "$PKG" "${NODELITE_GLIBC_MAX:-2.17}"
[[ "$(cat "$PKG/GLIBC_MAX")" != "0.0" ]] || { echo "GLIBC_MAX 测量失败" >&2; exit 69; }

rm -f "$OUT" "$OUT.sha256"
tar -C "$PKG" -czf "$OUT" .
sha256sum "$OUT" > "$OUT.sha256"
printf 'built %s (%s bytes)\n' "$OUT" "$(stat -c %s "$OUT")"
cat "$OUT.sha256"
