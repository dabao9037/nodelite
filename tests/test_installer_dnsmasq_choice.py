"""SVCB 过滤器选哪个 dnsmasq：内置静态 2.90 vs 发行版自带。

Debian 11 的 dnsmasq 是 2.85、CentOS 7 是 2.76、CentOS Stream 8 是 2.79，
都没有 filter-rr（2.86 引入）。release 包自带静态 2.90，安装器必须优先用它，
否则菜单 14 / 安装时的默认开启都只能跳过。
"""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = "# ==================== dnsmasq 版本与二进制选择 ===================="
END = "# ==================== dnsmasq 版本与二进制选择 · 结束 ===================="

FAKE_DNSMASQ = """#!/bin/sh
case "$1" in
  --version) echo "Dnsmasq version {version}  Copyright (c) 2000-2024 Simon Kelley" ;;
  --test) exit 0 ;;
esac
exit 0
"""


def _helper_block() -> str:
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    return text[text.index(START) : text.index(END)]


def _fake(path: Path, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FAKE_DNSMASQ.format(version=version), encoding="utf-8")
    path.chmod(0o755)


def _run(tmp_path, *, system_version=None, bundled_version=None, call="svcb_dnsmasq_bin"):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    if system_version:
        _fake(bindir / "dnsmasq", system_version)

    bundled = tmp_path / "opt" / "bin" / "dnsmasq"
    if bundled_version:
        _fake(bundled, bundled_version)

    block = tmp_path / "helpers.sh"
    block.write_text(_helper_block(), encoding="utf-8")

    env = os.environ.copy()
    env.update(
        PATH=f"{bindir}:/usr/bin:/bin",
        SVCB_DNSMASQ_BUNDLED=str(bundled),
        SVCB_DNSMASQ_MIN="2.86",
    )
    script = "set -Eeuo pipefail\n" f'source "{block}"\n' f"{call}\n"
    return subprocess.run(
        ["bash", "-c", script], env=env, capture_output=True, text=True, check=False
    )


def test_prefers_bundled_when_system_dnsmasq_is_too_old(tmp_path):
    proc = _run(tmp_path, system_version="2.85", bundled_version="2.90")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip().endswith("opt/bin/dnsmasq"), proc.stdout


def test_falls_back_to_system_binary_without_bundle(tmp_path):
    proc = _run(tmp_path, system_version="2.85")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip().endswith("bin/dnsmasq"), proc.stdout


def test_system_version_gate(tmp_path):
    old = _run(tmp_path, system_version="2.85", call="svcb_system_dnsmasq_ok && echo yes || echo no")
    assert old.stdout.strip() == "no", old.stderr

    p = tmp_path / "new"
    p.mkdir()
    new = _run(p, system_version="2.89", call="svcb_system_dnsmasq_ok && echo yes || echo no")
    assert new.stdout.strip() == "yes", new.stderr


def test_version_ok_uses_bundled_binary(tmp_path):
    proc = _run(tmp_path, system_version="2.85", bundled_version="2.90",
                call="svcb_version_ok && echo ok || echo skip")
    assert proc.stdout.strip() == "ok", proc.stderr

    p = tmp_path / "nosystem"
    p.mkdir()
    only_old = _run(p, system_version="2.76", call="svcb_version_ok && echo ok || echo skip")
    assert only_old.stdout.strip() == "skip", only_old.stderr


def test_installer_uses_bundled_binary_in_unit():
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    unit = text[text.index("svcb_write_unit() {"):]
    unit = unit[: unit.index("\n}\n")]
    assert 'bin="$(svcb_dnsmasq_bin || true)"' in unit
    assert "ExecStart=$bin" in unit


def test_dnsmasq_install_uses_tolerant_apt():
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    fn = text[text.index("svcb_install_dnsmasq() {"):]
    fn = fn[: fn.index("\n}\n")]
    assert "apt_install dnsmasq" in fn
    assert "apt-get update" not in fn


def test_new_system_package_wins_over_bundle(tmp_path):
    """系统 dnsmasq 够新就用系统的，别抢发行版的安全更新。"""
    proc = _run(tmp_path, system_version="2.89", bundled_version="2.90")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip().endswith("bin/dnsmasq"), proc.stdout
    assert "opt/bin" not in proc.stdout
