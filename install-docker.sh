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
    uninstall) uninstall_nodelite ;;
    menu) menu ;;
    *) die "用法: install.sh [install|credentials|port|path|host|status|restart|tcpfit|disable-ipv6|enable-bbr-fq|uninstall|menu]" ;;
  esac
fi
