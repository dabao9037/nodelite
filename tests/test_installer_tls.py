"""安装器的 TLS 开关：写进 env、校验证书与私钥配对、健康检查绕开 TLS。"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"


def _text() -> str:
    return INSTALLER.read_text(encoding="utf-8")


def _func(name: str) -> str:
    text = _text()
    start = text.index(f"{name}() {{")
    return text[start : text.index("\n}\n", start)]


def test_environment_file_carries_tls_paths():
    text = _text()
    assert "TLS_CERT=${NODELITE_TLS_CERT:-}" in text
    assert "TLS_KEY=${NODELITE_TLS_KEY:-}" in text


def test_tls_cert_validates_pairing_and_restarts_gateway():
    body = _func("set_tls_cert")
    assert "openssl x509" in body and "-pubkey" in body
    assert "openssl pkey" in body and "-pubout" in body
    assert "证书与私钥不匹配" in body
    assert "nodelite-gateway.service" in body
    assert 'set_key "$env_file" TLS_CERT "$cert"' in body


def test_tls_off_clears_paths():
    body = _func("set_tls_off")
    assert 'set_key "$env_file" TLS_CERT ""' in body
    assert 'set_key "$env_file" TLS_KEY ""' in body


def test_access_output_follows_tls_state():
    body = _func("show_access")
    assert 'scheme="https"' in body
    assert "%s://%s:%s/%s/login" in body


def test_health_probe_bypasses_public_tls_port():
    """有 TLS 时公网端口是 https，健康检查必须走内部明文端口。"""
    body = _func("wait_healthy")
    assert "PANEL_INTERNAL_PORT" in body
    assert "LISTEN_PORT" not in body


def test_xray_config_dir_is_private():
    assert 'chmod 700 "$INSTALL_DIR/data" "$INSTALL_DIR/xray-config"' in _text()


def test_menu_has_tls_entries():
    text = _text()
    assert re.search(r"16\. 开启面板 HTTPS", text)
    assert re.search(r"17\. 回退明文 HTTP", text)
    assert "tls-cert) set_tls_cert" in text
