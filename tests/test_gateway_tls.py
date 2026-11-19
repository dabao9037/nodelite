"""gateway 的 TLS 终止：证书对了就只走 HTTPS，配置不全就拒绝启动。"""

import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GATEWAY = ROOT / "gateway" / "server.py"


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _make_cert(tmp_path: Path) -> tuple[Path, Path]:
    cert = tmp_path / "cert.pem"
    key = tmp_path / "key.pem"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=localhost",
        ],
        check=True,
        capture_output=True,
    )
    return cert, key


def _env(cert: Path, key: Path, port: int) -> dict:
    env = os.environ.copy()
    env.update(
        ACCESS_PATH="panel-test1234",
        LISTEN_HOST="127.0.0.1",
        LISTEN_PORT=str(port),
        UPSTREAM_HOST="127.0.0.1",
        UPSTREAM_PORT=str(_free_port()),  # 没人监听：代理会回 502，正好验证链路
        TLS_CERT=str(cert),
        TLS_KEY=str(key),
    )
    return env


def _wait_tls(port: int, timeout: float = 10.0) -> None:
    context = ssl._create_unverified_context()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as raw:
                with context.wrap_socket(raw, server_hostname="localhost"):
                    return
        except OSError:
            time.sleep(0.1)
    raise AssertionError("gateway 没在预期时间内开始接受 TLS 连接")


@pytest.fixture()
def gateway(tmp_path):
    cert, key = _make_cert(tmp_path)
    port = _free_port()
    process = subprocess.Popen(
        [sys.executable, str(GATEWAY)],
        env=_env(cert, key, port),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        _wait_tls(port)
        yield port, process
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def test_https_serves_and_forwards_https_scheme(gateway):
    port, _ = gateway
    context = ssl._create_unverified_context()
    url = f"https://127.0.0.1:{port}/panel-test1234/api/nodes"
    with pytest.raises(urllib.error.HTTPError) as invalid_upstream:
        urllib.request.urlopen(url, context=context, timeout=5)
    response = invalid_upstream.value
    assert response.code == 502  # TLS 通了，上游不在 —— 说明代理链路正常
    assert response.headers["Strict-Transport-Security"] == "max-age=31536000"

    with pytest.raises(urllib.error.HTTPError) as wrong_path:
        urllib.request.urlopen(
            f"https://127.0.0.1:{port}/wrong-path/api/nodes", context=context, timeout=5
        )
    assert wrong_path.value.code == 404


def test_half_configured_tls_refuses_to_start(tmp_path):
    cert, key = _make_cert(tmp_path)
    env = _env(cert, key, _free_port())
    env.pop("TLS_KEY")
    process = subprocess.run(
        [sys.executable, str(GATEWAY)], env=env, capture_output=True, text=True, timeout=15
    )
    assert process.returncode != 0
    assert "同时设置" in (process.stderr + process.stdout)


def test_plain_http_stays_default(tmp_path):
    port = _free_port()
    env = _env(Path("/nonexistent"), Path("/nonexistent"), port)
    env.pop("TLS_CERT")
    env.pop("TLS_KEY")
    process = subprocess.Popen(
        [sys.executable, str(GATEWAY)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise AssertionError("明文 gateway 没起来")
        with pytest.raises(urllib.error.HTTPError) as plain:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/wrong-path", timeout=5
            )
        assert plain.value.code == 404
        assert "Strict-Transport-Security" not in plain.value.headers
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
