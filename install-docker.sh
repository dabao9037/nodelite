#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${NODELITE_REPO_URL:-https://github.com/dabao9037/nodelite.git}"
INSTALL_DIR="${NODELITE_DIR:-/opt/nodelite}"
SYSCTL_DIR="${NODELITE_SYSCTL_DIR:-/etc/sysctl.d}"
MODULES_LOAD_DIR="${NODELITE_MODULES_LOAD_DIR:-/etc/modules-load.d}"
PASSWORD_KEY="ADMIN_""PASSWORD"
SECRET_KEY="APP_""SECRET"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install.sh" >&2
  exit 1
fi

info() { printf '\033[0;36m[*]\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

random_password() { openssl rand -base64 24 | tr -d '\n=/+' | cut -c1-20; }
random_secret() { openssl rand -hex 32; }
random_path() { printf 'panel-%s' "$(openssl rand -hex 8)"; }

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 ))
}

port_available() {
  ! ss -H -ltn 2>/dev/null | awk -v suffix=":$1" '$4 ~ suffix "$" {found=1} END {exit !found}'
}

random_high_port() {
  local candidate
  for _ in $(seq 1 200); do
    candidate=$((40000 + 0x$(openssl rand -hex 2) % 20001))
    if port_available "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "无法在 40000-60000 找到空闲访问端口"
}

normalize_path() {
  local value="${1#/}"; value="${value%/}"
  [[ "$value" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || return 1
  printf '%s' "$value"
}

read_key() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

set_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" >"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  install -m 600 "$tmp" "$file"
  rm -f "$tmp"
}

# ==================== 屏蔽 SVCB(64) / HTTPS(65) DNS 记录 ====================
# 这两类记录会把 ipv4hint / ipv6hint（真实地址）和 ech（加密 SNI 配置）直接写进
# DNS 应答。在 Fake-IP 代理体系下，客户端拿到 hint 会绕过假 IP 直连，alpn=h3 又会
# 把流量推进 QUIC(UDP/443)，结果是既走不成代理，也把出口 IP 与 DNS 一起漏出去。
#
# 过滤掉这两种 RR 后，客户端按 RFC 9460/9461 自动回退到 A/AAAA + h2，业务功能不受
# 影响；代价只是失去 HTTP/3 与 ECH。
#
# 依赖 dnsmasq >= 2.86（filter-rr 在 2.86 引入）。版本不够时跳过而不是把系统 DNS
# 改坏。关闭方式：SVCB_BLOCK=0，或执行 dns-unblock 子命令。
# ==========================================================================
SVCB_BLOCK="${SVCB_BLOCK:-1}"
SVCB_ETC="${SVCB_ETC:-/etc}"
SVCB_RESOLV="${SVCB_RESOLV:-/etc/resolv.conf}"
SVCB_CONF="${SVCB_CONF:-$SVCB_ETC/svcb-dns-filter.conf}"
SVCB_UNIT="${SVCB_UNIT:-$SVCB_ETC/systemd/system/svcb-dns-filter.service}"
SVCB_BAK="${SVCB_BAK:-$SVCB_RESOLV.svcb-block.bak}"
SVCB_MODE_FILE="${SVCB_MODE_FILE:-$SVCB_ETC/svcb-dns-filter.mode}"
SVCB_RESOLVED_DROPIN="${SVCB_RESOLVED_DROPIN:-$SVCB_ETC/systemd/resolved.conf.d/90-svcb-block.conf}"
SVCB_NM_DROPIN="${SVCB_NM_DROPIN:-$SVCB_ETC/NetworkManager/conf.d/90-svcb-block.conf}"
SVCB_SHARED_CONF="${SVCB_SHARED_CONF:-$SVCB_ETC/dnsmasq.d/svcb-block.conf}"
SVCB_LISTEN="${SVCB_LISTEN:-127.0.0.1}"
SVCB_TAG="svcb-dns-filter"
SVCB_SVC="$SVCB_TAG.service"

svcb_version() {
  dnsmasq --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p'
}

svcb_version_ok() {
  local v; v="$(svcb_version || true)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n2.86\n' "$v" | sort -V 2>/dev/null | sed -n '1p')" = "2.86" ]
}

svcb_is_on() {
  [ -f "$SVCB_CONF" ] || [ -f "$SVCB_SHARED_CONF" ]
}

svcb_active() {
  systemctl is-active --quiet "$SVCB_SVC" 2>/dev/null
}

svcb_install_dnsmasq() {
  info "安装 dnsmasq（SVCB/HTTPS 过滤依赖 filter-rr）"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq >/dev/null 2>&1 || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q dnsmasq >/dev/null 2>&1 || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q dnsmasq >/dev/null 2>&1 || return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache dnsmasq >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  command -v dnsmasq >/dev/null 2>&1
}

# 沿用系统现有的上游，避免把解析路径换成别处不通的公共 DNS。
# 必须剔除所有环回地址：本脚本自己就把 resolv.conf 指向 127.0.0.1，
# 一旦把 127.0.0.1 当成上游就会自环，整台机器的 DNS 立刻死掉。
svcb_upstreams() {
  { awk '/^[[:space:]]*nameserver[[:space:]]/{print $2}' "$SVCB_RESOLV" 2>/dev/null || true
    awk '/^[[:space:]]*nameserver[[:space:]]/{print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null || true
    # 第三来源：本脚本自己写下的 resolv.conf 备份。
    # 一旦 SVCB_RESOLV 已被改成 127.0.0.1，前两个来源就都是空/环回，只剩这份还留着
    # 真实上游 —— 历史版本正是漏了这一步，导致 shared 模式下 dnsmasq 上游为空。
    if [ -f "$SVCB_BAK" ]; then
      grep -vE '^(symlink:|absent$)' "$SVCB_BAK" 2>/dev/null \
        | awk '/^[[:space:]]*nameserver[[:space:]]/{print $2}' || true
    fi
  } | grep -vE '^127\.|^::1$|^0\.0\.0\.0$|^localhost$' | awk '!seen[$0]++' | sed -n '1,3p'
}

svcb_backup_resolv() {
  [ -e "$SVCB_BAK" ] && return 0
  if [ -L "$SVCB_RESOLV" ]; then
    printf 'symlink:%s\n' "$(readlink "$SVCB_RESOLV" 2>/dev/null || true)" > "$SVCB_BAK"
  elif [ -f "$SVCB_RESOLV" ]; then
    cp -a "$SVCB_RESOLV" "$SVCB_BAK"
  else
    printf 'absent\n' > "$SVCB_BAK"
  fi
}

svcb_restore_resolv() {
  [ -e "$SVCB_BAK" ] || return 0
  if grep -q '^symlink:' "$SVCB_BAK" 2>/dev/null; then
    ln -sfn "$(sed -n 's/^symlink://p' "$SVCB_BAK")" "$SVCB_RESOLV" 2>/dev/null || true
  elif grep -q '^absent$' "$SVCB_BAK" 2>/dev/null; then
    rm -f "$SVCB_RESOLV" 2>/dev/null || true
  else
    rm -f "$SVCB_RESOLV" 2>/dev/null || true
    cp -a "$SVCB_BAK" "$SVCB_RESOLV" 2>/dev/null || true
  fi
  rm -f "$SVCB_BAK" 2>/dev/null || true
}

# systemd-resolved 的 stub 占着 127.0.0.53:53，NetworkManager 会重写 resolv.conf
svcb_release_53() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null && [ ! -f "$SVCB_RESOLVED_DROPIN" ]; then
    mkdir -p "$(dirname "$SVCB_RESOLVED_DROPIN")" 2>/dev/null || true
    printf '[Resolve]\nDNSStubListener=no\n' > "$SVCB_RESOLVED_DROPIN"
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null && [ ! -f "$SVCB_NM_DROPIN" ]; then
    mkdir -p "$(dirname "$SVCB_NM_DROPIN")" 2>/dev/null || true
    printf '[main]\ndns=none\n' > "$SVCB_NM_DROPIN"
    systemctl reload NetworkManager >/dev/null 2>&1 || systemctl restart NetworkManager >/dev/null 2>&1 || true
  fi
  sleep 1
}

svcb_write_conf() {
  local upstreams="$1" s
  mkdir -p "$(dirname "$SVCB_CONF")" 2>/dev/null || true
  {
    printf '# %s\n' "$SVCB_TAG"
    printf '# 过滤 SVCB(64)/HTTPS(65)：阻断 Fake-IP 下的 hint 直连与 QUIC 旁路\n'
    printf 'port=53\n'
    printf 'no-resolv\n'
    while IFS= read -r s; do
      [ -n "$s" ] && printf 'server=%s\n' "$s"
    done <<< "$upstreams"
    printf 'listen-address=%s\n' "$SVCB_LISTEN"
    printf 'bind-dynamic\n'
    printf 'cache-size=2000\n'
    printf 'filter-rr=HTTPS\n'
    printf 'filter-rr=SVCB\n'
  } > "$SVCB_CONF"
  chmod 644 "$SVCB_CONF" 2>/dev/null || true
}

svcb_write_unit() {
  local bin; bin="$(command -v dnsmasq || true)"
  [ -n "$bin" ] || return 1
  mkdir -p "$(dirname "$SVCB_UNIT")" 2>/dev/null || true
  cat > "$SVCB_UNIT" <<UNIT
[Unit]
Description=SVCB/HTTPS DNS 记录过滤器 (dnsmasq)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin --keep-in-foreground --conf-file=$SVCB_CONF
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
}

svcb_write_resolv() {
  rm -f "$SVCB_RESOLV" 2>/dev/null || true
  cat > "$SVCB_RESOLV" <<RESOLV
# $SVCB_TAG: 已过滤 SVCB/HTTPS 记录
nameserver 127.0.0.1
options timeout:2 attempts:3
RESOLV
  chmod 644 "$SVCB_RESOLV" 2>/dev/null || true
}

svcb_port_ready() {
  local _i out=""
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    out="$(ss -Hlun 2>/dev/null | awk '{print $4}' | grep -E '(^|:)53$' 2>/dev/null || true)"
    [ -n "$out" ] && return 0
    sleep 1
  done
  return 1
}

svcb_verify() {
  local a h
  if ! command -v dig >/dev/null 2>&1; then
    info "本机未装 dig，跳过查询验证（仅确认服务与端口）"
    return 0
  fi
  # 先用 A 记录证明这条解析链路是通的，否则"查不到 HTTPS"毫无意义
  a="$(dig +short +time=3 +tries=1 A example.com @127.0.0.1 2>/dev/null | grep -v '^;;' | sed -n '1p' || true)"
  if [ -z "$a" ]; then
    warn "无法从 127.0.0.1 解析 A 记录，DNS 链路未就绪"
    return 1
  fi
  h="$(dig +short +time=3 +tries=1 HTTPS example.com @127.0.0.1 2>/dev/null | grep -v '^;;' || true)"
  [ -z "$h" ] && h="$(dig +short +time=3 +tries=1 SVCB example.com @127.0.0.1 2>/dev/null | grep -v '^;;' || true)"
  if [ -z "$h" ]; then
    ok "验证通过：A 记录正常，HTTPS/SVCB 返回空（已过滤）"
    return 0
  fi
  warn "验证未通过，HTTPS/SVCB 仍可解析：$(printf '%s' "$h" | tr '\n' ' ')"
  return 1
}

svcb_status() {
  local v; v="$(svcb_version || true)"
  info "DNS 过滤状态"
  printf '  dnsmasq 版本 : %s\n' "${v:-未安装}"
  printf '  模式文件     : %s\n' "$([ -f "$SVCB_MODE_FILE" ] && cat "$SVCB_MODE_FILE" || echo 未启用)"
  if svcb_active; then
    printf '  独立服务     : %s（运行中）\n' "$SVCB_SVC"
  else
    printf '  独立服务     : 未运行\n'
  fi
  printf '  共享配置     : %s\n' "$([ -f "$SVCB_SHARED_CONF" ] && echo 存在 || echo 无)"
  printf '  系统解析     : %s\n' "$(awk '/^[[:space:]]*nameserver/{print $2}' "$SVCB_RESOLV" 2>/dev/null | tr '\n' ' ')"
  printf '  上游         : %s\n' "$(svcb_upstreams | tr '\n' ' ')"
  svcb_verify || true
}

# 关闭：停服务、删配置、还原 resolv.conf 与 resolved stub
svcb_disable() {
  local mode="dedicated"
  [ -f "$SVCB_MODE_FILE" ] && mode="$(cat "$SVCB_MODE_FILE" 2>/dev/null || echo dedicated)"
  if [ "$mode" = "shared" ]; then
    rm -f "$SVCB_SHARED_CONF" 2>/dev/null || true
    systemctl reload dnsmasq >/dev/null 2>&1 || systemctl restart dnsmasq >/dev/null 2>&1 || true
  else
    systemctl disable --now "$SVCB_SVC" >/dev/null 2>&1 || true
    rm -f "$SVCB_UNIT" "$SVCB_CONF" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$SVCB_RESOLVED_DROPIN" "$SVCB_NM_DROPIN" 2>/dev/null || true
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager >/dev/null 2>&1 || true
  fi
  svcb_restore_resolv
  rm -f "$SVCB_MODE_FILE" 2>/dev/null || true
  ok "已关闭 SVCB/HTTPS 记录过滤，DNS 配置已还原"
}

# 修复历史版本写下的「半成品」shared 配置（缺 no-resolv + server=）。
#
# 判定依据只看 no-resolv：新版本一定会写它，旧版本一定没有。命中就整份重写成
# 带上游的形态并重启 dnsmasq —— 已坏的机器跑一次 dns-block 即可自愈，不必手工救。
# 恒返回 0，不阻断 svcb_enable 后续流程。
svcb_repair_shared() {
  [ -f "$SVCB_SHARED_CONF" ] || return 0
  grep -qE '^[[:space:]]*no-resolv' "$SVCB_SHARED_CONF" 2>/dev/null && return 0
  local ups; ups="$(svcb_upstreams || true)"
  [ -n "$ups" ] || ups="${SVCB_UPSTREAM:-1.1.1.1 8.8.8.8}"
  info "检测到旧版 shared DNS 配置缺上游（会导致整机解析失败），正在修复"
  {
    printf '# %s\n' "$SVCB_TAG"
    printf '# 上游显式钉死（修复版）：resolv.conf 已指向 127.0.0.1，不能再当上游来源\n'
    printf 'no-resolv\n'
    printf 'no-poll\n'
    while IFS= read -r _svcb_up; do
      if [ -n "$_svcb_up" ]; then printf 'server=%s\n' "$_svcb_up"; fi
    done <<< "$ups"
    printf 'filter-rr=HTTPS\n'
    printf 'filter-rr=SVCB\n'
  } > "$SVCB_SHARED_CONF"
  if systemctl restart dnsmasq >/dev/null 2>&1; then
    ok "shared DNS 配置已修复（上游：$(printf '%s' "$ups" | tr '\n' ' ')）"
  else
    warn "dnsmasq 重启失败，配置已写好，下次启用时会再试一次"
  fi
  return 0
}

# 开启：幂等；任何一步失败都回滚，不把系统 DNS 弄坏
svcb_enable() {
  if [ "$SVCB_BLOCK" != "1" ]; then
    info "SVCB_BLOCK=$SVCB_BLOCK，跳过 SVCB/HTTPS 记录过滤"
    return 0
  fi
  if [ "$(id -u)" != "0" ]; then
    warn "非 root，跳过 SVCB/HTTPS 记录过滤"
    return 0
  fi
  # 自愈：历史版本的 shared 配置只写了 filter-rr，没写 no-resolv/server=，
  # 而 svcb_write_resolv 又把 resolv.conf 指向 127.0.0.1 —— 于是 dnsmasq 上游为空、
  # 整机解析 REFUSED（2026-11-08 秘书3 事故）。每次启用前先补一次，幂等。
  svcb_repair_shared
  # 幂等：服务在跑、配置还在、或者上次已经标记过模式，都直接返回
  if svcb_active || svcb_is_on || [ -f "$SVCB_MODE_FILE" ]; then
    ok "SVCB/HTTPS 记录过滤已启用"
    return 0
  fi

  command -v dnsmasq >/dev/null 2>&1 || svcb_install_dnsmasq || {
    warn "dnsmasq 安装失败，跳过 SVCB/HTTPS 过滤（不影响其他功能）"
    return 0
  }
  if ! svcb_version_ok; then
    warn "dnsmasq $(svcb_version || echo 未知) 低于 2.86，无 filter-rr，跳过过滤"
    return 0
  fi

  local upstreams mode="dedicated"
  upstreams="$(svcb_upstreams || true)"
  [ -n "$upstreams" ] || upstreams="${SVCB_UPSTREAM:-1.1.1.1 8.8.8.8}"

  # 已有 dnsmasq 在跑：注入配置，不另建实例、不动别人的 dnsmasq
  if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    mode="shared"
  fi

  svcb_backup_resolv || true
  svcb_release_53 || true

  if [ "$mode" = "shared" ]; then
    mkdir -p "$(dirname "$SVCB_SHARED_CONF")" 2>/dev/null || true
    {
      printf '# %s\n' "$SVCB_TAG"
      printf '# 上游必须显式钉死：下面 svcb_write_resolv 会把 /etc/resolv.conf 指向\n'
      printf '# 127.0.0.1，若 dnsmasq 仍按 resolv.conf 取上游就是自环，上游列表为空，\n'
      printf '# 整机域名解析一律 REFUSED（2026-11-08 秘书3「更新后没网」事故）。\n'
      printf 'no-resolv\n'
      printf 'no-poll\n'
      while IFS= read -r _svcb_up; do
        if [ -n "$_svcb_up" ]; then printf 'server=%s\n' "$_svcb_up"; fi
      done <<< "$upstreams"
      printf 'filter-rr=HTTPS\n'
      printf 'filter-rr=SVCB\n'
    } > "$SVCB_SHARED_CONF"
    if ! grep -qE '^[[:space:]]*conf-dir=/etc/dnsmasq\.d' /etc/dnsmasq.conf 2>/dev/null; then
      printf '\nconf-dir=/etc/dnsmasq.d/,*.conf\n' >> /etc/dnsmasq.conf 2>/dev/null || true
    fi
    if ! systemctl restart dnsmasq >/dev/null 2>&1; then
      warn "现有 dnsmasq 重启失败，回滚"
      rm -f "$SVCB_SHARED_CONF" 2>/dev/null || true
      svcb_restore_resolv
      return 0
    fi
  else
    # 发行版自带 unit 先让位，避免抢 53
    if systemctl is-enabled --quiet dnsmasq 2>/dev/null; then
      systemctl disable --now dnsmasq >/dev/null 2>&1 || true
    fi
    svcb_write_conf "$upstreams" || { warn "写配置失败，跳过"; svcb_restore_resolv; return 0; }
    svcb_write_unit || { warn "写 service 失败，跳过"; rm -f "$SVCB_CONF"; svcb_restore_resolv; return 0; }
    if ! systemctl enable --now "$SVCB_SVC" >/dev/null 2>&1; then
      warn "过滤服务启动失败，回滚"
      systemctl disable --now "$SVCB_SVC" >/dev/null 2>&1 || true
      rm -f "$SVCB_UNIT" "$SVCB_CONF" 2>/dev/null || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      svcb_restore_resolv
      return 0
    fi
  fi

  if ! svcb_port_ready; then
    warn "53 端口未就绪，回滚 DNS 配置"
    svcb_disable >/dev/null 2>&1 || true
    return 0
  fi

  printf '%s\n' "$mode" > "$SVCB_MODE_FILE" 2>/dev/null || true
  svcb_write_resolv
  ok "已启用 SVCB/HTTPS 记录过滤（$mode 模式，上游：$(printf '%s' "$upstreams" | tr '\n' ' ')）"
  # 验证失败必须回滚，不能把机器留在一个「过滤生效但解析全死」的状态。
  # 宁可暂时没有 DNS 过滤，也不能让转发机失去解析能力（2026-11-08 教训）。
  if ! svcb_verify; then
    warn "验证未通过：解析链路不可用，回滚 DNS 配置以免整机断网"
    svcb_disable >/dev/null 2>&1 || true
    return 0
  fi
  return 0
}
# ================== 屏蔽 SVCB/HTTPS 记录 · 结束 ==================

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git openssl iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git openssl iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git openssl iproute
  else
    die "仅支持 apt、dnf 或 yum 系统"
  fi
}

install_docker() {
  command -v curl >/dev/null 2>&1 || install_packages
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || service docker start
}

ensure_dependencies() {
  command -v git >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v ss >/dev/null 2>&1 || install_packages
  command -v docker >/dev/null 2>&1 || install_docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用，请先安装 Docker Compose v2"
}

ensure_network_tools() {
  command -v sysctl >/dev/null 2>&1 && return
  warn "安装网络设置所需工具：sysctl"
  if command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y procps kmod
  elif command -v dnf >/dev/null; then
    dnf install -y procps-ng kmod
  elif command -v yum >/dev/null; then
    yum install -y procps-ng kmod
  else
    die "请先安装 sysctl（procps/procps-ng）"
  fi
  command -v sysctl >/dev/null 2>&1 || die "安装后仍找不到 sysctl"
}

confirm_network_change() {
  [[ "${NODELITE_ASSUME_YES:-0}" == 1 ]] && return 0
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "已取消"; return 1; }
}

apply_managed_sysctl() {
  local name="$1" content="$2" rollback="$3" file apply_file rollback_file backup=""
  file="$SYSCTL_DIR/$name"
  mkdir -p "$SYSCTL_DIR"
  apply_file="$(mktemp "$SYSCTL_DIR/.nodelite-apply.XXXXXX")"
  rollback_file="$(mktemp "$SYSCTL_DIR/.nodelite-rollback.XXXXXX")"
  printf '%s\n' "$content" >"$apply_file"
  printf '%s\n' "$rollback" >"$rollback_file"
  chmod 0644 "$apply_file" "$rollback_file"
  if ! sysctl -p "$apply_file" >/dev/null; then
    sysctl -p "$rollback_file" >/dev/null 2>&1 || true
    rm -f "$apply_file" "$rollback_file"
    die "应用内核网络设置失败，运行时设置已回滚"
  fi
  if [[ -f "$file" ]] && cmp -s "$apply_file" "$file"; then
    rm -f "$apply_file" "$rollback_file"
    return 0
  fi
  if [[ -f "$file" ]]; then
    backup="$file.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$file" "$backup"
  fi
  if ! mv -f "$apply_file" "$file"; then
    sysctl -p "$rollback_file" >/dev/null 2>&1 || true
    [[ -z "$backup" ]] || cp -a "$backup" "$file"
    rm -f "$apply_file" "$rollback_file"
    die "持久化内核网络设置失败，运行时设置已回滚"
  fi
  chmod 0644 "$file"
  rm -f "$rollback_file"
}

persist_bbr_modules() {
  local file="$MODULES_LOAD_DIR/nodelite-bbr.conf" tmp
  mkdir -p "$MODULES_LOAD_DIR"
  tmp="$(mktemp "$MODULES_LOAD_DIR/.nodelite-bbr.XXXXXX")"
  printf 'tcp_bbr\nsch_fq\n' >"$tmp"
  chmod 0644 "$tmp"
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv -f "$tmp" "$file"; fi
}

disable_ipv6() {
  cat <<'EOF'
关闭 IPv6 会立即影响现有 IPv6 连接；如果当前 SSH 走 IPv6，连接可能中断。
设置会写入独立的 NodeLite sysctl 文件并持久生效，不改动其他 sysctl 文件。
EOF
  confirm_network_change "确认一键关闭 IPv6？" || return 0
  ensure_network_tools
  local old_all old_default
  old_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" || die "当前系统不支持或不允许修改 IPv6 sysctl"
  old_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" || die "当前系统不支持或不允许修改 IPv6 sysctl"
  apply_managed_sysctl "99-zz-nodelite-disable-ipv6.conf" "# Managed by NodeLite
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1" "net.ipv6.conf.all.disable_ipv6 = $old_all
net.ipv6.conf.default.disable_ipv6 = $old_default"
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == 1 ]] || die "IPv6 全局关闭校验失败"
  [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" == 1 ]] || die "IPv6 默认关闭校验失败"
  ok "IPv6 已关闭，并已持久化到 $SYSCTL_DIR/99-zz-nodelite-disable-ipv6.conf"
}

enable_bbr_fq() {
  cat <<'EOF'
将启用 Linux BBR TCP 拥塞控制和 fq 默认队列规则，并写入独立的持久化 sysctl 文件。
此操作不会改动 NodeLite 节点、端口或登录配置。
EOF
  confirm_network_change "确认一键开启 BBR + fq？" || return 0
  ensure_network_tools
  local old_qdisc old_cc available
  old_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)" || die "无法读取默认队列规则"
  old_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || die "无法读取当前 TCP 拥塞控制算法"
  command -v modprobe >/dev/null 2>&1 && { modprobe tcp_bbr 2>/dev/null || true; modprobe sch_fq 2>/dev/null || true; }
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  [[ " $available " == *" bbr "* ]] || die "当前内核不支持 BBR；可用算法：${available:-未知}"
  apply_managed_sysctl "99-zz-nodelite-bbr-fq.conf" "# Managed by NodeLite
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr" "net.core.default_qdisc = $old_qdisc
net.ipv4.tcp_congestion_control = $old_cc"
  [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == fq ]] || die "fq 启用校验失败"
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] || die "BBR 启用校验失败"
  persist_bbr_modules
  ok "BBR + fq 已开启，并已持久化到 $SYSCTL_DIR/99-zz-nodelite-bbr-fq.conf"
}

sync_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" fetch --depth=1 origin main
    git -C "$INSTALL_DIR" reset --hard origin/main
  elif [[ -e "$INSTALL_DIR" ]]; then
    die "安装目录已存在且不是 NodeLite Git 仓库：$INSTALL_DIR"
  else
    git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
  fi
}

require_install() {
  [[ -f "$INSTALL_DIR/docker-compose.yml" && -f "$INSTALL_DIR/.env" ]] || die "NodeLite 尚未安装，请先选择 1"
}

install_shortcuts() {
  local target=/usr/local/bin/node alias=/usr/local/bin/nodelite existing
  cat >"$alias" <<EOF
#!/usr/bin/env bash
# NodeLite management shortcut
if [[ \$# -eq 0 ]]; then
  exec "$INSTALL_DIR/install-docker.sh" menu
else
  exec "$INSTALL_DIR/install-docker.sh" "\$@"
fi
EOF
  chmod 0755 "$alias"

  existing="$(command -v node 2>/dev/null || true)"
  if [[ -z "$existing" || "$existing" == "$target" ]] || grep -q 'NodeLite management shortcut' "$target" 2>/dev/null; then
    cp "$alias" "$target"
    chmod 0755 "$target"
    ok "快捷命令已安装：node"
  else
    warn "检测到已有 node 命令：$existing，未覆盖；可使用 nodelite 进入菜单"
  fi
}


wait_healthy() {
  local attempt panel_health xray_health netguard_health gateway_health
  for attempt in $(seq 1 60); do
    gateway_health="$(docker inspect simple-node-gateway --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    panel_health="$(docker inspect simple-node-panel --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    xray_health="$(docker inspect simple-node-xray --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    netguard_health="$(docker inspect simple-node-netguard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    if [[ "$gateway_health" == healthy && "$panel_health" == healthy && "$xray_health" == healthy && "$netguard_health" == healthy ]]; then
      return 0
    fi
    if [[ "$attempt" == 60 ]]; then
      docker compose ps -a
      docker compose logs --tail=150 gateway panel xray netguard
      return 1
    fi
    sleep 5
  done
}

show_access() {
  local host port path user
  host="$(read_key "$INSTALL_DIR/.env" PUBLIC_HOST)"
  port="$(read_key "$INSTALL_DIR/.env" PANEL_PORT)"
  path="$(read_key "$INSTALL_DIR/.env" ACCESS_PATH)"
  user="$(read_key "$INSTALL_DIR/.env.credentials" ADMIN_USER)"
  cat <<EOF

访问地址：http://$host:$port/$path/login
用户名：$user
安装目录：$INSTALL_DIR

EOF
}

install_or_update() {
  ensure_dependencies
  local old_host old_port old_path old_user old_password old_secret
  old_host="$(read_key "$INSTALL_DIR/.env" PUBLIC_HOST)"
  old_port="$(read_key "$INSTALL_DIR/.env" PANEL_PORT)"
  old_path="$(read_key "$INSTALL_DIR/.env" ACCESS_PATH)"
  old_user="$(read_key "$INSTALL_DIR/.env.credentials" ADMIN_USER)"
  old_password="$(read_key "$INSTALL_DIR/.env.credentials" "$PASSWORD_KEY")"
  old_secret="$(read_key "$INSTALL_DIR/.env.credentials" "$SECRET_KEY")"

  local requested_password="${!PASSWORD_KEY:-}" requested_secret="${!SECRET_KEY:-}"
  local host="${PUBLIC_HOST:-$old_host}" port="${PANEL_PORT:-$old_port}" path="${ACCESS_PATH:-$old_path}"
  local user="${ADMIN_USER:-$old_user}" password secret

  if [[ -z "$host" ]]; then
    host="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  fi
  [[ -n "$host" ]] || die "无法检测公网 IP，请使用 PUBLIC_HOST=域名或IP 重新执行"
  port="${port:-$(random_high_port)}"
  valid_port "$port" || die "PANEL_PORT 必须是 1-65535 的端口"
  path="${path:-$(random_path)}"
  path="$(normalize_path "$path")" || die "ACCESS_PATH 只能包含字母、数字、下划线和横线，长度 8-64"
  user="${user:-admin}"
  password="${requested_password:-${old_password:-$(random_password)}}"
  secret="${requested_secret:-${old_secret:-$(random_secret)}}"

  sync_repo
  cd "$INSTALL_DIR"
  cat >.env <<EOF
PUBLIC_HOST=$host
PANEL_PORT=$port
ACCESS_PATH=$path
IMAGE_TAG=${IMAGE_TAG:-latest}
EOF
  {
    printf 'ADMIN_USER=%s\n' "$user"
    printf '%s=%s\n' "$PASSWORD_KEY" "$password"
    printf '%s=%s\n' "$SECRET_KEY" "$secret"
  } >.env.credentials
  chmod 600 .env .env.credentials
  mkdir -p data xray-config
  chmod 700 data
  chmod 755 xray-config

  install_shortcuts
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  if [[ "${NODELITE_FORCE_BUILD:-0}" != "1" ]] && docker compose pull gateway panel netguard xray; then
    docker compose up -d --no-build --remove-orphans
  else
    warn "预构建镜像不可用，回退到本机构建"
    docker compose up -d --build --remove-orphans
  fi
  wait_healthy || exit 1
  svcb_enable || true
  ok "NodeLite 安装/更新完成"
  show_access
  if [[ -z "$old_password" || -n "$requested_password" ]]; then
    printf '密码：%s\n\n' "$password"
    warn "请立即保存密码；凭据文件位于 $INSTALL_DIR/.env.credentials"
  fi
}

change_credentials() {
  require_install
  local user="${2:-}" password="${3:-}"
  if [[ -t 0 ]]; then
    read -r -p "新管理员用户名 [admin]: " user
    read -r -s -p "新管理员密码（留空则随机生成）: " password; echo
  fi
  user="${user:-admin}"
  password="${password:-$(random_password)}"
  set_key "$INSTALL_DIR/.env.credentials" ADMIN_USER "$user"
  set_key "$INSTALL_DIR/.env.credentials" "$PASSWORD_KEY" "$password"
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate panel gateway xray
  wait_healthy
  ok "管理员凭据已更新"
  printf '用户名：%s\n密码：%s\n' "$user" "$password"
}

change_port() {
  require_install
  local port="${2:-}"
  [[ -n "$port" ]] || read -r -p "新访问端口: " port
  valid_port "$port" || die "端口必须是 1-65535"
  set_key "$INSTALL_DIR/.env" PANEL_PORT "$port"
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate gateway
  wait_healthy
  ok "访问端口已修改"
  show_access
}

change_path() {
  require_install
  local path="${2:-}"
  if [[ -z "$path" && -t 0 ]]; then
    read -r -p "新随机目录（留空自动生成）: " path
  fi
  path="${path:-$(random_path)}"
  path="$(normalize_path "$path")" || die "目录只能包含字母、数字、下划线和横线，长度 8-64"
  set_key "$INSTALL_DIR/.env" ACCESS_PATH "$path"
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate gateway
  wait_healthy
  ok "随机访问目录已修改，旧目录立即失效"
  show_access
}

change_host() {
  require_install
  local host="${2:-}"
  [[ -n "$host" ]] || read -r -p "新的公网 IP 或域名: " host
  [[ -n "$host" && ! "$host" =~ [[:space:]/] ]] || die "地址格式不正确"
  set_key "$INSTALL_DIR/.env" PUBLIC_HOST "$host"
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate panel gateway xray
  wait_healthy
  ok "公开地址已修改"
  show_access
}

show_status() {
  require_install
  cd "$INSTALL_DIR"
  docker compose ps
  show_access
}

restart_services() {
  require_install
  cd "$INSTALL_DIR"
  docker compose restart
  wait_healthy
  ok "NodeLite 已重启并恢复健康"
}

run_tcpfit() {
  ensure_dependencies
  cat <<'EOF'

TCPFit 是独立的第三方系统调优工具，可能修改：
- /etc/sysctl.d 内核网络参数
- tc/qdisc 队列规则与默认路由参数
- systemd 持久化服务
- 可选 swap 配置

它不是 NodeLite 的组成部分。脚本自身提供 status、verify 和 rollback，
但任何网络调优都可能造成 SSH 波动，请确保你有云控制台/KVM 回退通道。
EOF
  local answer
  read -r -p "确认从 Kylin010/tcpfit 获取当前版本并进入其菜单？[y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

  local commit tmp sha
  commit="$(git ls-remote https://github.com/Kylin010/tcpfit.git refs/heads/main | awk 'NR==1{print $1}')"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "无法解析 TCPFit 当前提交"
  tmp="$(mktemp /tmp/tcpfit.XXXXXX.sh)"
  trap 'rm -f "${tmp:-}"' RETURN
  curl -fsSL "https://raw.githubusercontent.com/Kylin010/tcpfit/$commit/tcpfit.sh" -o "$tmp"
  bash -n "$tmp" || die "TCPFit 脚本语法检查失败"
  sha="$(sha256sum "$tmp" | awk '{print $1}')"
  printf '来源提交：%s\n脚本 SHA256：%s\n' "$commit" "$sha"
  bash "$tmp"
  rm -f "$tmp"
  trap - RETURN
}

uninstall_nodelite() {
  require_install
  local answer remove_data
  read -r -p "确认停止并卸载 NodeLite？输入 YES 继续: " answer
  [[ "$answer" == YES ]] || { warn "已取消"; return 0; }
  read -r -p "同时删除数据库、节点和配置？[y/N]: " remove_data
  cd "$INSTALL_DIR"
  docker exec simple-node-netguard python3 /netguard.py rollback >/dev/null 2>&1 || true
  docker compose down --remove-orphans
  for shortcut in /usr/local/bin/node /usr/local/bin/nodelite; do
    if grep -q 'NodeLite management shortcut' "$shortcut" 2>/dev/null; then
      rm -f "$shortcut"
    fi
  done
  if [[ "$remove_data" =~ ^[Yy]$ ]]; then
    cd /
    rm -rf --one-file-system "$INSTALL_DIR"
    ok "NodeLite 与全部数据已删除"
  else
    ok "NodeLite 已停止，安装数据保留在 $INSTALL_DIR"
  fi
}

menu() {
  while true; do
    cat <<'EOF'

============== NodeLite 管理菜单 ==============
  1. 安装 / 更新
  2. 修改管理员账号密码
  3. 修改访问端口
  4. 更换随机访问目录
  5. 修改公网 IP / 域名
  6. 查看运行状态与访问地址
  7. 重启 NodeLite
  8. TCPFit 网络调优（第三方，可回滚）
  9. 卸载 NodeLite
 10. 一键关闭 IPv6
 11. 一键开启 BBR + fq
 12. 屏蔽 SVCB/HTTPS DNS 记录（防 Fake-IP 直连与 QUIC 旁路）
 13. 取消 SVCB/HTTPS 屏蔽
  0. 退出
===============================================
EOF
    local choice
    read -r -p "请选择 [0-11]: " choice
    case "$choice" in
      1) install_or_update ;;
      2) change_credentials ;;
      3) change_port ;;
      4) change_path ;;
      5) change_host ;;
      6) show_status ;;
      7) restart_services ;;
      8) run_tcpfit ;;
      9) uninstall_nodelite ;;
      10) disable_ipv6 ;;
      11) enable_bbr_fq ;;
      12) svcb_enable ;;
      13) svcb_disable ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

command="${1:-}"
if [[ -z "$command" ]]; then
  if [[ -t 0 ]]; then menu; else install_or_update; fi
else
  case "$command" in
    install|update) install_or_update ;;
    credentials) change_credentials "$@" ;;
    port) change_port "$@" ;;
    path) change_path "$@" ;;
    host) change_host "$@" ;;
    status) show_status ;;
    restart) restart_services ;;
    tcpfit) run_tcpfit ;;
    disable-ipv6) disable_ipv6 ;;
    enable-bbr-fq) enable_bbr_fq ;;
    dns-block) svcb_enable ;;
    dns-unblock) svcb_disable ;;
    dns-status) svcb_status ;;
    uninstall) uninstall_nodelite ;;
    menu) menu ;;
    *) die "用法: install.sh [install|credentials|port|path|host|status|restart|tcpfit|disable-ipv6|enable-bbr-fq|dns-block|dns-unblock|dns-status|uninstall|menu]" ;;
  esac
fi
