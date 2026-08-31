# NodeLite

轻量级自托管代理节点面板，支持 SOCKS5、Shadowsocks 2022 和 VLESS REALITY。

## 默认：原生 systemd，无 Docker

NodeLite 现在默认采用类似 x-ui 的原生安装：下载 GitHub Release 预构建 tarball 到 `/opt/nodelite`，不安装 Docker，也不在目标机运行 `pip`。发行包包含：

- PyInstaller one-dir 形式的 Panel、随机路径 Gateway、Netguard
- Xray Core **26.6.27**
- 四个 systemd unit：`nodelite-panel`、`nodelite-gateway`、`nodelite-xray`、`nodelite-netguard`
- Panel 仅监听 `127.0.0.1:18080`；Gateway 在公开端口监听并只转发随机 `ACCESS_PATH`
- Netguard 原生 daemon；数据库尚未创建时可启动，健康检查严格验证 iptables chain/jump，退出和卸载均 rollback

支持 linux-amd64 和 linux-arm64；安装器会检测架构并优先下载最新 Release 的 `nodelite-linux-<arch>.tar.gz`。目标机只在缺少 `curl`/`tar`/`openssl` 等基础工具时安装少量软件包。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh)
```

非交互安装：

```bash
curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh | \
  PUBLIC_HOST=node.example.com PANEL_PORT=2060 ADMIN_USER=admin bash
```

可用 `NODELITE_VERSION=vX.Y.Z` 固定 Release。安装后执行 `node`；若已有 Node.js，绝不覆盖 `/usr/local/bin/node`，改用 `nodelite`。

菜单：

```text
1. 安装 / 更新（默认原生 systemd）
2. 修改管理员账号密码
3. 修改访问端口
4. 更换随机访问目录
5. 修改公网 IP / 域名
6. 查看状态与访问地址
7. 重启 NodeLite
8. TCPFit 网络调优（第三方，明确确认后才执行）
9. 卸载 NodeLite
10. 可选 Docker 兼容安装
0. 退出
```

访问地址类似：

```text
http://服务器IP:2060/panel-a1b2c3d4e5f6a7b8/login
```

裸 `IP:端口` 返回 404。随机目录不是身份认证替代品，请仍使用强密码并配置防火墙。

## Docker 兼容模式

Docker Compose 仍然受支持，但不再是默认安装方式：

```bash
sudo bash install.sh docker
# 或直接运行兼容安装器
sudo bash install-docker.sh install
```

Compose 会显式设置 `RUNTIME_BACKEND=docker`；Panel 在该模式才动态导入 Docker SDK/访问 Docker API。原生模式不会导入或调用 Docker。

手动 Compose：

```bash
git clone https://github.com/dabao9037/nodelite.git
cd nodelite
cp .env.example .env
cp .env.credentials.example .env.credentials
mkdir -p data xray-config
chmod 700 data && chmod 755 xray-config
chmod 600 .env .env.credentials
docker compose up -d --build
```

## 运行后端

- `RUNTIME_BACKEND=native`（默认）：只允许固定的 `systemctl is-active/restart` 操作，服务名严格限定为 `nodelite-xray.service`、`nodelite-netguard.service`；Xray 和 Netguard 通过 `/opt/nodelite/bin` 下固定程序调用。
- `RUNTIME_BACKEND=docker`：保留原容器 exec/restart 行为。
- `/healthz` 同时要求数据库、Xray、Netguard 健康，否则返回 HTTP 503 和 `status=degraded`。
- 每次节点配置变更先用 Xray `run -test` 验证，成功后才重启 Xray；失败恢复旧配置。

## Release 构建

`.github/workflows/native-release.yml` 在发布 Release 时为 amd64/arm64 构建并上传 tarball。也可以本地构建：

```bash
bash scripts/build-native-release.sh amd64
```

构建脚本创建隔离 venv，安装 `requirements-native.txt` 和 PyInstaller，生成 three one-dir 应用，然后下载并嵌入 Xray 26.6.27。目标服务器无需 Python、pip 或编译器。

## Reality 伪装目标

内置预设改为相对小众、但仍由稳定机构长期运营的境外站点：

- CERN（欧洲核子研究中心，默认）
- Nature（学术出版）
- Visit Finland（芬兰旅游）
- Anime News Network（动漫资讯）
- GOG（游戏发行平台）
- Backblaze（云存储企业）
- 自定义

这些候选覆盖学术、旅游、游戏和小众企业方向，并要求证书与 SNI 匹配、支持 TLS 1.3。Reality 目标的可用性会随服务器出口网络和目标站点策略变化，部署后仍应使用真实客户端测试。随机、小型个人站点可能随时下线，不建议作为长期默认目标。

## TCPFit

TCPFit 来自 <https://github.com/Kylin010/tcpfit>，不是 NodeLite 组成部分。NodeLite 永不自动执行；菜单会先说明网络/SSH 风险并确认，再固定上游 commit、做 `bash -n` 并显示 SHA256。请准备云控制台/KVM 回退。

## 测试

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
PYTHONPATH=. pytest -q
bash -n install.sh install-docker.sh scripts/*.sh
python -m py_compile app/main.py netguard/netguard.py gateway/server.py native/*.py
bash scripts/test-native-smoke.sh
```

真实空目录 Compose 门禁（需要 root/Docker）：

```bash
sudo NODELITE_FRESH_INSTALL_TEST=1 bash scripts/test-fresh-install.sh
```

## License

MIT
