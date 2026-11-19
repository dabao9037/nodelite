"""老 curl 兼容：--retry-all-errors 只有 7.71+ 认识，不能无条件带上。

CentOS 7 的 curl 7.29、Debian 10 的 7.64 会在发请求前直接报
`option --retry-all-errors: is unknown` 并退出，导致安装脚本/发行包下载失败。
"""

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"

OLD_CURL = """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    --retry-all-errors) echo "curl: option --retry-all-errors: is unknown" >&2; exit 2 ;;
  esac
done
case "$1" in --version) echo "curl 7.29.0"; exit 0 ;; esac
exit 0
"""

NEW_CURL = """#!/bin/sh
case "$1" in --version) echo "curl 8.5.0"; exit 0 ;; esac
exit 0
"""


def _run_probe(tmp_path: Path, fake: str) -> str:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    curl = bindir / "curl"
    curl.write_text(fake, encoding="utf-8")
    curl.chmod(0o755)

    text = INSTALLER.read_text(encoding="utf-8")
    start = text.index("curl_retry_all() {")
    block = text[start : text.index("\n}\n", start) + 3]
    script = f"set -Eeuo pipefail\n{block}\ncurl_retry_all\n"
    proc = subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, "PATH": f"{bindir}:/usr/bin:/bin"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def test_old_curl_does_not_get_the_flag(tmp_path):
    assert _run_probe(tmp_path, OLD_CURL) == ""


def test_new_curl_keeps_the_flag(tmp_path):
    assert _run_probe(tmp_path, NEW_CURL) == "--retry-all-errors"


def test_no_bare_flag_outside_the_probe():
    text = INSTALLER.read_text(encoding="utf-8")
    calls = [
        line for line in text.splitlines()
        if "--retry-all-errors" in line
        and "--version" not in line
        and "printf" not in line
        and not line.lstrip().startswith("#")
    ]
    assert calls == []
    assert text.count("$(curl_retry_all)") == 4


def test_every_curl_retry_uses_the_probe():
    text = INSTALLER.read_text(encoding="utf-8")
    for match in re.finditer(r"curl[^\n]*--retry 3[^\n]*", text):
        assert "$(curl_retry_all)" in match.group(0), match.group(0)
