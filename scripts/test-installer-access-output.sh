#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Load installer helpers without dispatching a command.
source <(sed '/^command="${1:-}"/,$d' "$ROOT/install.sh")
INSTALL_DIR="$TMP/install"
mkdir -p "$INSTALL_DIR/config"
cat >"$INSTALL_DIR/config/nodelite.env" <<'EOF'
PUBLIC_HOST=203.0.113.9
LISTEN_PORT=2060
ACCESS_PATH=panel-example
ADMIN_USER=admin-example
ADMIN_PASSWORD=generated-example-password
EOF

output="$(show_access)"
grep -q '访问地址：http://203.0.113.9:2060/panel-example/login' <<<"$output"
grep -q '用户名：admin-example' <<<"$output"
grep -q '密码：generated-example-password' <<<"$output"
grep -q "安装目录：$INSTALL_DIR" <<<"$output"

# A blank credential must fail the gate rather than printing a misleading result.
set_key "$INSTALL_DIR/config/nodelite.env" "$PASSWORD_KEY" ""
if show_access 2>/dev/null | grep -q '^密码：$'; then
  echo 'show_access accepted an empty password' >&2
  exit 1
fi

echo INSTALLER_ACCESS_CREDENTIALS_OK
