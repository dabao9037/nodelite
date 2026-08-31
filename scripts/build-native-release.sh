#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/build/native"
ARCH="${1:-amd64}"
XRAY_VERSION="26.6.27"
case "$ARCH" in
  amd64) XRAY_ARCH=64 ;;
  arm64) XRAY_ARCH=arm64-v8a ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 64 ;;
esac

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD/root/bin" "$BUILD/root/config" "$BUILD/root/data" "$BUILD/root/xray-config" "$BUILD/root/systemd" "$DIST"
python -m venv "$BUILD/venv"
"$BUILD/venv/bin/pip" install --upgrade pip wheel pyinstaller
"$BUILD/venv/bin/pip" install -r "$ROOT/requirements-native.txt"

build_one() {
  local name="$1" entry="$2"
  "$BUILD/venv/bin/pyinstaller" --noconfirm --clean --onedir --name "$name" \
    --paths "$ROOT" --collect-all app --collect-all qrcode --collect-all uvicorn \
    "$ROOT/$entry"
  cp -a "$ROOT/dist/$name" "$BUILD/root/lib-$name"
  cat >"$BUILD/root/bin/$name" <<EOF
#!/usr/bin/env bash
exec "${NODELITE_HOME:-/opt/nodelite}/lib-$name/$name" "\$@"
EOF
  chmod 0755 "$BUILD/root/bin/$name"
}

build_one nodelite-panel native/panel_entry.py
build_one nodelite-gateway native/gateway_entry.py
build_one nodelite-netguard native/netguard_entry.py

curl -fL --retry 3 "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" -o "$BUILD/xray.zip"
python - "$BUILD/xray.zip" "$BUILD/root/bin/xray" <<'PY'
import sys, zipfile
source, target = sys.argv[1:]
with zipfile.ZipFile(source) as archive, open(target, "wb") as output:
    output.write(archive.read("xray"))
PY
chmod 0755 "$BUILD/root/bin/xray"
cp "$ROOT"/packaging/systemd/*.service "$BUILD/root/systemd/"
printf '%s\n' "$XRAY_VERSION" >"$BUILD/root/XRAY_VERSION"
printf '%s\n' "${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}" >"$BUILD/root/BUILD_COMMIT"

tar -C "$BUILD/root" -czf "$DIST/nodelite-linux-$ARCH.tar.gz" .
sha256sum "$DIST/nodelite-linux-$ARCH.tar.gz" >"$DIST/nodelite-linux-$ARCH.tar.gz.sha256"
