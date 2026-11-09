#!/usr/bin/env bash
set -Eeuo pipefail

# Administrative tools such as nft, ip and sysctl live in sbin. A root shell
# started without a login profile (su, cron, some CI/agents) may omit those
# directories, which previously aborted installation even when nftables was
# installed. Keep the installer's own PATH complete as well.
for _dir in /usr/local/sbin /usr/sbin /sbin; do
  case ":$PATH:" in *":$_dir:"*) ;; *) [[ -d "$_dir" ]] && PATH="$PATH:$_dir" ;; esac
done
unset _dir
export PATH

REPO="${NODELITE_GITHUB_REPO:-dabao9037/nodelite}"
INSTALL_DIR="${NODELITE_DIR:-/opt/nodelite}"
SYSTEMD_DIR="${NODELITE_SYSTEMD_DIR:-/etc/systemd/system}"
BIN_DIR="${NODELITE_BIN_DIR:-/usr/local/bin}"
SYSCTL_DIR="${NODELITE_SYSCTL_DIR:-${SYSCTL_DIR:-/etc/sysctl.d}}"
MODULES_LOAD_DIR="${NODELITE_MODULES_LOAD_DIR:-${MODULES_LOAD_DIR:-/etc/modules-load.d}}"
INTERNAL_PORT=18080
PASSWORD_KEY="ADMIN_""PASSWORD"
SECRET_KEY="APP_""SECRET"
SERVICES=(nodelite-netguard.service nodelite-xray.service nodelite-panel.service nodelite-gateway.service)

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行：sudo bash install.sh" >&2; exit 1; }
info() { printf '\033[0;36m[*]\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
random_password() { openssl rand -base64 24 | tr -d '\n=/+' | cut -c1-20; }
random_secret() { openssl rand -hex 32; }
random_path() { printf 'panel-%s' "$(openssl rand -hex 8)"; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 )); }
port_available() { ! ss -H -ltn 2>/dev/null | awk -v suffix=":$1" '$4 ~ suffix "$" {found=1} END {exit !found}'; }
random_high_port() {
  local candidate
  for _ in $(seq 1 200); do
    candidate=$((40000 + 0x$(openssl rand -hex 2) % 20001))
    if port_available "$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  die "无法在 40000-60000 找到空闲访问端口"
}
normalize_path() { local v="${1#/}"; v="${v%/}"; [[ "$v" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || return 1; printf '%s' "$v"; }
read_key() { [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" | tail -n1 || true; }
set_key() { local f="$1" k="$2" v="$3" t; t="$(mktemp)"; [[ ! -f "$f" ]] || grep -v "^${k}=" "$f" >"$t" || true; printf '%s=%s\n' "$k" "$v" >>"$t"; install -m 600 "$t" "$f"; rm -f "$t"; }
have_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
service_ctl() { have_systemd || die "原生模式需要 systemd"; systemctl "$@"; }

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
    info "SVCB_BLOCK=${SVCB_BLOCK}，跳过 SVCB/HTTPS 记录过滤"
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

ensure_tools() {
  local missing=() packages=() cmd
  for cmd in curl tar openssl iptables ip; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  ((${#missing[@]} == 0)) && return
  warn "仅安装缺失的基础工具：${missing[*]}"
  if command -v apt-get >/dev/null; then
    for cmd in "${missing[@]}"; do case "$cmd" in ip) packages+=(iproute2);; *) packages+=("$cmd");; esac; done
    apt-get update && apt-get install -y ca-certificates "${packages[@]}"
  elif command -v dnf >/dev/null; then
    for cmd in "${missing[@]}"; do case "$cmd" in ip) packages+=(iproute);; *) packages+=("$cmd");; esac; done
    dnf install -y ca-certificates "${packages[@]}"
  elif command -v yum >/dev/null; then
    for cmd in "${missing[@]}"; do case "$cmd" in ip) packages+=(iproute);; *) packages+=("$cmd");; esac; done
    yum install -y ca-certificates "${packages[@]}"
  else die "请先安装 curl、tar、openssl、iptables 和 iproute2/iproute"; fi
  for cmd in curl tar openssl iptables ip; do command -v "$cmd" >/dev/null 2>&1 || die "依赖安装后仍找不到命令：$cmd"; done
}

ensure_nft() {
  local resolved
  resolved="$(command -v nft 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    warn "缺少 nft，正在安装 nftables"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y ca-certificates nftables
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y ca-certificates nftables
    elif command -v yum >/dev/null 2>&1; then
      yum install -y ca-certificates nftables
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache ca-certificates nftables
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install ca-certificates nftables
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm ca-certificates nftables
    else
      die "缺少 nft，且未找到受支持的包管理器；请先安装 nftables 后重试"
    fi
    resolved="$(command -v nft 2>/dev/null || true)"
  fi
  # The panel runs as a systemd service with a shorter PATH than an
  # interactive root shell. Publish nft in BIN_DIR so that service can find it
  # even on distributions that install nft only in /usr/sbin.
  if [[ -n "$resolved" && "$resolved" != "$BIN_DIR/nft" ]]; then
    mkdir -p "$BIN_DIR"
    ln -sf "$resolved" "$BIN_DIR/nft"
  fi
  command -v nft >/dev/null 2>&1 || die "nft 安装失败；请先手动安装 nftables 后重试"
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  warn "TCPFit 需要 git，正在安装缺失依赖"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y ca-certificates git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates git
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates git
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ca-certificates git
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ca-certificates git
  else
    die "TCPFit 需要 git，但未找到受支持的包管理器；请先安装 git 后重试"
  fi
  command -v git >/dev/null 2>&1 || die "git 安装失败；TCPFit 未执行，请先手动安装 git 后重试"
}

asset_arch() {
  case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) die "暂不支持架构：$(uname -m)";; esac
}
validate_release_compatibility() {
  local release_dir="$1" expected_arch="$2" package_arch required_glibc host_glibc highest
  package_arch="$(cat "$release_dir/ARCH" 2>/dev/null || true)"
  [[ "$package_arch" == "$expected_arch" ]] || die "发行包架构不匹配：需要 ${expected_arch}，实际 ${package_arch:-未知}"
  for item in bin/nodelite-panel bin/nodelite-gateway bin/nodelite-netguard bin/xray; do
    [[ -x "$release_dir/$item" ]] || die "发行包缺少可执行文件：$item"
  done
  required_glibc="$(cat "$release_dir/GLIBC_MAX" 2>/dev/null || true)"
  [[ "$required_glibc" =~ ^[0-9]+\.[0-9]+$ ]] || die "发行包缺少有效的 GLIBC_MAX 兼容性声明"
  host_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
  [[ "$host_glibc" =~ ^[0-9]+\.[0-9]+$ ]] || die "无法检测当前系统 glibc 版本"
  highest="$(printf '%s\n%s\n' "$required_glibc" "$host_glibc" | sort -V | tail -n1)"
  [[ "$highest" == "$host_glibc" ]] || die "当前系统 glibc $host_glibc 低于发行包要求 ${required_glibc}；尚未停止或替换现有服务"
  info "发行包兼容性检查通过：架构=${package_arch}，系统 glibc=${host_glibc}，要求≥$required_glibc"
}
latest_tag() {
  [[ -n "${NODELITE_VERSION:-}" ]] && { echo "$NODELITE_VERSION"; return; }
  # GitHub API / CDN may serve a stale "latest" for a while after a release;
  # bust the cache so an update never silently reinstalls the previous version.
  local attempt payload tag url
  for attempt in 1 2 3 4 5; do
    url="https://api.github.com/repos/$REPO/releases/latest?nodelite=$(date +%s)-$attempt-$RANDOM"
    payload="$(curl -fsSL \
      --connect-timeout 15 --max-time 60 \
      --retry 3 --retry-all-errors --retry-delay 2 \
      -H 'Accept: application/vnd.github+json' \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
      "$url" 2>/dev/null || true)"
    tag="$(printf '%s' "$payload" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-native$ ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
    sleep $((attempt * 2))
  done
  return 1
}

api_asset_url() {
  local tag="$1" asset="$2" payload download_url id
  download_url="https://github.com/$REPO/releases/download/$tag/$asset"
  payload="$(curl -fsSL \
    --connect-timeout 15 --max-time 60 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "https://api.github.com/repos/$REPO/releases/tags/$tag?nodelite=$(date +%s)-$RANDOM" 2>/dev/null || true)"
  [[ -n "$payload" ]] || return 1
  # The release JSON puts the asset id ~30 lines above browser_download_url.
  # Do not parse the whole document with a greedy match: the release body may
  # mention the same filename and the uploader object also has an "id".
  id="$(printf '%s' "$payload" | grep -B40 -F "\"browser_download_url\": \"$download_url\"" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  printf 'https://api.github.com/repos/%s/releases/assets/%s\n' "$REPO" "$id"
}

download_native_asset() {
  local tag="$1" arch="$2" destination="$3"
  local asset="nodelite-linux-$arch.tar.gz"
  local base_url="${NODELITE_ASSET_URL:-https://github.com/$REPO/releases/download/$tag/$asset}"
  local attempt delay cache_bust url api_url
  for attempt in 1 2 3; do
    cache_bust="nodelite=$(date +%s)-$attempt-$RANDOM"
    url="$base_url"
    [[ "$url" == *\?* ]] && url="$url&$cache_bust" || url="$url?$cache_bust"
    if curl -fL \
      --connect-timeout 15 --max-time 600 \
      --retry 3 --retry-all-errors --retry-delay 2 \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
      "$url" -o "$destination"; then
      [[ -s "$destination" ]] || die "下载到的原生发行包为空"
      return 0
    fi
    rm -f "$destination"
    delay=$((attempt * 2))
    warn "发行包暂时不可用，${delay} 秒后重试（$attempt/3）"
    sleep "$delay"
  done
  warn "直连发行包连续失败，尝试 GitHub API asset 回退"
  api_url="$(api_asset_url "$tag" "$asset" || true)"
  [[ -n "$api_url" ]] || die "无法解析 GitHub API 发行包地址：$base_url"
  info "回退下载：$api_url"
  curl -fL \
    --connect-timeout 15 --max-time 600 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    -H 'Accept: application/octet-stream' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api_url" -o "$destination"
  [[ -s "$destination" ]] || die "GitHub API 回退下载到的原生发行包为空"
}

installed_version() {
  local version commit
  version="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
  commit="$(cat "$INSTALL_DIR/BUILD_COMMIT" 2>/dev/null || true)"
  [[ -n "$version" ]] || version="未知"
  if [[ "$commit" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    printf '%s (%s)' "$version" "${commit:0:7}"
  else
    printf '%s' "$version"
  fi
}
require_native() { [[ -f "$INSTALL_DIR/config/nodelite.env" && -x "$INSTALL_DIR/bin/nodelite-panel" ]] || die "NodeLite 原生版尚未安装"; }

save_installer() {
  local destination="$1" source="${BASH_SOURCE[0]:-}"
  mkdir -p "$(dirname "$destination")"
  case "$source" in
    ""|bash|/bin/bash|/usr/bin/bash|/dev/fd/*|/proc/*/fd/*) source="" ;;
  esac
  if [[ -n "$source" && -e "$destination" && "$source" -ef "$destination" ]]; then
    bash -n "$destination" || die "保存的 NodeLite 管理脚本不完整"
    return 0
  fi
  if [[ -n "$source" && -f "$source" && -r "$source" ]]; then
    install -m 0755 "$source" "$destination"
  else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" -o "$destination"
    chmod 0755 "$destination"
  fi
  bash -n "$destination" || die "保存的 NodeLite 管理脚本不完整"
}

backup_runtime_state() {
  local backup_dir="$1" item
  mkdir -p "$backup_dir"
  for item in config data xray-config; do
    if [[ -e "$INSTALL_DIR/$item" || -L "$INSTALL_DIR/$item" ]]; then
      cp -a -- "$INSTALL_DIR/$item" "$backup_dir/$item"
    fi
  done
}

install_release_code() {
  local release_dir="$1" item name
  mkdir -p "$INSTALL_DIR"
  for item in "$release_dir"/* "$release_dir"/.[!.]*; do
    [[ -e "$item" || -L "$item" ]] || continue
    name="${item##*/}"
    case "$name" in
      # Keep the management script that is actually running.  The release
      # tarball can contain an older install.sh; copying it would silently
      # reintroduce fixed bugs on the next `nodelite` invocation.
      config|data|xray-config|install.sh) continue ;;
    esac
    rm -rf -- "$INSTALL_DIR/$name"
    cp -a -- "$item" "$INSTALL_DIR/"
  done
}

stop_legacy_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  local name running=()
  for name in simple-node-gateway simple-node-panel simple-node-xray simple-node-netguard; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == true ]] && running+=("$name")
  done
  ((${#running[@]} == 0)) && return 0
  info "检测到旧 NodeLite Docker 服务，切换原生模式并停止旧容器（数据和镜像保留）"
  docker stop -t 3 "${running[@]}" >/dev/null || die "停止旧 NodeLite Docker 容器失败"
}

port_in_use() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" {found=1} END {exit !found}'
}

stop_native_for_upgrade() {
  have_systemd || return 0
  local found=0 unit
  for unit in "${SERVICES[@]}"; do [[ -e "$SYSTEMD_DIR/$unit" ]] && found=1; done
  (( found == 1 )) || return 0
  info "停止现有 NodeLite 原生服务，准备平滑更新"
  service_ctl stop nodelite-gateway.service nodelite-panel.service nodelite-xray.service nodelite-netguard.service || true
}

choose_internal_port() {
  local preferred="${1:-$INTERNAL_PORT}" candidate
  if ! port_in_use "$preferred"; then INTERNAL_PORT="$preferred"; return 0; fi
  warn "内部端口 127.0.0.1:$preferred 被残留进程占用，自动选择新端口"
  ss -H -ltnp 2>/dev/null | awk -v suffix=":$preferred" '$4 ~ suffix "$"' >&2 || true
  for candidate in $(seq 18081 18180); do
    if ! port_in_use "$candidate"; then INTERNAL_PORT="$candidate"; info "新的 Panel 内部端口：127.0.0.1:$INTERNAL_PORT"; return 0; fi
  done
  die "无法找到可用的 Panel 内部端口（18081-18180）"
}

preflight_port() {
  local port="$1"
  if port_in_use "$port" && ! service_ctl is-active --quiet nodelite-gateway.service 2>/dev/null; then
    warn "访问端口 $port 已被其他程序占用："
    ss -H -ltnp 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$"' >&2 || true
    die "请先释放端口 ${port}，或用 PANEL_PORT=其他端口 重新安装"
  fi
}

install_shortcuts() {
  mkdir -p "$BIN_DIR"
  local alias="$BIN_DIR/nodelite" target="$BIN_DIR/node" existing temporary changed=0
  temporary="$(mktemp)"
  cat >"$temporary" <<EOF
#!/usr/bin/env bash
# NodeLite management shortcut
if [[ \$# -eq 0 ]]; then
  exec "$INSTALL_DIR/install.sh" menu
else
  exec "$INSTALL_DIR/install.sh" "\$@"
fi
EOF
  if [[ ! -f "$alias" ]] || ! cmp -s "$temporary" "$alias"; then
    install -m 0755 "$temporary" "$alias"
    changed=1
  fi
  rm -f "$temporary"
  existing="$(command -v node 2>/dev/null || true)"
  if [[ -z "$existing" || "$existing" == "$target" ]] || grep -q 'NodeLite management shortcut' "$target" 2>/dev/null; then
    if [[ ! -f "$target" ]] || ! cmp -s "$alias" "$target"; then install -m 0755 "$alias" "$target"; changed=1; fi
    (( changed == 0 )) || ok "快捷命令已安装：node"
  else warn "检测到已有 Node.js：${existing}，未覆盖；请使用 nodelite"; fi
}

bootstrap_menu() {
  save_installer "$INSTALL_DIR/install.sh"
  install_shortcuts
  menu
}

write_environment() {
  local host="$1" port="$2" path="$3" user="$4" password="$5" secret="$6"
  mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/data" "$INSTALL_DIR/xray-config"
  chmod 700 "$INSTALL_DIR/data"
  cat >"$INSTALL_DIR/config/nodelite.env" <<EOF
RUNTIME_BACKEND=native
NODELITE_HOME=$INSTALL_DIR
DB_PATH=$INSTALL_DIR/data/panel.db
NETGUARD_DB_PATH=/var/lib/nodelite/netguard.db
NETGUARD_DB_IMMUTABLE=1
XRAY_CONFIG_PATH=$INSTALL_DIR/xray-config/config.json
PUBLIC_HOST=$host
ADMIN_USER=$user
${PASSWORD_KEY}=$password
${SECRET_KEY}=$secret
NETGUARD_REQUIRED=1
NETGUARD_SOCKET=/run/nodelite/netguard.sock
BACKGROUND_INTERVAL_SECONDS=2
PANEL_INTERNAL_PORT=$INTERNAL_PORT
UPSTREAM_HOST=127.0.0.1
UPSTREAM_PORT=$INTERNAL_PORT
LISTEN_HOST=0.0.0.0
LISTEN_PORT=$port
ACCESS_PATH=$path
EOF
  chmod 600 "$INSTALL_DIR/config/nodelite.env"
}

install_units() {
  mkdir -p "$SYSTEMD_DIR"
  local unit installed temporary
  for unit in "$INSTALL_DIR"/systemd/*.service; do
    installed="$SYSTEMD_DIR/$(basename "$unit")"
    if [[ "$SYSTEMD_DIR" == "/etc/systemd/system" ]] && [[ -e "$installed" ]] && ! grep -q '^Description=NodeLite' "$installed"; then
      die "拒绝覆盖非 NodeLite systemd unit：$installed"
    fi
    temporary="$(mktemp)"
    sed "s#/opt/nodelite#$INSTALL_DIR#g" "$unit" >"$temporary"
    install -m 0644 "$temporary" "$installed"
    rm -f "$temporary"
  done
  service_ctl daemon-reload
  service_ctl enable "${SERVICES[@]}"
}

service_states() {
  local unit state substate restarts result output=()
  for unit in "${SERVICES[@]}"; do
    state="$(service_ctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
    substate="$(service_ctl show "$unit" --property=SubState --value 2>/dev/null || true)"
    restarts="$(service_ctl show "$unit" --property=NRestarts --value 2>/dev/null || true)"
    result="$(service_ctl show "$unit" --property=Result --value 2>/dev/null || true)"
    output+=("${unit#nodelite-}=${state:-unknown}/${substate:-unknown},重启=${restarts:-0},结果=${result:-unknown}")
  done
  printf '%s' "${output[*]}"
}

diagnose_services() {
  local unit
  warn "NodeLite 服务诊断：$(service_states)"
  for unit in "${SERVICES[@]}"; do
    warn "$unit 最近日志："
    journalctl -u "$unit" --no-pager -n 12 2>/dev/null || service_ctl --no-pager --full status "$unit" || true
  done
}

service_crash_loop() {
  local unit="$1" state restarts result
  state="$(service_ctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
  restarts="$(service_ctl show "$unit" --property=NRestarts --value 2>/dev/null || true)"
  result="$(service_ctl show "$unit" --property=Result --value 2>/dev/null || true)"
  [[ "$state" == failed ]] || { [[ "$state" != active ]] && { [[ "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 0 ]] || [[ -n "$result" && "$result" != success ]]; }; }
}

wait_healthy() {
  local i unit response health="http://127.0.0.1:$(read_key "$INSTALL_DIR/config/nodelite.env" LISTEN_PORT)/healthz"
  for i in $(seq 1 45); do
    # Connection refused is expected for the first few seconds after systemd
    # starts the gateway. Capture it silently instead of presenting a normal
    # startup race as an installation error.
    response="$(curl -fs --connect-timeout 1 --max-time 3 "$health" 2>/dev/null || true)"
    if [[ "$response" == *'"status":"ok"'* ]]; then return 0; fi
    if (( i >= 3 )); then
      for unit in "${SERVICES[@]}"; do
        if service_crash_loop "$unit"; then
          diagnose_services
          die "$unit 启动后发生崩溃/重启，请查看上方日志"
        fi
      done
    fi
    if (( i >= 5 )) && [[ "$response" == *'"status":"degraded"'* ]]; then
      diagnose_services
      die "服务健康检查失败：$response"
    fi
    if (( i == 10 )); then
      for unit in "${SERVICES[@]}"; do
        if [[ "$(service_ctl show "$unit" --property=ActiveState --value 2>/dev/null || true)" != active ]]; then
          diagnose_services
          die "$unit 10 秒内未进入 active 状态"
        fi
      done
    fi
    (( i % 5 != 0 )) || info "服务启动中（${i} 秒）：$(service_states)"
    sleep 1
  done
  diagnose_services
  die "服务 45 秒内未恢复健康，请查看上方状态"
}
show_access() {
  local f="$INSTALL_DIR/config/nodelite.env" host port path user password
  host="$(read_key "$f" PUBLIC_HOST)"; port="$(read_key "$f" LISTEN_PORT)"; path="$(read_key "$f" ACCESS_PATH)"
  user="$(read_key "$f" ADMIN_USER)"; password="$(read_key "$f" "$PASSWORD_KEY")"
  [[ -n "$host" && -n "$port" && -n "$path" && -n "$user" && -n "$password" ]] || die "登录信息不完整，请运行 node 重设后台账号密码"
  printf '\n访问地址：http://%s:%s/%s/login\n用户名：%s\n密码：%s\n安装目录：%s\n\n' \
    "$host" "$port" "$path" "$user" "$password" "$INSTALL_DIR"
}

install_or_update() {
  ensure_tools
  ensure_nft
  local old="$INSTALL_DIR/config/nodelite.env" arch tag url tmp host port path user password secret old_internal had_existing=0 release_dir backup_dir
  [[ -f "$old" ]] && had_existing=1
  arch="$(asset_arch)"; tag="$(latest_tag)"; [[ -n "$tag" ]] || die "无法获取最新 GitHub Release"
  url="${NODELITE_ASSET_URL:-https://github.com/$REPO/releases/download/$tag/nodelite-linux-$arch.tar.gz}"
  host="${PUBLIC_HOST:-$(read_key "$old" PUBLIC_HOST)}"; [[ -n "$host" ]] || host="$(curl -4fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
  port="${PANEL_PORT:-$(read_key "$old" LISTEN_PORT)}"; port="${port:-$(random_high_port)}"; valid_port "$port" || die "端口必须为 1-65535"
  path="${ACCESS_PATH:-$(read_key "$old" ACCESS_PATH)}"; path="${path:-$(random_path)}"; path="$(normalize_path "$path")" || die "随机路径格式错误"
  user="${ADMIN_USER:-$(read_key "$old" ADMIN_USER)}"; user="${user:-admin}"
  password="${!PASSWORD_KEY:-$(read_key "$old" "$PASSWORD_KEY")}"; password="${password:-$(random_password)}"
  secret="${!SECRET_KEY:-$(read_key "$old" "$SECRET_KEY")}"; secret="${secret:-$(random_secret)}"
  old_internal="$(read_key "$old" PANEL_INTERNAL_PORT)"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
  info "下载原生发行包：$url"
  download_native_asset "$tag" "$arch" "$tmp/release.tar.gz"
  release_dir="$tmp/release"; backup_dir="$tmp/runtime-state"
  mkdir -p "$release_dir"
  tar -xzf "$tmp/release.tar.gz" -C "$release_dir"
  validate_release_compatibility "$release_dir" "$arch"
  backup_runtime_state "$backup_dir"
  stop_legacy_docker
  stop_native_for_upgrade
  preflight_port "$port"
  choose_internal_port "$old_internal"
  install_release_code "$release_dir"
  # The running script is the source of truth for the management CLI.  Do not
  # compare it to the tarball copy (that copy is intentionally not installed).
  save_installer "$INSTALL_DIR/install.sh"
  [[ -s "$INSTALL_DIR/VERSION" ]] || die "安装后的版本文件缺失；拒绝报告更新成功"
  [[ "$(cat "$INSTALL_DIR/VERSION")" == "$tag" ]] || \
    die "安装后版本不匹配：期望 ${tag}，实际 $(installed_version)"
  [[ -s "$INSTALL_DIR/BUILD_COMMIT" ]] || die "安装后的构建提交标记缺失；拒绝报告更新成功"
  bash -n "$INSTALL_DIR/install.sh" || die "安装后的管理脚本语法检查失败"
  write_environment "$host" "$port" "$path" "$user" "$password" "$secret"
  if [[ ! -s "$INSTALL_DIR/xray-config/config.json" ]]; then
    cat >"$INSTALL_DIR/xray-config/config.json" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}
JSON
  fi
  install_units
  service_ctl restart nodelite-netguard.service nodelite-panel.service nodelite-xray.service nodelite-gateway.service
  wait_healthy
  svcb_enable || true
  install_shortcuts
  ok "NodeLite 原生版安装/更新完成（$(installed_version) / ${arch}）"; show_access
  (( had_existing == 1 )) || printf '密码：%s\n' "$password"
}

change_value_restart() {
  require_native; set_key "$INSTALL_DIR/config/nodelite.env" "$1" "$2"; service_ctl restart "${@:3}"; wait_healthy
}
change_credentials() { require_native; local u="${2:-}" p="${3:-}"; [[ -n "$u" ]] || read -r -p "新用户名 [admin]: " u; [[ -n "$p" ]] || { read -r -s -p "新密码（留空随机）: " p; echo; }; u="${u:-admin}"; p="${p:-$(random_password)}"; set_key "$INSTALL_DIR/config/nodelite.env" ADMIN_USER "$u"; change_value_restart "$PASSWORD_KEY" "$p" nodelite-panel.service; printf '用户名：%s\n密码：%s\n' "$u" "$p"; }
change_port() { require_native; local v="${2:-}"; [[ -n "$v" ]] || read -r -p "新端口: " v; valid_port "$v" || die "端口错误"; change_value_restart LISTEN_PORT "$v" nodelite-gateway.service; show_access; }
change_path() { require_native; local v="${2:-$(random_path)}"; v="$(normalize_path "$v")" || die "路径错误"; change_value_restart ACCESS_PATH "$v" nodelite-gateway.service; show_access; }
change_host() { require_native; local v="${2:-}"; [[ -n "$v" ]] || read -r -p "公网 IP/域名: " v; [[ -n "$v" && ! "$v" =~ [[:space:]/] ]] || die "地址错误"; change_value_restart PUBLIC_HOST "$v" nodelite-panel.service; show_access; }
show_status() { require_native; service_ctl --no-pager --full status "${SERVICES[@]}" || true; show_access; }
restart_services() { require_native; service_ctl restart "${SERVICES[@]}"; wait_healthy; ok "NodeLite 已重启"; }

install_docker_mode() {
  warn "Docker 是可选兼容模式，不是默认安装方式。"
  local answer; read -r -p "确认安装/更新 Docker 兼容模式？[y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return
  ensure_tools; command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  command -v git >/dev/null || die "Docker 兼容模式需要 git"
  local dir="${NODELITE_DOCKER_DIR:-/opt/nodelite-docker}"
  [[ -d "$dir/.git" ]] && { git -C "$dir" fetch origin main; git -C "$dir" reset --hard origin/main; } || git clone "https://github.com/$REPO.git" "$dir"
  (cd "$dir" && NODELITE_DIR="$dir" bash install-docker.sh install)
}

run_ip_check() {
  clear
  cat <<'EOF'
=== IP质量检测 - 仅IPv4 ===

正在运行 IP 质量检测脚本（仅 IPv4）...
------------------------------------------------

EOF
  if bash <(curl -fsSL "https://IP.Check.Place") -4; then
    echo ""
    echo "------------------------------------------------"
    ok "IP 检测完成"
  else
    echo ""
    echo "------------------------------------------------"
    warn "脚本执行失败"
  fi
  echo ""
  read -r -p "按 Enter 键继续..."
}

ensure_network_tools() {
  command -v sysctl >/dev/null 2>&1 && return 0
  warn "网络设置需要 sysctl，正在安装缺失依赖"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y procps-ng
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache procps
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install procps
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm procps-ng
  else
    die "未找到受支持的包管理器；请先安装 procps/sysctl 后重试"
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

run_tcpfit() {
  cat <<'EOF'
TCPFit 是第三方系统调优工具，可能修改 sysctl、tc、systemd 与 swap，并可能造成 SSH 波动。
请确保有云控制台/KVM 回退。NodeLite 永不自动执行 TCPFit。
EOF
  local answer; read -r -p "确认进入 TCPFit 菜单？[y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return
  ensure_tools; ensure_git
  local commit tmp sha; commit="$(git ls-remote https://github.com/Kylin010/tcpfit.git refs/heads/main | awk 'NR==1{print $1}')"; [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "无法固定 TCPFit 提交"
  tmp="$(mktemp)"; curl -fsSL "https://raw.githubusercontent.com/Kylin010/tcpfit/$commit/tcpfit.sh" -o "$tmp"; bash -n "$tmp"; sha="$(sha256sum "$tmp" | awk '{print $1}')"; printf '提交：%s\nSHA256：%s\n' "$commit" "$sha"; bash "$tmp"; rm -f "$tmp"
}

uninstall_nodelite() {
  require_native; local answer remove; read -r -p "输入 YES 确认卸载: " answer; [[ "$answer" == YES ]] || return; read -r -p "删除数据？[y/N]: " remove
  "$INSTALL_DIR/bin/nodelite-netguard" rollback >/dev/null 2>&1 || true
  service_ctl disable --now "${SERVICES[@]}" || true
  local shortcut unit_path; for shortcut in "$BIN_DIR/node" "$BIN_DIR/nodelite"; do grep -q 'NodeLite management shortcut' "$shortcut" 2>/dev/null && rm -f "$shortcut"; done
  for unit_path in "${SERVICES[@]}"; do rm -f "$SYSTEMD_DIR/$unit_path"; done
  service_ctl daemon-reload
  if [[ "$remove" =~ ^[Yy]$ ]]; then rm -rf --one-file-system "$INSTALL_DIR"; else warn "数据保留在 $INSTALL_DIR"; fi
  ok "NodeLite 已卸载，Netguard 规则已回滚"
}

menu() {
  while true; do printf '\n当前版本：%s\n' "$(installed_version)"; cat <<'EOF'

============== NodeLite 原生管理菜单 ==============
  1. 安装 / 更新（默认原生 systemd）
  2. 修改管理员账号密码
  3. 修改访问端口
  4. 更换随机访问目录
  5. 修改公网 IP / 域名
  6. 查看状态与访问地址
  7. 重启 NodeLite
  8. TCPFit 网络调优（第三方）
  9. IP检测（IPv4质量检测）
 10. 一键开启 BBR
 11. 一键关闭 IPv6
 12. 卸载 NodeLite
 13. 可选 Docker 兼容安装
 14. 屏蔽 SVCB/HTTPS DNS 记录（防 Fake-IP 直连与 QUIC 旁路）
 15. 取消 SVCB/HTTPS 屏蔽
  0. 退出
===================================================
EOF
  local c; read -r -p "请选择: " c; case "$c" in 1) install_or_update;; 2) change_credentials;; 3) change_port;; 4) change_path;; 5) change_host;; 6) show_status;; 7) restart_services;; 8) run_tcpfit;; 9) run_ip_check;; 10) enable_bbr_fq;; 11) disable_ipv6;; 12) uninstall_nodelite;; 13) install_docker_mode;; 14) svcb_enable;; 15) svcb_disable;; 0) exit;; *) warn "无效选项";; esac; done
}

command="${1:-}"; case "$command" in "") [[ -t 0 ]] && bootstrap_menu || install_or_update;; install|update) install_or_update;; shortcuts) install_shortcuts;; credentials) change_credentials "$@";; port) change_port "$@";; path) change_path "$@";; host) change_host "$@";; status) show_status;; restart) restart_services;; tcpfit) run_tcpfit;; ipcheck) run_ip_check;; disable-ipv6) disable_ipv6;; enable-bbr-fq) enable_bbr_fq;; uninstall) uninstall_nodelite;; docker) install_docker_mode;; menu) bootstrap_menu;; dns-block) svcb_enable;; dns-unblock) svcb_disable;; dns-status) svcb_status;; *) die "用法: install.sh [install|credentials|port|path|host|status|restart|tcpfit|ipcheck|disable-ipv6|enable-bbr-fq|dns-block|dns-unblock|dns-status|uninstall|docker|shortcuts|menu]";; esac
