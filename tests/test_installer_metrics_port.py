"""metrics 端口撞车会让 nodelite-xray 起不来，安装器必须自己挑空闲端口。"""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"


def _func(name: str) -> str:
    text = INSTALLER.read_text(encoding="utf-8")
    start = text.index(f"{name}() {{")
    return text[start : text.index("\n}\n", start) + 3]


def _run(tmp_path, busy_port=None, existing=None):
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    fake = bindir / "ss"
    if busy_port:
        fake.write_text(
            "#!/bin/sh\n"
            f"echo 'LISTEN 0 128 127.0.0.1:{busy_port} 0.0.0.0:*'\n",
            encoding="utf-8",
        )
    else:
        fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake.chmod(0o755)

    install_dir = tmp_path / "opt"
    (install_dir / "config").mkdir(parents=True, exist_ok=True)
    if existing is not None:
        (install_dir / "config" / "nodelite.env").write_text(
            f"XRAY_METRICS_PORT={existing}\n", encoding="utf-8"
        )

    script = (
        "set -Eeuo pipefail\n"
        f'INSTALL_DIR="{install_dir}"\n'
        'read_key() { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; }\n'
        f"{_func('port_in_use')}"
        f"{_func('pick_metrics_port')}"
        "pick_metrics_port\n"
    )
    proc = subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, "PATH": f"{bindir}:/usr/bin:/bin"},
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.strip()


def test_free_default_when_nothing_listens(tmp_path):
    assert _run(tmp_path) == "11111"


def test_moves_to_next_port_when_11111_is_taken(tmp_path):
    assert _run(tmp_path, busy_port=11111) == "11200"


def test_keeps_existing_port_when_still_free(tmp_path):
    assert _run(tmp_path, existing=11300) == "11300"


def test_install_writes_metrics_port_and_verifies_xray():
    text = INSTALLER.read_text(encoding="utf-8")
    assert "XRAY_METRICS_PORT=$(pick_metrics_port" in text
    assert 'service_prop nodelite-xray.service ActiveState' in text
    assert "attempt == 5" in text  # 面板重写配置后允许 xray 重启一次
    assert "20 秒内始终没起来" in text
