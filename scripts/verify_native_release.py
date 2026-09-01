#!/usr/bin/env python3
"""Verify release-critical UI data, backend semantics, and installer contracts."""
import ast
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
page = (root / "app/static/index.html").read_text(encoding="utf-8")
script = (root / "app/static/app.js").read_text(encoding="utf-8")
installer = (root / "install.sh").read_text(encoding="utf-8")
docker_installer = (root / "install-docker.sh").read_text(encoding="utf-8")
stylesheet = (root / "app/static/app.css").read_text(encoding="utf-8")
backend = (root / "app/main.py").read_text(encoding="utf-8")
targets_document = json.loads((root / "config/reality-targets.json").read_text(encoding="utf-8"))

groups = targets_document["groups"]
assert len(groups) == 6
expected = {target["host"] for group in groups for target in group["targets"]}
for group in groups:
    label = group["label"].split(" · ", 1)[0]
    assert f'<optgroup label="{label}">' in page, label
    for target in group["targets"]:
        host = target["host"]
        assert page.count(f'<option value="{host}"') == 1, host
        assert len(expected) == 12

methods = [
    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
    "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305",
]
tree = ast.parse(backend)
assignments = {
    node.targets[0].id: ast.literal_eval(node.value)
    for node in tree.body
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
    and node.targets[0].id in {"DEFAULT_SS_METHOD", "SS_METHOD_KEY_BYTES"}
}
assert assignments["DEFAULT_SS_METHOD"] == methods[0]
assert list(assignments["SS_METHOD_KEY_BYTES"]) == methods
node_input = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "NodeInput")
assert any(isinstance(node, ast.AnnAssign) and getattr(node.target, "id", None) == "method" for node in node_input.body)
for marker in (
    "config_shadowsocks_method(cfg)", "shadowsocks_method(payload.method)",
    'cfg["method"] = config_shadowsocks_method(cfg)',
    'userinfo = f"{config_shadowsocks_method(cfg)}:{cfg[\'password\']}"',
):
    assert marker in backend, marker
html_protocols = re.findall(r'<button class="protocol(?: active)?"[^>]+data-proto="([^"]+)"', page)
assert html_protocols == ["vless", "shadowsocks", "socks"], html_protocols
assert re.findall(r'<option value="([^"]+)">[^<]+</option>', page[page.index('id="ssMethod"'):page.index('id="ssMethod"') + 700])[:5] == methods

removed = (
    "www.apple.com", "www.microsoft.com", "www.bbc.co.uk", "www.gov.uk",
    "www.sony.jp", "www.nintendo.co.jp", "www.singaporeair.com", "www.dbs.com",
    "www.ikea.com", "www.cathaypacific.com", "www.hangseng.com",
    "www.nature.com", "www.visitfinland.com", "www.animenewsnetwork.com",
)
for host in removed:
    assert f'value="{host}"' not in page, host
    assert host not in script, host

assert "document.execCommand('copy')" in script
assert "await copyText(copy.dataset.copy)" in script
assert "await navigator.clipboard.writeText(copy.dataset.copy)" not in script
assert '[[ -n "$host" && -n "$port" && -n "$path" && -n "$user" && -n "$password" ]]' in installer
assert "用户名：%s\\n密码：%s" in installer
assert 'port="${port:-$(random_high_port)}"' in installer
assert 'port="${port:-$(random_high_port)}"' in docker_installer
assert "DEFAULT_PORT=2060" not in installer
assert "DEFAULT_PORT=2060" not in docker_installer
assert "grid-template-columns: minmax(92px, auto)" in stylesheet
assert ".node-meta .port strong { overflow: visible; text-overflow: clip; white-space: nowrap;" in stylesheet
print("verified: Reality JSON groups[].targets, five SS methods/backend flow, protocol order, installer contracts")
