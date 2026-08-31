# NodeLite

轻量级自托管代理节点面板，支持 SOCKS5、Shadowsocks 2022 和 VLESS REALITY。

## 主要能力

- SOCKS5、Shadowsocks 2022、VLESS REALITY 节点创建与管理
- 节点二维码、链接、启停、到期时间、流量与连接数统计
- 每节点连接数限制
- 随机后台访问目录：裸 `IP:端口` 返回 404
- 菜单式安装、更新和维护
- Xray Core `26.6.27`
- 独立 Netguard 容器，通过 iptables `connlimit` 管理连接限制

## 一键菜单

要求 root 权限，支持 Ubuntu、Debian、CentOS、Rocky Linux 和 AlmaLinux：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh)
```

菜单包括：

```text
1. 安装 / 更新
2. 修改管理员账号密码
3. 修改访问端口
4. 更换随机访问目录
5. 修改公网 IP / 域名
6. 查看运行状态与访问地址
7. 重启 NodeLite
8. TCPFit 网络调优（第三方，可回滚）
9. 卸载 NodeLite
0. 退出
```

安装后会显示类似地址：

```text
http://服务器IP:2060/panel-a1b2c3d4e5f6a7b8/login
```

直接访问 `http://服务器IP:2060/` 会返回 404。随机目录不是身份认证的替代品，仍需使用强密码并限制防火墙来源。

### 非交互安装

管道执行仍保持兼容：

```bash
curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh | bash
```

可自定义：

```bash
curl -fsSL https://raw.githubusercontent.com/dabao9037/nodelite/main/install.sh \
  | PUBLIC_HOST=node.example.com PANEL_PORT=2060 ACCESS_PATH=panel-my-secret ADMIN_USER=admin bash
```

命令行管理示例：

```bash
sudo /opt/nodelite/install.sh status
sudo /opt/nodelite/install.sh port 18060
sudo /opt/nodelite/install.sh path panel-new-secret
sudo /opt/nodelite/install.sh host node.example.com
sudo /opt/nodelite/install.sh restart
```

## TCPFit 菜单项

TCPFit 来源：<https://github.com/Kylin010/tcpfit>。

NodeLite 不会默认执行它。选择菜单 8 后会先说明风险并要求确认，然后解析 TCPFit 当前 `main` 提交、下载该固定提交对应的脚本、执行 Bash 语法检查并显示 SHA256，最后进入 TCPFit 自己的菜单。

TCPFit 可能修改 sysctl、qdisc、默认路由参数、systemd 服务和可选 swap。执行前请确保有云控制台/KVM 回退通道；回滚由 TCPFit 自身的 `rollback` 功能负责。

## Reality 伪装目标

内置预设：

- Apple
- Amazon
- Cloudflare
- Mozilla Add-ons
- Bing
- 自定义

Google、Microsoft 和 Oracle 已从推荐预设移除。目标域名是否适合某台服务器取决于服务器出口网络和 TLS 行为，部署后仍应使用真实客户端测试。

## 手动安装

```bash
git clone https://github.com/dabao9037/nodelite.git
cd nodelite
cp .env.example .env
cp .env.credentials.example .env.credentials
chmod 600 .env .env.credentials
mkdir -p data xray-config
chmod 700 data
chmod 755 xray-config
docker compose up -d --build
```

`.env` 示例：

```env
PUBLIC_HOST=node.example.com
PANEL_PORT=2060
ACCESS_PATH=panel-change-me
```

## 反向代理

NodeLite 自带随机路径网关。如果再放到外层 Nginx/Caddy 后面，请转发完整随机目录，不要把根路径直接映射到 Panel。例如随机目录为 `panel-change-me`：

```nginx
location /panel-change-me/ {
    proxy_pass http://127.0.0.1:2060/panel-change-me/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

## 测试

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
PYTHONPATH=. pytest -q
```

真实空目录 Compose 启动门禁：

```bash
sudo NODELITE_FRESH_INSTALL_TEST=1 bash scripts/test-fresh-install.sh
```

## License

MIT
