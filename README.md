# NodeLite

一个轻量的自托管节点管理面板，支持：

- SOCKS5
- Shadowsocks 2022
- VLESS + REALITY + XTLS Vision
- 节点创建、编辑、启停、删除和二维码
- 流量累计、实时速率和当前 TCP 连接数
- 节点有效期与到期自动停用
- 每节点最大并发连接限制
- 根路径与反向代理子路径部署

> 仅用于你有权管理的服务器和合规网络环境。请遵守当地法律、服务商条款及组织安全政策。

## 技术栈

- FastAPI + SQLite
- Docker Compose
- Xray Core `26.2.6`
- 独立 Netguard 容器，通过 iptables `connlimit` 管理每节点连接上限

## 一键安装

要求：Ubuntu、Debian、CentOS、Rocky Linux 或 AlmaLinux，使用 root 运行。

```bash
curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh | bash
```

默认使用服务器公网 IPv4、端口 `2060`，并自动生成登录密码。也可以自定义：

```bash
curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh | PUBLIC_HOST=node.example.com PANEL_PORT=2060 ADMIN_USER=admin bash
```

安装完成后，终端会显示访问地址、用户名和随机密码。

## 手动安装

### 1. 准备配置

```bash
cp .env.example .env
cp .env.credentials.example .env.credentials
```

编辑 `.env`：

```dotenv
PUBLIC_HOST=node.example.com
PANEL_PORT=2060
```

编辑 `.env.credentials`，设置强密码和随机签名密钥：

```dotenv
ADMIN_USER=admin
ADMIN_PASSWORD=replace-with-a-strong-password
APP_SECRET=replace-with-a-long-random-secret
```

可用下面的命令生成随机值：

```bash
openssl rand -base64 32
```

### 2. 创建运行目录

```bash
mkdir -p data xray-config
chmod 700 data xray-config
chmod 600 .env.credentials
```

### 3. 启动

```bash
docker compose up -d --build
```

打开：

```text
http://服务器地址:2060/login
```

### 4. 检查状态

```bash
docker compose ps
docker compose logs --tail=100 panel netguard xray
```

## REALITY 伪装目标

当前内置预设：

- Apple（默认）
- Amazon
- Cloudflare
- Mozilla Add-ons
- Bing
- Google
- 自定义域名

预设域名是否适合某台服务器取决于服务器出口网络、目标 TLS 行为和 Xray 版本，部署前后都应实测。当前列表已移除在生产真实 VLESS 链路测试中失败的 Microsoft 和 Oracle，并加入通过 TLS 1.3、真实代理 HTTPS 和流量计数验证的 Bing 与 Google。

Cloudflare 属于 CDN 目标。Xray 官方文档提醒：使用 CDN 目标时，未通过 REALITY 验证的连接可能被转发至目标，存在被滥用的风险。公网部署时应结合前置过滤、访问控制与日志监控评估使用。

## 反向代理子路径

面板支持由反向代理传入：

```http
X-Forwarded-Prefix: /node-panel
```

Nginx 示例：

```nginx
location /node-panel/ {
    proxy_pass http://127.0.0.1:2060/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Prefix /node-panel;
}
```

访问地址：

```text
https://node.example.com/node-panel/login
```

## 测试

本机有 Python 环境时：

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

或直接使用容器运行测试：

```bash
docker build --target test -t nodelite-test .
docker run --rm nodelite-test
```

## 发布门禁

`deploy.sh` 会执行：

1. Python 编译检查
2. 损坏标记检查
3. 测试镜像与 pytest
4. 无缓存构建
5. 服务健康检查
6. 宿主、镜像和运行容器关键文件 SHA256 对比

运行：

```bash
./deploy.sh
```

## 安全说明

- `.env.credentials`、数据库、Xray 运行配置和备份已在 `.gitignore` / `.dockerignore` 中排除。
- `panel` 为重建 Xray 配置需要访问 Docker Socket。Docker Socket 等同于较高的宿主权限；只应在可信服务器部署，并限制面板暴露范围。
- `netguard` 使用 host network、`NET_ADMIN` 和 `NET_RAW` 管理连接限制，不挂载 Docker Socket。
- 上线前务必修改示例凭据，建议只通过 HTTPS 反向代理访问，并配合防火墙限制管理入口。
- 不要把生产数据库、`.env.credentials`、私钥、节点分享链接或 `xray-config/` 提交到 GitHub。

## 项目结构

```text
app/                 FastAPI 后端与静态页面
netguard/            每节点连接限制守护进程
scripts/             REALITY 验收辅助脚本
tests/               pytest 测试
Dockerfile           多阶段构建（测试/运行）
docker-compose.yml   Panel、Netguard、Xray 服务
deploy.sh             发布门禁脚本
```

## License

MIT
