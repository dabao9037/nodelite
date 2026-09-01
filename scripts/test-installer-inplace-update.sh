#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${NODELITE_INSTALL_TEST_IMAGE:-ubuntu:24.04}"
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 77; }

# Run in an isolated container so the test can use the real /opt/nodelite path
# and cannot touch a host installation or production systemd state.
docker run --rm -i \
  -v "$ROOT:/src:ro" \
  "$IMAGE" bash -s <<'CONTAINER_TEST'
set -Eeuo pipefail

mkdir -p /run/systemd/system /test-bin /fixture-v021 /fixture-v022
cp /src/install.sh /fixture-v021/install.sh
cp /src/install.sh /fixture-v022/install.sh
printf 'v021\n' >/fixture-v021/code-marker
printf 'v022\n' >/fixture-v022/code-marker
for fixture in /fixture-v021 /fixture-v022; do
  mkdir -p "$fixture/bin" "$fixture/systemd" "$fixture/config" "$fixture/data" "$fixture/xray-config"
  printf 'amd64\n' >"$fixture/ARCH"
  printf '2.31\n' >"$fixture/GLIBC_MAX"
  for binary in nodelite-panel nodelite-gateway nodelite-netguard xray; do
    printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/$binary"
    chmod 0755 "$fixture/bin/$binary"
  done
done
for unit in netguard xray panel gateway; do
  printf '[Unit]\nDescription=NodeLite test service\n' >"/fixture-v021/systemd/nodelite-$unit.service"
  printf '[Unit]\nDescription=NodeLite test service\n' >"/fixture-v022/systemd/nodelite-$unit.service"
done
printf 'archive-v021-config-preserved\n' >/fixture-v021/config/archive-sentinel
printf 'archive-v022-must-not-overwrite\n' >/fixture-v022/data/archive-sentinel
printf 'archive-v022-must-not-overwrite\n' >/fixture-v022/xray-config/archive-sentinel
tar -C /fixture-v021 -czf /fixture-v021.tar.gz .
tar -C /fixture-v022 -czf /fixture-v022.tar.gz .

cat >/test-bin/curl <<'FAKE_CURL'
#!/bin/sh
set -eu
output=
previous=
url=
for arg in "$@"; do
  if [ "$previous" = -o ]; then
    output=$arg
    previous=
    continue
  fi
  case "$arg" in file://*|http://*|https://*) url=$arg ;; esac
  previous=$arg
done
if [ -n "$output" ]; then
  case "$url" in
    file://*) cp "${url#file://}" "$output" ;;
    *) printf 'unexpected download URL: %s\n' "$url" >&2; exit 1 ;;
  esac
else
  printf '{"status":"ok","xray":"running","netguard":"running"}\n'
fi
FAKE_CURL
chmod 0755 /test-bin/curl

cat >/test-bin/systemctl <<'FAKE_SYSTEMCTL'
#!/bin/sh
set -eu
case "${1:-}" in
  is-active) exit 1 ;;
  show)
    case "$*" in
      *ActiveState*) printf 'active\n' ;;
      *SubState*) printf 'running\n' ;;
      *NRestarts*) printf '0\n' ;;
      *Result*) printf 'success\n' ;;
    esac
    ;;
  *) exit 0 ;;
esac
FAKE_SYSTEMCTL
chmod 0755 /test-bin/systemctl
for command_name in iptables ip ss; do
  printf '#!/bin/sh\nexit 0\n' >"/test-bin/$command_name"
  chmod 0755 "/test-bin/$command_name"
done
cat >/test-bin/openssl <<'FAKE_OPENSSL'
#!/bin/sh
case "${1:-}" in
  rand)
    case "${2:-}" in
      -hex)
        if [ "${3:-}" = 8 ]; then printf '0000000000000000\n'; else printf '%064d\n' 0; fi
        ;;
      -base64) printf 'test-password-1234567890\n' ;;
    esac
    ;;
  *) exit 0 ;;
esac
FAKE_OPENSSL
chmod 0755 /test-bin/openssl
export PATH="/test-bin:$PATH"

export NODELITE_DIR=/opt/nodelite
export NODELITE_SYSTEMD_DIR=/tmp/nodelite-systemd
export NODELITE_BIN_DIR=/tmp/nodelite-bin
export NODELITE_VERSION=v0.2.1-native
export NODELITE_ASSET_URL=file:///fixture-v021.tar.gz
export PUBLIC_HOST=127.0.0.1
mkdir -p "$NODELITE_SYSTEMD_DIR"

bash /src/install.sh install >/tmp/install-v021.log
grep -q 'v0.2.1-native / amd64' /tmp/install-v021.log
test -f /opt/nodelite/install.sh
printf 'archive-v021-config-preserved\n' >/opt/nodelite/config/archive-sentinel
printf 'preserved-before-update\n' >/opt/nodelite/data/panel.db
printf 'preserved-xray-config\n' >/opt/nodelite/xray-config/config.json
printf 'preserved-data-sentinel\n' >/opt/nodelite/data/archive-sentinel
printf 'preserved-xray-sentinel\n' >/opt/nodelite/xray-config/archive-sentinel
printf 'preserved-config\n' >/opt/nodelite/config/user.conf
db_inode=$(stat -c '%d:%i' /opt/nodelite/data/panel.db)
env_hash=$(sha256sum /opt/nodelite/config/nodelite.env | awk '{print $1}')

export NODELITE_VERSION=v0.2.2-native
export NODELITE_ASSET_URL=file:///fixture-v022.tar.gz
cd /opt/nodelite
# The absolute installed path is the operator-facing command and keeps the
# current installer path identical to its managed destination.
printf '1\n0\n' | (cd /opt/nodelite && bash install.sh menu) >/tmp/install-v022-menu.log
! grep -Eqi 'same file|same-file|are the same file|同一个文件' /tmp/install-v022-menu.log
grep -q 'v0.2.2-native / amd64' /tmp/install-v022-menu.log
grep -q '^用户名：' /tmp/install-v022-menu.log
grep -q '^密码：' /tmp/install-v022-menu.log
grep -q '^v022$' /opt/nodelite/code-marker
test "$(cat /opt/nodelite/data/panel.db)" = preserved-before-update
test "$(cat /opt/nodelite/xray-config/config.json)" = preserved-xray-config
test -f /opt/nodelite/config/user.conf
test "$(cat /opt/nodelite/config/archive-sentinel)" = archive-v021-config-preserved
test "$(cat /opt/nodelite/data/archive-sentinel)" = preserved-data-sentinel
test "$(cat /opt/nodelite/xray-config/archive-sentinel)" = preserved-xray-sentinel
test "$db_inode" = "$(stat -c '%d:%i' /opt/nodelite/data/panel.db)"
test "$env_hash" = "$(sha256sum /opt/nodelite/config/nodelite.env | awk '{print $1}')"

printf 'INPLACE_MENU_UPDATE_OK current_installer_path=/opt/nodelite/install.sh archive_update=yes\n'
CONTAINER_TEST
