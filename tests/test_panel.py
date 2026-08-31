import base64
import importlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def panel(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_USER", "test-admin")
    monkeypatch.setenv("ADMIN_" + "PASSWORD", "correct-horse")
    monkeypatch.setenv("APP_" + "SECRET", "test-signing-value")
    monkeypatch.setenv("PUBLIC_HOST", "node.example.test")
    monkeypatch.setenv("DB_PATH", str(tmp_path / "panel.db"))
    monkeypatch.setenv("XRAY_CONFIG_PATH", str(tmp_path / "config.json"))
    monkeypatch.setenv("NETGUARD_REQUIRED", "0")
    monkeypatch.setenv("BACKGROUND_INTERVAL_SECONDS", "3600")
    sys.modules.pop("app.main", None)
    module = importlib.import_module("app.main")
    module.init_db()
    monkeypatch.setattr(module, "xray_container", lambda: None)
    with TestClient(module.app) as client:
        yield module, client
    module.STOP_EVENT.set()


def login(client, base=""):
    return client.post(
        f"{base}/login",
        data={"username": "test-admin", "password": "correct-horse"},
        follow_redirects=False,
    )


def test_repeatable_migration_preserves_legacy_nodes(tmp_path, monkeypatch):
    db = tmp_path / "legacy.db"
    connection = sqlite3.connect(db)
    connection.execute("""CREATE TABLE nodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, protocol TEXT NOT NULL,
      port INTEGER NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1,
      config TEXT NOT NULL, created_at INTEGER NOT NULL)""")
    connection.execute(
        "INSERT INTO nodes(name,protocol,port,config,created_at) VALUES(?,?,?,?,?)",
        ("legacy", "socks", 21000, json.dumps({"username": "u", "password": "p"}), 1),
    )
    connection.commit(); connection.close()
    monkeypatch.setenv("ADMIN_" + "PASSWORD", "x")
    monkeypatch.setenv("APP_" + "SECRET", "y")
    monkeypatch.setenv("DB_PATH", str(db))
    monkeypatch.setenv("NETGUARD_REQUIRED", "0")
    sys.modules.pop("app.main", None)
    module = importlib.import_module("app.main")
    module.init_db(); module.init_db()
    connection = sqlite3.connect(db)
    columns = {row[1]: row for row in connection.execute("PRAGMA table_info(nodes)")}
    row = connection.execute("SELECT name,expires_at,max_connections,traffic_uplink_base,traffic_downlink_base FROM nodes").fetchone()
    versions = connection.execute("SELECT count(*) FROM schema_migrations").fetchone()[0]
    assert row == ("legacy", None, None, 0, 0)
    assert versions == 7
    assert columns["traffic_uplink_base"][3] == 1


def test_login_error_success_and_relative_redirects(panel):
    _, client = panel
    page = client.get("/login")
    assert page.status_code == 200
    absolute_prefixes = [attribute + '="' + '/' for attribute in ("href", "src", "action")]
    assert not any(marker in page.text for marker in absolute_prefixes)
    wrong = client.post("/login", data={"username": "test-admin", "password": "wrong"}, follow_redirects=False)
    assert wrong.status_code == 401
    assert "用户名或密码错误" in wrong.text
    success = login(client)
    assert success.status_code == 303
    assert success.headers["location"] == "./"
    assert "HttpOnly" in success.headers["set-cookie"]


def test_prefix_safe_html_api_qr_and_redirect(panel):
    module, client = panel
    module.app.root_path = "/node-panel"
    assert client.get("/node-panel/login").status_code == 200
    success = login(client, "/node-panel")
    assert success.status_code == 303
    home = client.get("/node-panel/")
    assert home.status_code == 200
    assert "api/nodes/telemetry" in (Path(module.BASE_DIR) / "static/app.js").read_text()
    created = client.post("/node-panel/api/nodes", json={"name": "prefix socks", "protocol": "socks", "port": 21001})
    assert created.status_code == 201
    assert created.json()["qr"] == "api/nodes/1/qr"
    assert client.get("/node-panel/api/nodes/1/qr").headers["content-type"] == "image/png"
    assert client.get("/node-panel/api/nodes/telemetry").status_code == 200


def test_forwarded_prefix_scopes_session_cookie(panel):
    _, client = panel
    response = client.post(
        "/login", data={"username": "test-admin", "password": "correct-horse"},
        headers={"x-forwarded-prefix": "/node-panel"}, follow_redirects=False,
    )
    assert response.status_code == 303
    assert "Path=/node-panel/" in response.headers["set-cookie"]


def test_reality_preset_selector_and_custom_fallback(panel):
    module, client = panel
    login(client)
    home = client.get("/")
    assert home.status_code == 200
    apple_option = '<option value="www.apple.com">Apple（推荐）</option>'
    assert apple_option in home.text
    for host in (
        "www.apple.com", "www.bing.com", "www.microsoft.com",
        "learn.microsoft.com", "www.samsung.com", "www.asus.com",
    ):
        assert f'value="{host}"' in home.text
    for removed_host in (
        "www.amazon.com", "www.cloudflare.com", "addons.mozilla.org",
        "www.google.com", "www.oracle.com",
    ):
        assert f'value="{removed_host}"' not in home.text
    assert 'value="custom"' in home.text
    assert '<input id="serverName" value="www.apple.com">' in home.text
    assert '<input id="destination" value="www.apple.com:443">' in home.text
    assert module.reality_values(None, None) == ("www.apple.com", "www.apple.com:443")
    script = (Path(module.BASE_DIR) / "static/app.js").read_text()
    assert "updateRealityPreset" in script
    assert "`${value}:443`" in script
    assert "document.execCommand('copy')" in script


def test_create_edit_validation_and_defaults(panel, monkeypatch):
    module, client = panel
    login(client)
    monkeypatch.setattr(module, "x25519", lambda: ("private-reality-key", "public-reality-key"))
    before = time.time()
    socks = client.post("/api/nodes", json={
        "name": "office socks", "protocol": "socks", "port": 22001,
        "username": "name@example", "password": "p@ss/word",
    })
    assert socks.status_code == 201
    assert socks.json()["expires_at"] is None
    assert socks.json()["max_connections"] is None
    assert socks.json()["status"] == "active"
    edit = client.put("/api/nodes/1", json={
        "name": "limited", "max_connections": 3,
        "expiration_mode": "days", "expires_in_days": 2,
    })
    assert edit.status_code == 200
    assert edit.json()["max_connections"] == 3
    assert before + 2 * 86400 - 2 <= edit.json()["expires_at"] <= time.time() + 2 * 86400 + 2
    invalid_past = client.put("/api/nodes/1", json={
        "expiration_mode": "date", "expires_at": "2000-01-01T00:00:00Z",
    })
    assert invalid_past.status_code == 422
    invalid_limit = client.post("/api/nodes", json={
        "name": "bad", "protocol": "socks", "max_connections": 0,
    })
    assert invalid_limit.status_code == 422
    clear = client.put("/api/nodes/1", json={"max_connections": None, "expiration_mode": "never"})
    assert clear.status_code == 200
    assert clear.json()["max_connections"] is None
    assert clear.json()["expires_at"] is None


def test_create_and_serialize_all_three_protocols(panel, monkeypatch):
    module, client = panel
    login(client)
    monkeypatch.setattr(module, "x25519", lambda: ("private-reality-key", "public-reality-key"))
    key = base64.b64encode(b"0123456789abcdef").decode()
    client.post("/api/nodes", json={"name": "socks", "protocol": "socks", "port": 22001})
    shadowsocks = client.post("/api/nodes", json={"name": "ss", "protocol": "shadowsocks", "port": 22002, "password": key})
    assert shadowsocks.status_code == 201
    ss_auth = urlsplit(shadowsocks.json()["link"]).username
    ss_auth += "=" * (-len(ss_auth) % 4)
    assert base64.urlsafe_b64decode(ss_auth).decode() == f"{module.SS2022_METHOD}:{key}"
    reality = client.post("/api/nodes", json={
        "name": "reality", "protocol": "vless", "port": 22004,
        "server_name": "www.example.com", "destination": "www.example.com:443",
    })
    assert reality.status_code == 201
    query = parse_qs(urlsplit(reality.json()["link"]).query)
    assert query["type"] == ["raw"]
    assert query["fp"] == ["chrome"]
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT * FROM nodes ORDER BY id").fetchall()
    configuration = module.config_for(rows)
    assert configuration["stats"] == {}
    assert configuration["policy"]["system"]["statsInboundUplink"] is True
    assert configuration["api"]["listen"] == "127.0.0.1:10085"
    assert {item["tag"] for item in configuration["inbounds"]} == {"node-1", "node-2", "node-3"}


def test_traffic_mapping_rate_and_restart_baseline(panel):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={"name": "traffic", "protocol": "socks", "port": 23001})
    parsed = module.parse_xray_stats({"stat": [
        {"name": "inbound>>>node-1>>>traffic>>>uplink", "value": "1200"},
        {"name": "inbound>>>node-1>>>traffic>>>downlink", "value": "3000"},
        {"name": "outbound>>>direct>>>traffic>>>uplink", "value": "9999"},
    ]})
    assert parsed == {1: {"uplink": 1200, "downlink": 3000}}
    module.sample_telemetry(parsed, {23001: 1}, now=1000)
    second = module.sample_telemetry({1: {"uplink": 2200, "downlink": 5000}}, {23001: 2}, now=1002)[1]
    assert second["traffic_uplink"] == 2200
    assert second["traffic_downlink"] == 5000
    assert second["uplink_rate"] == 500
    assert second["downlink_rate"] == 1000
    assert second["active_connections"] == 2
    after_restart = module.sample_telemetry({1: {"uplink": 100, "downlink": 200}}, {23001: 0}, now=1004)[1]
    assert after_restart["traffic_uplink"] == 2300
    assert after_restart["traffic_downlink"] == 5200


def test_expiry_disables_rebuilds_and_cannot_toggle(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={"name": "soon", "protocol": "socks", "port": 24001})
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.execute("UPDATE nodes SET expires_at=? WHERE id=1", (100,)); connection.commit()
    calls = []
    monkeypatch.setattr(module, "rebuild", lambda: calls.append("rebuild"))
    monkeypatch.setattr(module, "reconcile_limits", lambda: calls.append("limits"))
    assert module.expire_due_nodes(now=101) == [1]
    assert calls == ["rebuild", "limits"]
    response = client.post("/api/nodes/1/toggle")
    assert response.status_code == 409
    assert client.get("/api/nodes").json()[0]["status"] == "expired"


def test_rebuild_validates_then_restarts_and_rolls_back(panel, monkeypatch):
    module, _ = panel
    module.XRAY_CONFIG_PATH.write_text('{"old": true}', encoding="utf-8")
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: {})

    class Result:
        exit_code = 0
        output = b"Configuration OK"

    class Container:
        def __init__(self): self.restarts = 0; self.commands = []
        def exec_run(self, command): self.commands.append(command); return Result()
        def restart(self, timeout): self.restarts += 1; assert timeout == 15

    container = Container()
    monkeypatch.setattr(module, "xray_container", lambda: container)
    # The startup worker may have begun an in-flight rebuild before this test
    # installs its fakes. Serialize with the same lock, then reset observations.
    with module.STATE_LOCK:
        container.commands.clear()
        container.restarts = 0
        module.rebuild()
    assert container.commands == [["xray", "run", "-test", "-config", "/etc/xray/config.json"]]
    assert container.restarts == 1
    assert json.loads(module.XRAY_CONFIG_PATH.read_text())["stats"] == {}

    class BadResult:
        exit_code = 1
        output = b"invalid configuration"

    container.exec_run = lambda command: BadResult()
    module.XRAY_CONFIG_PATH.write_text('{"known": "good"}', encoding="utf-8")
    with pytest.raises(module.HTTPException): module.rebuild()
    assert json.loads(module.XRAY_CONFIG_PATH.read_text()) == {"known": "good"}


def load_netguard(tmp_path, monkeypatch):
    path = Path(__file__).parents[1] / "netguard" / "netguard.py"
    spec = importlib.util.spec_from_file_location("netguard_test", path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    db = tmp_path / "guard.db"
    connection = sqlite3.connect(db)
    connection.execute("CREATE TABLE nodes(id INTEGER,port INTEGER,enabled INTEGER,max_connections INTEGER,expires_at INTEGER)")
    connection.executemany("INSERT INTO nodes VALUES(?,?,?,?,?)", [
        (1, 30001, 1, 2, None), (2, 30002, 0, 3, None), (3, 30003, 1, None, None), (4, 30004, 1, 1, 10),
    ])
    connection.commit(); connection.close()
    monkeypatch.setattr(module, "DB_PATH", str(db))
    return module


def test_netguard_cold_start_without_database(tmp_path, monkeypatch):
    path = Path(__file__).parents[1] / "netguard" / "netguard.py"
    spec = importlib.util.spec_from_file_location("netguard_cold_start_test", path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    monkeypatch.setattr(module, "DB_PATH", str(tmp_path / "not-created-yet.db"))
    assert module.desired_rules(now=20) == []

    commands = []
    monkeypatch.setattr(module, "ensure_jump", lambda: commands.append(("ensure",)))
    monkeypatch.setattr(module, "run", lambda *args, check=True: commands.append(args) or "")
    assert module.reconcile() == []
    assert commands == [("ensure",), ("iptables", "-F", module.CHAIN)]


def test_netguard_reads_live_wal_data(tmp_path, monkeypatch):
    path = Path(__file__).parents[1] / "netguard" / "netguard.py"
    spec = importlib.util.spec_from_file_location("netguard_wal_test", path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    db = tmp_path / "wal.db"
    writer = sqlite3.connect(db)
    writer.execute("PRAGMA journal_mode=WAL")
    writer.execute("PRAGMA wal_autocheckpoint=0")
    writer.execute("CREATE TABLE nodes(id INTEGER,port INTEGER,enabled INTEGER,max_connections INTEGER,expires_at INTEGER)")
    writer.execute("INSERT INTO nodes VALUES(1,30001,1,2,NULL)")
    writer.commit()
    monkeypatch.setattr(module, "DB_PATH", str(db))
    assert module.desired_rules(now=20) == [(1, 30001, 2)]
    writer.close()


def test_netguard_health_fails_when_iptables_probe_fails(tmp_path, monkeypatch):
    guard = load_netguard(tmp_path, monkeypatch)

    def failed_probe(*args, **kwargs):
        raise RuntimeError("iptables unavailable")

    monkeypatch.setattr(guard, "run", failed_probe)
    with pytest.raises(RuntimeError, match="iptables unavailable"):
        guard.health()


def test_connlimit_rule_generation_and_rollback(tmp_path, monkeypatch):
    guard = load_netguard(tmp_path, monkeypatch)
    assert guard.desired_rules(now=20) == [(1, 30001, 2)]
    commands = []
    monkeypatch.setattr(guard, "ensure_jump", lambda: commands.append(("ensure",)))
    monkeypatch.setattr(guard, "run", lambda *args, check=True: commands.append(args) or "")
    rules = guard.reconcile()
    assert rules == [{"id": 1, "port": 30001, "limit": 2}]
    text = " ".join(commands[-1])
    assert "--dport 30001" in text
    assert "--connlimit-above 2" in text
    assert "--connlimit-mask 0" in text
    assert "--syn" in text and "tcp-reset" in text

    command_results = iter([0, 0, 1])
    monkeypatch.setattr(guard.subprocess, "run", lambda *args, **kwargs: type("R", (), {"returncode": next(command_results)})())
    rollback_commands = []
    monkeypatch.setattr(guard, "run", lambda *args, check=True: rollback_commands.append(args) or "")
    guard.rollback()
    assert ("iptables", "-D", "INPUT", "-j", guard.CHAIN) in rollback_commands
    assert rollback_commands[-1] == ("iptables", "-X", guard.CHAIN)


def test_netguard_active_connection_mapping(tmp_path, monkeypatch):
    guard = load_netguard(tmp_path, monkeypatch)
    output = "0 0 127.0.0.1:30001 1.1.1.1:555\n0 0 [::]:30001 [::1]:9\n0 0 0.0.0.0:40000 2.2.2.2:1\n"
    monkeypatch.setattr(guard, "run", lambda *args, **kwargs: output)
    assert guard.status([30001, 40000]) == {"30001": 2, "40000": 1}
