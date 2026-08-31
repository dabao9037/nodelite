#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${NODELITE_REPO_URL:-https://github.com/dabao9037/nodelite.git}"
INSTALL_DIR="${NODELITE_DIR:-/opt/nodelite}"
PANEL_PORT="${PANEL_PORT:-2060}"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install.sh" >&2
  exit 1
fi

if [[ ! "$PANEL_PORT" =~ ^[0-9]+$ ]] || (( PANEL_PORT < 1 || PANEL_PORT > 65535 )); then
  echo "PANEL_PORT 必须是 1-65535 的端口" >&2
  exit 1
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git openssl
  else
    echo "仅支持 apt、dnf 或 yum 系统" >&2
    exit 1
  fi
}

install_docker() {
  command -v curl >/dev/null 2>&1 || install_packages
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || service docker start
}

command -v git >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || install_packages
command -v docker >/dev/null 2>&1 || install_docker
docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose 插件不可用，请先安装 Docker Compose v2" >&2
  exit 1
}

PUBLIC_HOST="${PUBLIC_HOST:-}"
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
fi
[[ -n "$PUBLIC_HOST" ]] || { echo "无法检测公网 IP，请使用 PUBLIC_HOST=域名或IP 重新执行" >&2; exit 1; }

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n=/+' | cut -c1-20)}"
APP_SECRET="${APP_SECRET:-$(openssl rand -hex 32)}"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" fetch --depth=1 origin main
  git -C "$INSTALL_DIR" reset --hard origin/main
elif [[ -e "$INSTALL_DIR" ]]; then
  echo "安装目录已存在且不是 NodeLite Git 仓库：$INSTALL_DIR" >&2
  exit 1
else
  git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
cat >.env <<EOF
PUBLIC_HOST=$PUBLIC_HOST
PANEL_PORT=$PANEL_PORT
EOF
cat >.env.credentials <<EOF
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
APP_SECRET=$APP_SECRET
EOF
chmod 600 .env .env.credentials
mkdir -p data xray-config
chmod 700 data
# Xray runs as uid 65532 and must be able to traverse this bind-mounted
# directory. Config files themselves contain no panel credentials.
chmod 755 xray-config

docker compose up -d --build

for attempt in $(seq 1 60); do
  panel_health="$(docker inspect simple-node-panel --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  xray_health="$(docker inspect simple-node-xray --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  netguard_health="$(docker inspect simple-node-netguard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [[ "$panel_health" == healthy && "$xray_health" == healthy && "$netguard_health" == healthy ]]; then
    break
  fi
  if [[ "$attempt" == 60 ]]; then
    docker compose ps -a
    docker compose logs --tail=150 panel xray netguard
    exit 1
  fi
  sleep 5
done

cat <<EOF

NodeLite 安装完成
访问地址：http://$PUBLIC_HOST:$PANEL_PORT/login
用户名：$ADMIN_USER
密码：$ADMIN_PASSWORD
安装目录：$INSTALL_DIR

请立即保存密码；凭据文件位于 $INSTALL_DIR/.env.credentials
EOF
