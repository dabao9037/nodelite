"""systemd 219（CentOS 7）兼容：不能依赖 230 才有的 --value，StartLimit 要在 [Service]。"""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
UNITS = ROOT / "packaging" / "systemd"


def _func(name: str) -> str:
    text = INSTALLER.read_text(encoding="utf-8")
    start = text.index(f"{name}() {{")
    return text[start : text.index("\n}\n", start) + 3]


def test_no_value_flag_outside_comment():
    text = INSTALLER.read_text(encoding="utf-8")
    for number, line in enumerate(text.splitlines(), 1):
        if "--value" in line and not line.lstrip().startswith("#"):
            raise AssertionError(f"install.sh:{number}: {line}")


def test_service_prop_parses_key_value_output(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    fake = bindir / "systemctl"
    fake.write_text("#!/bin/sh\necho 'ActiveState=active'\n", encoding="utf-8")
    fake.chmod(0o755)

    script = (
        "set -Eeuo pipefail\n"
        "have_systemd() { true; }\n"
        "die() { exit 1; }\n"
        f"{_func('service_ctl')}"
        f"{_func('service_prop')}"
        'service_prop nodelite-netguard.service ActiveState\n'
    )
    proc = subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, "PATH": f"{bindir}:/usr/bin:/bin"},
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "active"


def test_start_limit_moved_to_service_section():
    for unit in UNITS.glob("*.service"):
        text = unit.read_text(encoding="utf-8")
        unit_section = text.split("[Service]", 1)[0]
        service_section = text.split("[Service]", 1)[1]
        assert "StartLimitBurst" not in unit_section, unit
        assert "StartLimitInterval" in service_section, unit
        assert "StartLimitBurst=20" in service_section, unit
