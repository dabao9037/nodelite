import base64
import importlib
import json
import os
import sqlite3
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
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
    monkeypatch.setenv("RUNTIME_BACKEND", "docker")
    monkeypatch.setenv("DB_PATH", str(tmp_path / "panel.db"))
    monkeypatch.setenv("XRAY_CONFIG_PATH", str(tmp_path / "config.json"))
    monkeypatch.setenv("NETGUARD_REQUIRED", "0")
    monkeypatch.setenv("BACKGROUND_INTERVAL_SECONDS", "3600")
    monkeypatch.setenv("REALITY_TARGETS_URL", "")
    monkeypatch.setenv("REALITY_TARGETS_CACHE", str(tmp_path / "reality-targets-cache.json"))
    monkeypatch.setenv("REALITY_TARGETS_BUNDLED", str(Path(__file__).resolve().parents[1] / "config/reality-targets.json"))
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
    assert versions == 11
    assert columns["traffic_uplink_base"][3] == 1
    assert columns["traffic_limit_mb"][3] == 0


def test_migration_infers_disabled_reason_and_persists_after_restart(tmp_path, monkeypatch):
    db = tmp_path / "legacy-reasons.db"
    connection = sqlite3.connect(db)
    connection.execute("""CREATE TABLE nodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, protocol TEXT NOT NULL,
      port INTEGER NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1,
      config TEXT NOT NULL, created_at INTEGER NOT NULL,
      expires_at INTEGER, max_connections INTEGER,
      traffic_uplink_base INTEGER NOT NULL DEFAULT 0,
      traffic_downlink_base INTEGER NOT NULL DEFAULT 0,
      traffic_uplink_raw INTEGER NOT NULL DEFAULT 0,
      traffic_downlink_raw INTEGER NOT NULL DEFAULT 0,
      traffic_sampled_at REAL, traffic_limit_mb INTEGER,
      traffic_uplink_origin INTEGER NOT NULL DEFAULT 0,
      traffic_downlink_origin INTEGER NOT NULL DEFAULT 0)""")
    rows = [
        ("expired", 21010, 0, int(time.time()) - 10, 100, 1),
        ("quota", 21011, 0, None, 2 * 1024 * 1024, 1),
        ("manual", 21012, 0, None, 0, 10),
        ("active", 21013, 1, None, 0, 10),
    ]
    for name, port, enabled, expires_at, used, limit in rows:
        connection.execute(
            """INSERT INTO nodes(name,protocol,port,enabled,config,created_at,expires_at,
               traffic_uplink_base,traffic_limit_mb) VALUES(?,?,?,?,?,?,?,?,?)""",
            (name, "socks", port, enabled, json.dumps({"username": "u", "password": "p"}),
             1, expires_at, used, limit),
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
    assert connection.execute(
        "SELECT name,enabled,disabled_reason FROM nodes ORDER BY id"
    ).fetchall() == [
        ("expired", 0, "expired"),
        ("quota", 0, "traffic_limit"),
        ("manual", 0, "manual"),
        ("active", 1, None),
    ]
    connection.close()


def test_restart_preserves_manual_reason_even_when_node_is_over_quota(tmp_path, monkeypatch):
    db = tmp_path / "preserve-manual.db"
    monkeypatch.setenv("ADMIN_" + "PASSWORD", "x")
    monkeypatch.setenv("APP_" + "SECRET", "y")
    monkeypatch.setenv("DB_PATH", str(db))
    monkeypatch.setenv("NETGUARD_REQUIRED", "0")
    sys.modules.pop("app.main", None)
    module = importlib.import_module("app.main")
    module.init_db()
    connection = sqlite3.connect(db)
    connection.execute(
        """INSERT INTO nodes(name,protocol,port,enabled,config,created_at,traffic_limit_mb,
           traffic_uplink_base,disabled_reason) VALUES(?,?,?,?,?,?,?,?,?)""",
        ("manual over quota", "socks", 21014, 0,
         json.dumps({"username": "u", "password": "p"}), 1, 1, 2 * 1024 * 1024, "manual"),
    )
    connection.commit(); connection.close()

    module.init_db()
    connection = sqlite3.connect(db)
    assert connection.execute(
        "SELECT enabled,disabled_reason FROM nodes WHERE port=21014"
    ).fetchone() == (0, "manual")
    connection.close()


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
    default_option = '<option value="www.atlasobscura.com">Atlas Obscura · 小众旅行（推荐）</option>'
    assert default_option in home.text
    expected_groups = {
        "美国": ("www.atlasobscura.com", "www.backblaze.com"),
        "英国": ("www.jodrellbank.net", "www.sciencemuseum.org.uk"),
        "日本": ("www.animatetimes.com", "www.famitsu.com"),
        "东南亚": ("www.a-star.edu.sg", "www.visitsingapore.com"),
        "欧洲": ("www.cern.ch", "www.gog.com"),
        "香港": ("www.hkstp.org", "www.discoverhongkong.com"),
    }
    for group, hosts in expected_groups.items():
        assert f'<optgroup label="{group}">' in home.text
        for host in hosts:
            assert f'value="{host}"' in home.text
    for removed_host in (
        "www.apple.com", "www.microsoft.com", "www.bbc.co.uk", "www.gov.uk",
        "www.sony.jp", "www.nintendo.co.jp", "www.singaporeair.com", "www.dbs.com",
        "www.ikea.com", "www.cathaypacific.com", "www.hangseng.com",
        "www.nature.com", "www.visitfinland.com", "www.animenewsnetwork.com",
    ):
        assert f'value="{removed_host}"' not in home.text
    assert 'value="custom"' in home.text
    assert '<input id="serverName" value="www.atlasobscura.com">' in home.text
    assert '<input id="destination" value="www.atlasobscura.com:443">' in home.text
    assert module.reality_values(None, None) == ("www.atlasobscura.com", "www.atlasobscura.com:443")
    script = (Path(module.BASE_DIR) / "static/app.js").read_text()
    assert "updateRealityPreset" in script
    assert "`${value}:443`" in script
    assert "document.execCommand('copy')" in script
    assert "await copyText(copy.dataset.copy)" in script
    assert "await navigator.clipboard.writeText(copy.dataset.copy)" not in script


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


def test_node_traffic_limit_create_edit_clear_and_validation(panel):
    _, client = panel
    login(client)
    created = client.post("/api/nodes", json={
        "name": "quota", "protocol": "socks", "port": 22501, "traffic_limit_mb": 10,
    })
    assert created.status_code == 201
    node = created.json()
    assert node["traffic_limit_mb"] == 10
    assert node["traffic_limit_bytes"] == 10 * 1024 * 1024
    assert node["traffic_used_bytes"] == 0
    assert node["traffic_remaining_bytes"] == 10 * 1024 * 1024
    assert node["traffic_percent"] == 0
    assert node["traffic_exceeded"] is False

    edited = client.put("/api/nodes/1", json={"traffic_limit_mb": 20})
    assert edited.status_code == 200
    assert edited.json()["traffic_limit_mb"] == 20
    cleared = client.put("/api/nodes/1", json={"traffic_limit_mb": None})
    assert cleared.status_code == 200
    assert cleared.json()["traffic_limit_mb"] is None
    assert cleared.json()["traffic_limit_bytes"] is None
    assert cleared.json()["traffic_remaining_bytes"] is None
    assert cleared.json()["traffic_percent"] is None

    for value in (0, 1_000_000_001, 1.5, "abc"):
        invalid = client.put("/api/nodes/1", json={"traffic_limit_mb": value})
        assert invalid.status_code == 422
        assert "流量上限" in invalid.text


def test_traffic_limit_exact_and_overage_auto_disable_without_affecting_unlimited(panel, monkeypatch):
    module, client = panel
    login(client)
    mib = 1024 * 1024
    client.post("/api/nodes", json={
        "name": "exact", "protocol": "socks", "port": 22502, "traffic_limit_mb": 1,
    })
    client.post("/api/nodes", json={
        "name": "over", "protocol": "socks", "port": 22503, "traffic_limit_mb": 1,
    })
    client.post("/api/nodes", json={"name": "unlimited", "protocol": "socks", "port": 22504})
    module.RUNTIME_DIRTY = False
    sample = module.sample_telemetry({
        1: {"uplink": mib // 2, "downlink": mib // 2},
        2: {"uplink": mib, "downlink": 1},
        3: {"uplink": mib * 50, "downlink": mib * 50},
    }, {22502: 0, 22503: 0, 22504: 0}, now=1000)
    assert sample.exceeded_ids == [1, 2]
    assert module.disable_exceeded_nodes(sample.exceeded_ids) == [1, 2]
    telemetry = sample
    assert telemetry[1]["traffic_exceeded"] is True
    assert telemetry[1]["status"] == "traffic_exceeded"
    assert telemetry[2]["traffic_exceeded"] is True
    assert telemetry[3]["traffic_exceeded"] is False
    assert module.RUNTIME_DIRTY is True
    with sqlite3.connect(module.DB_PATH) as connection:
        assert connection.execute("SELECT enabled FROM nodes ORDER BY id").fetchall() == [(0,), (0,), (1,)]

    calls = []
    monkeypatch.setattr(module, "expire_due_nodes", lambda **kwargs: [])
    monkeypatch.setattr(module, "sample_telemetry", lambda: calls.append("sample") or module.TelemetrySample({}, []))
    monkeypatch.setattr(module, "rebuild", lambda: calls.append("rebuild") or setattr(module, "RUNTIME_DIRTY", False))
    monkeypatch.setattr(module, "reconcile_limits", lambda: calls.append("limits"))
    module.RUNTIME_DIRTY = True
    module.background_tick()
    assert calls == ["sample", "rebuild", "limits"]


def test_quota_background_rebuild_keeps_panel_responsive_and_runs_once(panel, monkeypatch):
    module, client = panel
    login(client)
    mib = 1024 * 1024
    client.post("/api/nodes", json={
        "name": "quota target", "protocol": "socks", "port": 22511, "traffic_limit_mb": 1,
    })
    client.post("/api/nodes", json={
        "name": "unlimited peer", "protocol": "socks", "port": 22512,
    })
    module.RUNTIME_DIRTY = False

    daemon_lock = threading.Lock()
    restart_started = threading.Event()
    allow_restart = threading.Event()
    stats_calls = []

    class Result:
        exit_code = 0
        output = b"Configuration OK"

    class BlockingContainer:
        status = "running"

        def __init__(self):
            self.restarts = 0

        def exec_run(self, command):
            return Result()

        def restart(self, timeout):
            self.restarts += 1
            with daemon_lock:
                restart_started.set()
                assert allow_restart.wait(3)

        def reload(self):
            # Model the Docker daemon being occupied by the in-flight restart.
            with daemon_lock:
                return None

    container = BlockingContainer()

    def stats():
        stats_calls.append(1)
        return {1: {"uplink": mib, "downlink": 0}, 2: {"uplink": mib * 10, "downlink": 0}}

    monkeypatch.setattr(module, "query_xray_stats", stats)
    monkeypatch.setattr(module, "active_connections", lambda ports: {port: 0 for port in ports})
    monkeypatch.setattr(module, "xray_container", lambda: container)
    monkeypatch.setattr(module, "reconcile_limits", lambda: None)
    monkeypatch.setattr(module, "runtime_service_statuses", lambda: {"xray": "running", "netguard": "disabled"})

    worker = threading.Thread(target=module.background_tick, daemon=True)
    worker.start()
    assert restart_started.wait(1), "quota enforcement did not reach the Xray restart"

    executor = ThreadPoolExecutor(max_workers=3)
    try:
        futures = {
            "login": executor.submit(client.get, "/login"),
            "health": executor.submit(client.get, "/healthz"),
            "nodes": executor.submit(client.get, "/api/nodes"),
        }
        responses = {}
        for name, future in futures.items():
            try:
                responses[name] = future.result(timeout=0.5)
            except FutureTimeout as exc:
                pytest.fail(f"{name} blocked behind quota enforcement: {exc}")
        assert responses["login"].status_code == 200
        assert responses["health"].status_code == 200
        assert responses["nodes"].status_code == 200
        assert module.STATE_LOCK.acquire(blocking=False), "quota rebuild held the panel state lock"
        module.STATE_LOCK.release()
    finally:
        allow_restart.set()
        worker.join(3)
        executor.shutdown(wait=True)

    assert not worker.is_alive(), "quota background thread deadlocked"
    assert stats_calls == [1], "rebuild recursively sampled Xray after the quota sample"
    assert container.restarts == 1
    rows = client.get("/api/nodes").json()
    assert {row["name"]: row["enabled"] for row in rows} == {
        "quota target": False,
        "unlimited peer": True,
    }

    module.background_tick()
    assert container.restarts == 1, "the next sample repeated an already-applied quota rebuild"


def test_failed_quota_restart_does_not_lock_panel(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "restart failure", "protocol": "socks", "port": 22513, "traffic_limit_mb": 1,
    })
    module.RUNTIME_DIRTY = False
    mib = 1024 * 1024

    class Result:
        exit_code = 0
        output = b"Configuration OK"

    class BrokenContainer:
        def exec_run(self, command):
            return Result()

        def restart(self, timeout):
            raise RuntimeError("restart failed")

    monkeypatch.setattr(module, "query_xray_stats", lambda: {1: {"uplink": mib, "downlink": 0}})
    monkeypatch.setattr(module, "active_connections", lambda ports: {port: 0 for port in ports})
    monkeypatch.setattr(module, "xray_container", lambda: BrokenContainer())
    monkeypatch.setattr(module, "reconcile_limits", lambda: None)
    monkeypatch.setattr(module, "runtime_service_statuses", lambda: {"xray": "unavailable", "netguard": "disabled"})

    with pytest.raises(RuntimeError, match="restart failed"):
        module.background_tick()

    assert module.STATE_LOCK.acquire(blocking=False)
    module.STATE_LOCK.release()
    assert client.get("/login").status_code == 200
    health = client.get("/healthz")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"
    assert client.get("/api/nodes").status_code == 200


def test_traffic_limit_persists_across_counter_reset_and_edit_preserves_usage(panel):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "persistent", "protocol": "socks", "port": 22505, "traffic_limit_mb": 100,
    })
    module.sample_telemetry({1: {"uplink": 1200, "downlink": 3000}}, {22505: 0}, now=1000)
    module.sample_telemetry({1: {"uplink": 100, "downlink": 200}}, {22505: 0}, now=1002)
    before = client.get("/api/nodes").json()[0]["traffic_used_bytes"]
    assert before == 4500
    edited = client.put("/api/nodes/1", json={"traffic_limit_mb": 200})
    assert edited.status_code == 200
    assert edited.json()["traffic_used_bytes"] == before


def test_traffic_reset_auth_and_raw_baseline_algorithm(panel, monkeypatch):
    module, client = panel
    unauthenticated = client.post("/api/nodes/1/traffic/reset")
    assert unauthenticated.status_code == 401
    login(client)
    client.post("/api/nodes", json={
        "name": "reset", "protocol": "socks", "port": 22506, "traffic_limit_mb": 1,
    })
    sample = module.sample_telemetry({1: {"uplink": 700000, "downlink": 400000}}, {22506: 0}, now=1000)
    module.disable_exceeded_nodes(sample.exceeded_ids)
    assert client.get("/api/nodes").json()[0]["traffic_exceeded"] is True
    monkeypatch.setattr(module, "query_xray_stats", lambda: {1: {"uplink": 700000, "downlink": 400000}})
    calls = []
    monkeypatch.setattr(module, "rebuild", lambda: calls.append("rebuild") or setattr(module, "RUNTIME_DIRTY", False))
    monkeypatch.setattr(module, "reconcile_limits", lambda: calls.append("limits"))
    reset = client.post("/api/nodes/1/traffic/reset")
    assert reset.status_code == 200
    assert reset.json()["traffic_used_bytes"] == 0
    assert reset.json()["enabled"] is True
    assert reset.json()["disabled_reason"] is None
    assert calls == ["rebuild", "limits"]
    same = module.sample_telemetry({1: {"uplink": 700000, "downlink": 400000}}, {22506: 0}, now=1002)[1]
    assert same["traffic_used_bytes"] == 0
    increased = module.sample_telemetry({1: {"uplink": 700123, "downlink": 400077}}, {22506: 0}, now=1004)[1]
    assert increased["traffic_used_bytes"] == 200


def test_reset_rebuild_failure_rolls_back_node_state(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "rollback reset", "protocol": "socks", "port": 22521, "traffic_limit_mb": 1,
    })
    _mark_quota_disabled(module, 1, 1024 * 1024, 22521)
    monkeypatch.setattr(module, "query_xray_stats", lambda: {1: {"uplink": 1024 * 1024, "downlink": 0}})
    attempts = []

    def fail_both_times():
        attempts.append(1)
        raise RuntimeError("rebuild failed")

    monkeypatch.setattr(module, "rebuild", fail_both_times)
    monkeypatch.setattr(module, "reconcile_limits", lambda: None)

    with pytest.raises(RuntimeError, match="rebuild failed"):
        client.post("/api/nodes/1/traffic/reset")
    with sqlite3.connect(module.DB_PATH) as connection:
        enabled, reason, used = connection.execute(
            "SELECT enabled,disabled_reason,traffic_uplink_base + traffic_uplink_raw-traffic_uplink_origin FROM nodes WHERE id=1"
        ).fetchone()
    assert (enabled, reason, used) == (0, "traffic_limit", 1024 * 1024)
    assert len(attempts) == 2


def test_update_rebuild_failure_rolls_back_auto_enable_and_reason(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "rollback edit", "protocol": "socks", "port": 22522, "traffic_limit_mb": 1,
    })
    _mark_quota_disabled(module, 1, 1024 * 1024, 22522)
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))
    attempts = []

    def fail_both_times():
        attempts.append(1)
        raise RuntimeError("rebuild failed")

    monkeypatch.setattr(module, "rebuild", fail_both_times)
    monkeypatch.setattr(module, "reconcile_limits", lambda: None)

    with pytest.raises(RuntimeError, match="rebuild failed"):
        client.put("/api/nodes/1", json={"traffic_limit_mb": 2})
    with sqlite3.connect(module.DB_PATH) as connection:
        assert connection.execute(
            "SELECT enabled,disabled_reason,traffic_limit_mb FROM nodes WHERE id=1"
        ).fetchone() == (0, "traffic_limit", 1)
    assert len(attempts) == 2


def test_traffic_reset_never_enables_expired_node(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "expired reset", "protocol": "socks", "port": 22514, "traffic_limit_mb": 1,
    })
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.execute(
            "UPDATE nodes SET enabled=0, disabled_reason='expired', expires_at=? WHERE id=1",
            (int(time.time()) - 1,),
        )
        connection.commit()
    monkeypatch.setattr(module, "query_xray_stats", lambda: {1: {"uplink": 2000000, "downlink": 0}})
    calls = []
    monkeypatch.setattr(module, "rebuild", lambda: calls.append("rebuild") or setattr(module, "RUNTIME_DIRTY", False))
    monkeypatch.setattr(module, "reconcile_limits", lambda: calls.append("limits"))

    reset = client.post("/api/nodes/1/traffic/reset")
    assert reset.status_code == 200
    assert reset.json()["traffic_used_bytes"] == 0
    assert reset.json()["enabled"] is False
    assert reset.json()["disabled_reason"] == "expired"
    assert reset.json()["expired"] is True
    assert calls == ["rebuild", "limits"]


def _mark_quota_disabled(module, node_id, used_bytes, port):
    sample = module.sample_telemetry(
        {node_id: {"uplink": used_bytes, "downlink": 0}}, {port: 0}, now=1000
    )
    module.disable_exceeded_nodes(sample.exceeded_ids)


def test_quota_edit_auto_enables_only_when_new_limit_allows(panel, monkeypatch):
    module, client = panel
    login(client)
    mib = 1024 * 1024
    client.post("/api/nodes", json={
        "name": "raise me", "protocol": "socks", "port": 22515, "traffic_limit_mb": 1,
    })
    _mark_quota_disabled(module, 1, mib, 22515)
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))

    still_exceeded = client.put("/api/nodes/1", json={"traffic_limit_mb": 1})
    assert still_exceeded.status_code == 200
    assert still_exceeded.json()["enabled"] is False
    assert still_exceeded.json()["disabled_reason"] == "traffic_limit"

    raised = client.put("/api/nodes/1", json={"traffic_limit_mb": 2})
    assert raised.status_code == 200
    assert raised.json()["enabled"] is True
    assert raised.json()["disabled_reason"] is None


def test_quota_edit_clear_limit_auto_enables(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "clear me", "protocol": "socks", "port": 22516, "traffic_limit_mb": 1,
    })
    _mark_quota_disabled(module, 1, 1024 * 1024, 22516)
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))

    cleared = client.put("/api/nodes/1", json={"traffic_limit_mb": None})
    assert cleared.status_code == 200
    assert cleared.json()["enabled"] is True
    assert cleared.json()["disabled_reason"] is None


def test_manual_disable_is_not_reversed_by_raise_clear_or_ordinary_edit(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "manual", "protocol": "socks", "port": 22517, "traffic_limit_mb": 1,
    })
    assert client.post("/api/nodes/1/toggle").status_code == 200
    disabled = client.get("/api/nodes").json()[0]
    assert disabled["enabled"] is False
    assert disabled["disabled_reason"] == "manual"
    assert client.post("/api/nodes/1/toggle").json()["disabled_reason"] is None
    assert client.post("/api/nodes/1/toggle").json()["disabled_reason"] == "manual"
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))

    renamed = client.put("/api/nodes/1", json={"name": "still manual"})
    assert renamed.json()["enabled"] is False
    assert renamed.json()["disabled_reason"] == "manual"
    raised = client.put("/api/nodes/1", json={"traffic_limit_mb": 2})
    assert raised.json()["enabled"] is False
    assert raised.json()["disabled_reason"] == "manual"
    cleared = client.put("/api/nodes/1", json={"traffic_limit_mb": None})
    assert cleared.json()["enabled"] is False
    assert cleared.json()["disabled_reason"] == "manual"


def test_quota_auto_enable_does_not_cross_nodes_or_enable_expired(panel, monkeypatch):
    module, client = panel
    login(client)
    mib = 1024 * 1024
    for name, port in (("target", 22518), ("peer", 22519), ("expired", 22520)):
        client.post("/api/nodes", json={
            "name": name, "protocol": "socks", "port": port, "traffic_limit_mb": 1,
        })
    sample = module.sample_telemetry(
        {1: {"uplink": mib}, 2: {"uplink": mib}, 3: {"uplink": mib}},
        {22518: 0, 22519: 0, 22520: 0}, now=1000,
    )
    module.disable_exceeded_nodes(sample.exceeded_ids)
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.execute(
            "UPDATE nodes SET expires_at=?, disabled_reason='expired' WHERE id=3",
            (int(time.time()) - 1,),
        )
        connection.commit()
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))

    raised = client.put("/api/nodes/1", json={"traffic_limit_mb": 2})
    assert raised.json()["enabled"] is True
    rows = {row["name"]: row for row in client.get("/api/nodes").json()}
    assert rows["peer"]["enabled"] is False
    assert rows["peer"]["disabled_reason"] == "traffic_limit"
    assert rows["expired"]["enabled"] is False
    expired_clear = client.put("/api/nodes/3", json={"traffic_limit_mb": None})
    assert expired_clear.json()["enabled"] is False
    assert expired_clear.json()["disabled_reason"] == "expired"


def test_expired_reason_auto_enables_only_after_future_expiry_edit(panel, monkeypatch):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={"name": "renew", "protocol": "socks", "port": 22523})
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.execute(
            "UPDATE nodes SET enabled=0, disabled_reason='expired', expires_at=? WHERE id=1",
            (int(time.time()) - 1,),
        )
        connection.commit()
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: module.TelemetrySample({}, []))

    renewed = client.put("/api/nodes/1", json={
        "expiration_mode": "days", "expires_in_days": 1,
    })
    assert renewed.status_code == 200
    assert renewed.json()["enabled"] is True
    assert renewed.json()["disabled_reason"] is None
    assert renewed.json()["expired"] is False


def test_exceeded_toggle_blocked_until_limit_raised_or_cleared(panel):
    module, client = panel
    login(client)
    client.post("/api/nodes", json={
        "name": "blocked", "protocol": "socks", "port": 22507, "traffic_limit_mb": 1,
    })
    sample = module.sample_telemetry({1: {"uplink": 1024 * 1024, "downlink": 0}}, {22507: 0}, now=1000)
    module.disable_exceeded_nodes(sample.exceeded_ids)
    blocked = client.post("/api/nodes/1/toggle")
    assert blocked.status_code == 409
    assert "流量" in blocked.json()["detail"]
    raised = client.put("/api/nodes/1", json={"traffic_limit_mb": 2})
    assert raised.status_code == 200
    assert raised.json()["enabled"] is True


def test_traffic_limit_ui_controls_and_reset_button(panel):
    module, client = panel
    login(client)
    html = client.get("/").text
    script = (Path(module.BASE_DIR) / "static/app.js").read_text()
    css = (Path(module.BASE_DIR) / "static/app.css").read_text()
    assert 'id="trafficLimitMb"' in html
    assert 'id="editTrafficLimitMb"' in html
    assert "data-traffic-reset" in script
    assert "api/nodes/${reset.dataset.trafficReset}/traffic/reset" in script
    assert "确定将该节点已用流量归零吗" in script
    assert "节点未到期时会自动启用并立即应用配置" in script
    assert "提高到当前用量以上或清除上限会自动启用" in html
    assert "traffic-progress" in script and "traffic-progress" in css
    assert "traffic_limit_mb" in script


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
    assert base64.urlsafe_b64decode(ss_auth).decode() == f"{module.DEFAULT_SS_METHOD}:{key}"
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


def test_shadowsocks_backend_exposes_all_five_methods(panel):
    module, _ = panel
    assert module.DEFAULT_SS_METHOD == "2022-blake3-aes-128-gcm"
    assert list(module.SS_METHOD_KEY_BYTES) == [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
        "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305",
    ]
    assert "method" in module.NodeInput.model_fields


def test_shadowsocks_selected_method_drives_config_link_and_serial(panel):
    module, client = panel
    login(client)
    response = client.post("/api/nodes", json={
        "name": "selected cipher", "protocol": "shadowsocks", "port": 22005,
        "method": "chacha20-poly1305", "password": "ordinary-password",
    })
    assert response.status_code == 201
    node = response.json()
    assert node["config"]["method"] == "chacha20-poly1305"
    auth = urlsplit(node["link"]).username
    auth += "=" * (-len(auth) % 4)
    assert base64.urlsafe_b64decode(auth).decode() == "chacha20-poly1305:ordinary-password"
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.row_factory = sqlite3.Row
        row = connection.execute("SELECT * FROM nodes WHERE id=1").fetchone()
    assert module.inbound(row)["settings"]["method"] == "chacha20-poly1305"


def test_shadowsocks_password_rules_and_invalid_method(panel):
    module, client = panel
    login(client)
    key256 = base64.b64encode(b"x" * 32).decode()
    valid = client.post("/api/nodes", json={
        "name": "aes256", "protocol": "shadowsocks", "port": 22006,
        "method": "2022-blake3-aes-256-gcm", "password": key256,
    })
    assert valid.status_code == 201
    assert valid.json()["config"]["password"] == key256
    wrong_size = client.post("/api/nodes", json={
        "name": "bad key", "protocol": "shadowsocks", "port": 22007,
        "method": "2022-blake3-aes-256-gcm", "password": base64.b64encode(b"short").decode(),
    })
    assert wrong_size.status_code == 422
    invalid = client.post("/api/nodes", json={
        "name": "bad method", "protocol": "shadowsocks", "port": 22008,
        "method": "rc4-md5", "password": "x",
    })
    assert invalid.status_code == 422


def test_legacy_shadowsocks_node_defaults_to_2022_aes128(panel):
    module, _ = panel
    key = base64.b64encode(b"0123456789abcdef").decode()
    with sqlite3.connect(module.DB_PATH) as connection:
        connection.execute(
            "INSERT INTO nodes(name,protocol,port,config,created_at) VALUES(?,?,?,?,?)",
            ("legacy ss", "shadowsocks", 22009, json.dumps({"password": key}), 1),
        )
        connection.commit()
        connection.row_factory = sqlite3.Row
        row = connection.execute("SELECT * FROM nodes WHERE name='legacy ss'").fetchone()
    assert module.config_shadowsocks_method(json.loads(row["config"])) == module.DEFAULT_SS_METHOD
    assert module.inbound(row)["settings"]["method"] == module.DEFAULT_SS_METHOD
    assert module.serial(row)["config"]["method"] == module.DEFAULT_SS_METHOD
    auth = urlsplit(module.link_for(row)).username
    auth += "=" * (-len(auth) % 4)
    assert base64.urlsafe_b64decode(auth).decode() == f"{module.DEFAULT_SS_METHOD}:{key}"


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
    # installs its fakes. Serialize with the dedicated rebuild lock first.
    with module.REBUILD_LOCK:
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


def test_native_backend_does_not_import_docker_and_whitelists_commands(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_" + "PASSWORD", "x")
    monkeypatch.setenv("APP_" + "SECRET", "y")
    monkeypatch.setenv("RUNTIME_BACKEND", "native")
    monkeypatch.setenv("DB_PATH", str(tmp_path / "native.db"))
    monkeypatch.setenv("XRAY_CONFIG_PATH", str(tmp_path / "config.json"))
    monkeypatch.setenv("NETGUARD_REQUIRED", "0")
    sys.modules.pop("app.main", None)
    before = sys.modules.get("docker")
    module = importlib.import_module("app.main")
    assert module.docker is None
    assert sys.modules.get("docker") is before
    with pytest.raises(RuntimeError, match="non-whitelisted"):
        module._systemctl("stop", module.XRAY_SERVICE)
    with pytest.raises(RuntimeError, match="non-whitelisted"):
        module._systemctl("restart", "ssh.service")


def test_native_rebuild_validates_fixed_binary_then_restarts_service(panel, monkeypatch):
    module, _ = panel
    module.XRAY_CONFIG_PATH.write_text('{"old": true}', encoding="utf-8")
    monkeypatch.setattr(module, "sample_telemetry", lambda *args, **kwargs: {})
    monkeypatch.setattr(module, "RUNTIME_BACKEND", "native")
    monkeypatch.setattr(module, "NATIVE_XRAY_BIN", Path("/fixed/xray"))
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        return type("R", (), {"returncode": 0, "stdout": "ok", "stderr": ""})()

    monkeypatch.setattr(module.subprocess, "run", run)
    monkeypatch.setattr(module, "_systemctl", lambda action, service: calls.append(["systemctl", action, service]) or "")
    module.rebuild()
    assert calls[0] == ["/fixed/xray", "run", "-test", "-config", str(module.XRAY_CONFIG_PATH)]
    assert calls[1] == ["systemctl", "restart", "nodelite-xray.service"]


def test_native_health_is_strict(panel, monkeypatch):
    module, client = panel
    monkeypatch.setattr(module, "RUNTIME_BACKEND", "native")
    monkeypatch.setattr(module, "NETGUARD_REQUIRED", True)
    monkeypatch.setattr(module, "native_service_status", lambda service: "running" if service == module.XRAY_SERVICE else "unavailable")
    assert client.get("/healthz").status_code == 200
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json()["status"] == "degraded"


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


def test_netguard_daemon_rolls_back_on_sigterm_path(tmp_path, monkeypatch):
    guard = load_netguard(tmp_path, monkeypatch)
    calls = []
    monkeypatch.setattr(guard, "reconcile", lambda: calls.append("reconcile") or [])
    monkeypatch.setattr(guard, "rollback", lambda: calls.append("rollback"))
    monkeypatch.setattr(guard.time, "monotonic", lambda: 0)

    def sleep(_seconds):
        raise KeyboardInterrupt

    monkeypatch.setattr(guard.time, "sleep", sleep)
    with pytest.raises(KeyboardInterrupt):
        guard.daemon(0.5)
    assert calls == ["reconcile", "rollback"]


def test_netguard_active_connection_mapping(tmp_path, monkeypatch):
    guard = load_netguard(tmp_path, monkeypatch)
    output = "0 0 127.0.0.1:30001 1.1.1.1:555\n0 0 [::]:30001 [::1]:9\n0 0 0.0.0.0:40000 2.2.2.2:1\n"
    monkeypatch.setattr(guard, "run", lambda *args, **kwargs: output)
    assert guard.status([30001, 40000]) == {"30001": 2, "40000": 1}
