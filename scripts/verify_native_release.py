#!/usr/bin/env python3
"""Verify NodeLite Reality presets and native installer access-output contract."""
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
page = (root / "app/static/index.html").read_text(encoding="utf-8")
script = (root / "app/static/app.js").read_text(encoding="utf-8")
installer = (root / "install.sh").read_text(encoding="utf-8")
docker_installer = (root / "install-docker.sh").read_text(encoding="utf-8")
stylesheet = (root / "app/static/app.css").read_text(encoding="utf-8")

groups = {
    "美国": ("www.atlasobscura.com", "www.backblaze.com"),
    "英国": ("www.jodrellbank.net", "www.sciencemuseum.org.uk"),
    "日本": ("www.animatetimes.com", "www.famitsu.com"),
    "东南亚": ("www.a-star.edu.sg", "www.visitsingapore.com"),
    "欧洲": ("www.cern.ch", "www.gog.com"),
    "香港": ("www.hkstp.org", "www.discoverhongkong.com"),
}
expected = {host for hosts in groups.values() for host in hosts}
for label, hosts in groups.items():
    assert f'<optgroup label="{label}">' in page, label
    for host in hosts:
        assert page.count(f'<option value="{host}"') == 1, host
        assert host in script, host
assert len(expected) == 12

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
print("verified: 6 groups, 12 niche domains, removed legacy presets, non-empty username/password output")
