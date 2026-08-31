#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${NODELITE_GITHUB_REPO:-dabao9037/nodelite}"
INSTALL_DIR="${NODELITE_DIR:-/opt/nodelite}"
SYSTEMD_DIR="${NODELITE_SYSTEMD_DIR:-/etc/systemd/system}"
BIN_DIR="${NODELITE_BIN_DIR:-/usr/local/bin}"
DEFAULT_PORT=2060
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
normalize_path() { local v="${1#/}"; v="${v%/}"; [[ "$v" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || return 1; printf '%s' "$v"; }
read_key() { [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" | tail -n1 || true; }
set_key() { local f="$1" k="$2" v="$3" t; t="$(mktemp)"; [[ ! -f "$f" ]] || grep -v "^${k}=" "$f" >"$t" || true; printf '%s=%s\n' "$k" "$v" >>"$t"; install -m 600 "$t" "$f"; rm -f "$t"; }
have_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
service_ctl() { have_systemd || die "原生模式需要 systemd"; systemctl "$@"; }

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

asset_arch() {
  case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) die "暂不支持架构：$(uname -m)";; esac
}
latest_tag() {
  [[ -n "${NODELITE_VERSION:-}" ]] && { echo "$NODELITE_VERSION"; return; }
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}
require_native() { [[ -f "$INSTALL_DIR/config/nodelite.env" && -x "$INSTALL_DIR/bin/nodelite-panel" ]] || die "NodeLite 原生版尚未安装"; }

save_installer() {
  local destination="$1" source="${BASH_SOURCE[0]:-}"
  mkdir -p "$(dirname "$destination")"
  [[ "$source" == "$destination" ]] && bash -n "$destination" 2>/dev/null && return 0
  case "$source" in
    ""|bash|/bin/bash|/usr/bin/bash|/dev/fd/*|/proc/*/fd/*) source="" ;;
  esac
  if [[ -n "$source" && -f "$source" && -r "$source" ]]; then
    install -m 0755 "$source" "$destination"
  else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" -o "$destination"
    chmod 0755 "$destination"
  fi
  bash -n "$destination" || die "保存的 NodeLite 管理脚本不完整"
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
    die "请先释放端口 $port，或用 PANEL_PORT=其他端口 重新安装"
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
  else warn "检测到已有 Node.js：$existing，未覆盖；请使用 nodelite"; fi
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
  local f="$INSTALL_DIR/config/nodelite.env"
  printf '\n访问地址：http://%s:%s/%s/login\n用户名：%s\n安装目录：%s\n\n' \
    "$(read_key "$f" PUBLIC_HOST)" "$(read_key "$f" LISTEN_PORT)" "$(read_key "$f" ACCESS_PATH)" "$(read_key "$f" ADMIN_USER)" "$INSTALL_DIR"
}

install_or_update() {
  ensure_tools
  local old="$INSTALL_DIR/config/nodelite.env" arch tag url tmp host port path user password secret old_internal had_existing=0
  [[ -f "$old" ]] && had_existing=1
  arch="$(asset_arch)"; tag="$(latest_tag)"; [[ -n "$tag" ]] || die "无法获取最新 GitHub Release"
  url="${NODELITE_ASSET_URL:-https://github.com/$REPO/releases/download/$tag/nodelite-linux-$arch.tar.gz}"
  host="${PUBLIC_HOST:-$(read_key "$old" PUBLIC_HOST)}"; [[ -n "$host" ]] || host="$(curl -4fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
  port="${PANEL_PORT:-$(read_key "$old" LISTEN_PORT)}"; port="${port:-$DEFAULT_PORT}"; valid_port "$port" || die "端口必须为 1-65535"
  path="${ACCESS_PATH:-$(read_key "$old" ACCESS_PATH)}"; path="${path:-$(random_path)}"; path="$(normalize_path "$path")" || die "随机路径格式错误"
  user="${ADMIN_USER:-$(read_key "$old" ADMIN_USER)}"; user="${user:-admin}"
  password="${!PASSWORD_KEY:-$(read_key "$old" "$PASSWORD_KEY")}"; password="${password:-$(random_password)}"
  secret="${!SECRET_KEY:-$(read_key "$old" "$SECRET_KEY")}"; secret="${secret:-$(random_secret)}"
  old_internal="$(read_key "$old" PANEL_INTERNAL_PORT)"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
  info "下载原生发行包：$url"; curl -fL --retry 3 "$url" -o "$tmp/release.tar.gz"
  tar -tzf "$tmp/release.tar.gz" >/dev/null
  stop_legacy_docker
  stop_native_for_upgrade
  preflight_port "$port"
  choose_internal_port "$old_internal"
  mkdir -p "$INSTALL_DIR"; tar -xzf "$tmp/release.tar.gz" -C "$INSTALL_DIR"
  save_installer "$INSTALL_DIR/install.sh"
  write_environment "$host" "$port" "$path" "$user" "$password" "$secret"
  if [[ ! -s "$INSTALL_DIR/xray-config/config.json" ]]; then
    cat >"$INSTALL_DIR/xray-config/config.json" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}
JSON
  fi
  install_units
  service_ctl restart nodelite-netguard.service nodelite-panel.service nodelite-xray.service nodelite-gateway.service
  wait_healthy; ok "NodeLite 原生版安装/更新完成（$tag / $arch）"; show_access
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

run_tcpfit() {
  cat <<'EOF'
TCPFit 是第三方系统调优工具，可能修改 sysctl、tc、systemd 与 swap，并可能造成 SSH 波动。
请确保有云控制台/KVM 回退。NodeLite 永不自动执行 TCPFit。
EOF
  local answer; read -r -p "确认进入 TCPFit 菜单？[y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return
  ensure_tools; local commit tmp sha; commit="$(git ls-remote https://github.com/Kylin010/tcpfit.git refs/heads/main | awk 'NR==1{print $1}')"; [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "无法固定 TCPFit 提交"
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
  while true; do cat <<'EOF'

============== NodeLite 原生管理菜单 ==============
  1. 安装 / 更新（默认原生 systemd）
  2. 修改管理员账号密码
  3. 修改访问端口
  4. 更换随机访问目录
  5. 修改公网 IP / 域名
  6. 查看状态与访问地址
  7. 重启 NodeLite
  8. TCPFit 网络调优（第三方）
  9. 卸载 NodeLite
 10. 可选 Docker 兼容安装
  0. 退出
===================================================
EOF
  local c; read -r -p "请选择: " c; case "$c" in 1) install_or_update;; 2) change_credentials;; 3) change_port;; 4) change_path;; 5) change_host;; 6) show_status;; 7) restart_services;; 8) run_tcpfit;; 9) uninstall_nodelite;; 10) install_docker_mode;; 0) exit;; *) warn "无效选项";; esac; done
}

command="${1:-}"; case "$command" in "") [[ -t 0 ]] && bootstrap_menu || install_or_update;; install|update) install_or_update;; credentials) change_credentials "$@";; port) change_port "$@";; path) change_path "$@";; host) change_host "$@";; status) show_status;; restart) restart_services;; tcpfit) run_tcpfit;; uninstall) uninstall_nodelite;; docker) install_docker_mode;; menu) bootstrap_menu;; *) die "用法: install.sh [install|credentials|port|path|host|status|restart|tcpfit|uninstall|docker|menu]";; esac
