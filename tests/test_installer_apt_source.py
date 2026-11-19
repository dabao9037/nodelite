"""apt 源容错：下架套件（Release 404）必须被注释掉，且不能阻断依赖安装。

2026-11-19 现场：Debian 11 的源里残留 bullseye-backports（Debian 转 LTS 后已
下架）。`apt-get update` 退出 100，旧实现 `update && install` 短路，iptables
根本没装，最后报成「依赖安装后仍找不到命令：iptables」。
"""

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = "# ==================== apt 源容错（死源自动注释） ===================="
END = "# ==================== apt 源容错 · 结束 ===================="

FAKE_APT = r"""#!/bin/sh
log="$APT_TEST_LOG"
printf '%s\n' "$*" >>"$log"
case "$1" in
  update)
    if [ "${APT_TEST_ALWAYS_FAIL:-0}" = "1" ]; then
      n=0
    else
      n=$(grep -c '^update' "$log" || true)
    fi
    if [ "$n" -le 1 ]; then
      dead_uri="${APT_TEST_DEAD_URI:-http://deb.debian.org/debian}"
      dead_suite="${APT_TEST_DEAD_SUITE:-bullseye-backports}"
      printf '%s\n' \
        "Err:5 $dead_uri $dead_suite Release" \
        "  404  Not Found [IP: 151.101.2.132 80]" \
        "E: The repository '$dead_uri $dead_suite Release' no longer has a Release file." >&2
      exit 100
    fi
    exit 0
    ;;
  install)
    n=$(grep -c '^install' "$log" || true)
    case "${APT_TEST_INSTALL_FAIL:-0}" in
      1) [ "$n" -le 1 ] && exit 100 ;;
      2) [ "$n" -le 2 ] && exit 100 ;;
    esac
    exit 0
    ;;
esac
exit 0
"""


def _helper_block() -> str:
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    return text[text.index(START) : text.index(END)]


def _run(tmp_path, sources: str, extra=None, suite="bullseye-backports",
         uri="http://deb.debian.org/debian", always_fail=False,
         install_fail="0"):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    fake = bindir / "apt-get"
    fake.write_text(FAKE_APT, encoding="utf-8")
    fake.chmod(0o755)

    log = tmp_path / "apt.log"
    log.write_text("", encoding="utf-8")

    sources_list = tmp_path / "sources.list"
    sources_list.write_text(sources, encoding="utf-8")
    sources_dir = tmp_path / "sources.list.d"
    sources_dir.mkdir()
    for name, content in (extra or {}).items():
        (sources_dir / name).write_text(content, encoding="utf-8")

    block = tmp_path / "block.sh"
    block.write_text(_helper_block(), encoding="utf-8")

    env = os.environ.copy()
    env.update(
        PATH=f"{bindir}:{env['PATH']}",
        APT_TEST_LOG=str(log),
        APT_TEST_DEAD_SUITE=suite,
        APT_TEST_DEAD_URI=uri,
        APT_TEST_ALWAYS_FAIL="1" if always_fail else "0",
        APT_TEST_INSTALL_FAIL=install_fail,
        NODELITE_APT_SOURCES_LIST=str(sources_list),
        NODELITE_APT_SOURCES_DIR=str(sources_dir),
    )
    script = (
        'set -Eeuo pipefail\n'
        'warn() { printf "[!] %s\\n" "$*" >&2; }\n'
        'source "$1"\n'
        'apt_install ca-certificates iptables\n'
    )
    proc = subprocess.run(
        ["bash", "-c", script, "_", str(block)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    return proc, log.read_text(encoding="utf-8"), sources_list, sources_dir


def test_dead_suite_is_commented_and_install_still_runs(tmp_path):
    sources = (
        "deb http://deb.debian.org/debian bullseye main\n"
        "deb http://deb.debian.org/debian bullseye-backports main\n"
        "deb http://security.debian.org/debian-security bullseye-security main\n"
    )
    proc, log, sources_list, _ = _run(tmp_path, sources)

    assert proc.returncode == 0, proc.stderr
    assert "已下架" in proc.stderr

    text = sources_list.read_text(encoding="utf-8")
    assert "# nodelite: 套件 bullseye-backports" in text
    assert "deb http://deb.debian.org/debian bullseye main" in text
    assert "deb http://security.debian.org/debian-security bullseye-security main" in text
    # 没被注释的健康行不能动
    assert text.splitlines()[0] == "deb http://deb.debian.org/debian bullseye main"
    assert text.count("# nodelite:") == 1

    backup = sources_list.with_name("sources.list.nodelite-bak")
    assert backup.exists()
    assert "deb http://deb.debian.org/debian bullseye-backports main" in backup.read_text(
        encoding="utf-8"
    )

    assert log.splitlines() == [
        "update",
        "update",
        "install -y ca-certificates iptables",
    ], log


def test_update_failure_without_dead_suite_does_not_abort(tmp_path):
    """源全挂但没有 404 套件（比如断网）：只 warn，仍要尝试安装。"""
    proc, log, _, _ = _run(
        tmp_path, "deb http://deb.debian.org/debian bullseye main\n", always_fail=True
    )
    # 404 报的套件不在本机 source 里（改过镜像/临时断网）：注释不到东西，
    # 不能死循环重试，也不能抛错退出，必须继续走 install。
    assert proc.returncode == 0, proc.stderr
    assert "仍然失败" in proc.stderr
    assert "已注释" not in proc.stderr
    assert log.splitlines() == [
        "update",
        "install -y ca-certificates iptables",
    ], log


def test_deb822_strips_dead_suite_from_mixed_stanza(tmp_path):
    extra = {
        "debian.sources": (
            "Types: deb\n"
            "URIs: http://deb.debian.org/debian\n"
            "Suites: bookworm bookworm-backports\n"
            "Components: main\n"
        )
    }
    proc, _, _, sources_dir = _run(
        tmp_path, "", extra, suite="bookworm-backports"
    )
    assert proc.returncode == 0, proc.stderr
    text = (sources_dir / "debian.sources").read_text(encoding="utf-8")
    assert "Suites: bookworm\n" in text
    assert "bookworm-backports" not in text


def test_deb822_stanza_with_only_dead_suite_is_disabled(tmp_path):
    extra = {
        "backports.sources": (
            "Types: deb\n"
            "URIs: http://deb.debian.org/debian\n"
            "Suites: bookworm-backports\n"
            "Components: main\n"
        )
    }
    proc, _, _, sources_dir = _run(
        tmp_path, "", extra, suite="bookworm-backports"
    )
    assert proc.returncode == 0, proc.stderr
    for line in (sources_dir / "backports.sources").read_text(encoding="utf-8").splitlines():
        assert line.startswith("#"), line
    assert "整段停用" in (sources_dir / "backports.sources").read_text(encoding="utf-8")


def test_no_bare_update_and_install_short_circuit():
    """`apt-get update && apt-get install` 再也不能出现：一个死源就会吞掉安装。"""
    pattern = re.compile(r"apt-get\s+update\s*&&\s*apt-get\s+install")
    for name in ("install.sh", "install-docker.sh", "build/native-amd64/package/install.sh"):
        for lineno, line in enumerate(
            (ROOT / name).read_text(encoding="utf-8").splitlines(), 1
        ):
            if line.lstrip().startswith("#"):
                continue
            assert not pattern.search(line), f"{name}:{lineno}: {line}"


def test_iptables_is_optional_for_native_install():
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    block = text[text.index("ensure_tools() {"):]
    block = block[: block.index("\n}\n")]
    assert "for cmd in curl tar openssl ip; do" in block
    assert "未安装 iptables" in block


def test_install_retries_with_release_suite_pin(tmp_path):
    """pool 404（EOL security 源）时整笔事务会回滚，第二次要按发行版代号重挑版本。"""
    proc, log, _, _ = _run(
        tmp_path,
        "deb http://deb.debian.org/debian bullseye main\n",
        install_fail="1",
    )
    assert proc.returncode == 0, proc.stderr
    installs = [line for line in log.splitlines() if line.startswith("install")]
    assert len(installs) == 2, log
    assert installs[0] == "install -y ca-certificates iptables"
    assert installs[1].startswith("install -y --fix-missing -t "), log


def test_install_falls_back_to_plain_fix_missing(tmp_path):
    """连 release 版本都装不上时，最后用 --fix-missing 保住能装的包。"""
    proc, log, _, _ = _run(
        tmp_path,
        "deb http://deb.debian.org/debian bullseye main\n",
        install_fail="2",
    )
    assert proc.returncode == 0, proc.stderr
    installs = [line for line in log.splitlines() if line.startswith("install")]
    assert installs[-1] == "install -y --fix-missing ca-certificates iptables", log
