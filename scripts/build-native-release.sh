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
"$BUILD/venv/bin/pip" install --disable-pip-version-check -q --upgrade pip wheel
"$BUILD/venv/bin/pip" install --disable-pip-version-check -q -r "$ROOT/requirements-native.txt" pyinstaller

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

curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" \
  -o "$BUILD/xray.zip"
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

printf '%s\n' "$XRAY_VERSION" > "$PKG/XRAY_VERSION"
printf '%s\n' "$ARCH" > "$PKG/ARCH"
printf '%s\n' "${GITHUB_SHA:-local}" > "$PKG/BUILD_COMMIT"

# Validate the exact package before compression.
test -x "$PKG/bin/nodelite-panel"
test -x "$PKG/bin/nodelite-gateway"
test -x "$PKG/bin/nodelite-netguard"
test -x "$PKG/bin/xray"
test -x "$PKG/install.sh"
for unit in panel gateway xray netguard; do test -s "$PKG/systemd/nodelite-$unit.service"; done

rm -f "$OUT" "$OUT.sha256"
tar -C "$PKG" -czf "$OUT" .
sha256sum "$OUT" > "$OUT.sha256"
printf 'built %s (%s bytes)\n' "$OUT" "$(stat -c %s "$OUT")"
cat "$OUT.sha256"
