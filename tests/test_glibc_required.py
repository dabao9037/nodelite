"""GLIBC_MAX 必须是实测值：以前写死 2.31 把 Debian 10（2.28）挡在门外。"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "glibc-required.py"


def _run(target: Path):
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(target)],
        capture_output=True, text=True, check=False,
    )


def test_measures_real_binary(tmp_path):
    binary = tmp_path / "true"
    shutil.copy2("/bin/true", binary)
    proc = _run(tmp_path)
    assert proc.returncode == 0, proc.stderr
    version = proc.stdout.strip()
    assert version.count(".") >= 1 and version[0].isdigit(), version
    expected = subprocess.run(
        ["readelf", "--version-info", str(binary)], capture_output=True, text=True, check=True
    ).stdout
    assert f"GLIBC_{version}" in expected


def test_empty_directory_fails(tmp_path):
    proc = _run(tmp_path)
    assert proc.returncode == 1
    assert "no ELF files" in proc.stderr


def test_version_ordering_is_numeric():
    sys.path.insert(0, str(ROOT / "scripts"))
    import importlib.util

    spec = importlib.util.spec_from_file_location("glibc_required", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.version_key("2.9") < module.version_key("2.17")
    assert module.version_key("2.17") < module.version_key("2.28")
