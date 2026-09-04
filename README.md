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
  PUBLIC_HOST=node.example.com ADMIN_USER=admin bash
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
11. 一键关闭 IPv6
12. 一键开启 BBR + fq
0. 退出
```

访问地址类似：

```text
http://服务器IP:随机高位端口/panel-a1b2c3d4e5f6a7b8/login
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

## 单节点流量上限

创建或编辑节点时可选填“流量上限 (MB)”，范围为 `1..1,000,000,000`；留空表示不限。流量按 Xray 为该节点记录的**上传 + 下载累计总量**计算，`1 MB = 1024 × 1024 bytes`。

- 达到或超过上限后，NodeLite 会在后台采样周期内自动停用节点，并重建 Xray 配置、同步 Netguard。
- 累计值使用数据库持久基线，Xray/NodeLite 重启或原始 counter 回退不会归零，也不会重复计费。
- NodeLite 会记录明确的停用原因，区分手动停用、到期停用和流量超限停用；升级旧数据库时只对可由持久计数明确证明的超限节点推断为流量停用，其他旧停用节点按手动停用保守处理。
- 因流量超限自动停用的节点，提高上限且当前已用流量低于新上限时会自动启用；清除上限也会自动启用，并立即重建 Xray 配置、同步 Netguard。
- 编辑上限默认保留已使用流量。若提高后仍达到或超过新上限，节点继续停用；普通编辑、提高或清除上限都不会误启用手动停用的节点。
- “重置流量”会把面板已用量归零，同时把当前 Xray counter 记为新的原始基准，避免下一次采样重新计入历史流量；节点未到期时会自动启用，并立即重建 Xray 配置、同步 Netguard。
- 已到期节点绝不会因重置流量、提高上限或清除上限而自动启用，必须先把有效期修改到未来。

认证 API：

```text
POST /api/nodes/{id}/traffic/reset
```

## Release 构建

`.github/workflows/native-release.yml` 在发布 Release 时为 amd64/arm64 构建并上传 tarball。也可以本地构建：

```bash
bash scripts/build-native-release-container.sh amd64
```

构建脚本在 Debian 11 / GLIBC 2.31 容器中创建隔离 venv，安装 `requirements-native.txt` 和 PyInstaller，生成 three one-dir 应用，然后下载并嵌入 Xray 26.6.27。发布门禁会扫描包内全部 ELF，拒绝高于 GLIBC 2.31 的依赖；目标服务器无需 Python、pip 或编译器。

## Reality 伪装目标

内置目标继续遵循“小众境外网站优先”的筛选方向，按地区分组，每个地区提供两个候选：

- 美国：Atlas Obscura（小众旅行）、Backblaze（小众云存储企业）
- 英国：Jodrell Bank（天文研究）、Science Museum（科学教育）
- 日本：Animate Times（二次元资讯）、Famitsu（游戏资讯）
- 东南亚：A*STAR（新加坡科研）、Visit Singapore（旅游）
- 欧洲：CERN（瑞士科研）、GOG（波兰游戏平台）
- 香港：HKSTP（香港科技园）、Discover Hong Kong（旅游）
- 自定义

候选方向集中在学术研究、旅游、二次元、游戏和小众企业，避免把 Apple、Microsoft、BBC 等大型通用站点作为内置预设。发布前检查 DNS、443、TLS 1.3 和证书主机名匹配；Reality 目标的实际可用性仍受服务器出口与站点策略影响，部署后应使用真实客户端测试。

## TCPFit

TCPFit 来自 <https://github.com/Kylin010/tcpfit>，不是 NodeLite 组成部分。NodeLite 永不自动执行；菜单会先说明网络/SSH 风险并确认，再固定上游 commit、做 `bash -n` 并显示 SHA256。请准备云控制台/KVM 回退。

## 一键网络设置

- “一键关闭 IPv6”会设置 `net.ipv6.conf.all.disable_ipv6=1` 和 `net.ipv6.conf.default.disable_ipv6=1`。
- “一键开启 BBR + fq”会先确认当前内核提供 BBR，再设置 `net.ipv4.tcp_congestion_control=bbr` 和 `net.core.default_qdisc=fq`。
- 两项操作都会先提示确认，立即应用并校验结果，同时分别写入 `/etc/sysctl.d/99-zz-nodelite-*.conf` 持久化；不会覆盖其他 sysctl 文件。重复执行是幂等的。
- 也可直接执行 `sudo nodelite disable-ipv6` 或 `sudo nodelite enable-bbr-fq`；自动化环境可显式设置 `NODELITE_ASSUME_YES=1` 跳过确认。

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
