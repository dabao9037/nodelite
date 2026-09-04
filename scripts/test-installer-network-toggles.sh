#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/sysctl.d" "$TMP/modules-load.d" "$TMP/state"

cat >"$TMP/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${NODELITE_TEST_STATE:?}"
get_value() {
  case "$1" in
    net.ipv6.conf.all.disable_ipv6|net.ipv6.conf.default.disable_ipv6) cat "$state/${1//\//_}" 2>/dev/null || echo 0 ;;
    net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbr' ;;
    net.core.default_qdisc) cat "$state/qdisc" 2>/dev/null || echo fq_codel ;;
    net.ipv4.tcp_congestion_control) cat "$state/congestion" 2>/dev/null || echo cubic ;;
    *) exit 1 ;;
  esac
}
case "${1:-}" in
  -n) get_value "$2" ;;
  -p)
    while IFS='=' read -r raw_key raw_value; do
      key="${raw_key//[[:space:]]/}"; value="${raw_value//[[:space:]]/}"
      [[ -n "$key" && "$key" != \#* ]] || continue
      case "$key" in
        net.ipv6.conf.all.disable_ipv6|net.ipv6.conf.default.disable_ipv6) printf '%s\n' "$value" >"$state/${key//\//_}" ;;
        net.core.default_qdisc) printf '%s\n' "$value" >"$state/qdisc" ;;
        net.ipv4.tcp_congestion_control) printf '%s\n' "$value" >"$state/congestion" ;;
      esac
    done <"$2"
    ;;
  --system) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/modprobe" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$TMP/bin/sysctl" "$TMP/bin/modprobe"

test_installer() {
  local installer="$1" functions="$TMP/$(basename "$installer").functions.sh"
  sed '/^command="${1:-}"/,$d' "$installer" >"$functions"
  (
    export PATH="$TMP/bin:$PATH"
    export NODELITE_SYSCTL_DIR="$TMP/sysctl.d"
    export NODELITE_MODULES_LOAD_DIR="$TMP/modules-load.d"
    export NODELITE_TEST_STATE="$TMP/state"
    export NODELITE_ASSUME_YES=1
    # shellcheck disable=SC1090
    source "$functions"
    disable_ipv6
    enable_bbr_fq
    disable_ipv6
    enable_bbr_fq
  )
  grep -Fq 'net.ipv6.conf.all.disable_ipv6 = 1' "$TMP/sysctl.d/99-zz-nodelite-disable-ipv6.conf"
  grep -Fq 'net.ipv6.conf.default.disable_ipv6 = 1' "$TMP/sysctl.d/99-zz-nodelite-disable-ipv6.conf"
  grep -Fq 'net.core.default_qdisc = fq' "$TMP/sysctl.d/99-zz-nodelite-bbr-fq.conf"
  grep -Fq 'net.ipv4.tcp_congestion_control = bbr' "$TMP/sysctl.d/99-zz-nodelite-bbr-fq.conf"
  test "$(cat "$TMP/modules-load.d/nodelite-bbr.conf")" = $'tcp_bbr\nsch_fq'
  test "$(cat "$TMP/state/net.ipv6.conf.all.disable_ipv6")" = 1
  test "$(cat "$TMP/state/net.ipv6.conf.default.disable_ipv6")" = 1
  test "$(cat "$TMP/state/qdisc")" = fq
  test "$(cat "$TMP/state/congestion")" = bbr
  rm -f "$TMP/sysctl.d"/* "$TMP/modules-load.d"/* "$TMP/state"/*
}

test_installer "$ROOT/install.sh"
test_installer "$ROOT/install-docker.sh"
grep -Fq '11. 一键关闭 IPv6' "$ROOT/install.sh"
grep -Fq '12. 一键开启 BBR + fq' "$ROOT/install.sh"
grep -Fq '10. 一键关闭 IPv6' "$ROOT/install-docker.sh"
grep -Fq '11. 一键开启 BBR + fq' "$ROOT/install-docker.sh"

printf 'INSTALLER_NETWORK_TOGGLES_OK native_and_docker=yes\n'
