from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import sqlite3
import threading
import time
import uuid
from contextlib import closing
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from typing import Literal
from urllib.parse import quote, urlencode

import docker
import qrcode
from docker.errors import DockerException, NotFound
from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("DB_PATH", "/data/panel.db"))
XRAY_CONFIG_PATH = Path(os.getenv("XRAY_CONFIG_PATH", "/xray-config/config.json"))
XRAY_CONTAINER = os.getenv("XRAY_CONTAINER", "simple-node-xray")
NETGUARD_CONTAINER = os.getenv("NETGUARD_CONTAINER", "simple-node-netguard")
NETGUARD_REQUIRED = os.getenv("NETGUARD_REQUIRED", "1") != "0"
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_CREDENTIAL = os.getenv("ADMIN_" + "PASSWORD", "")
SIGNING_SECRET = os.getenv("APP_" + "SECRET", "")
PUBLIC_HOST = os.getenv("PUBLIC_HOST", "127.0.0.1")
BACKGROUND_INTERVAL = max(1.0, float(os.getenv("BACKGROUND_INTERVAL_SECONDS", "2")))

DEFAULT_SS_METHOD = "2022-blake3-aes-128-gcm"
# Kept as an alias for callers that used the original single-method constant.
SS2022_METHOD = DEFAULT_SS_METHOD
SS_METHOD_KEY_BYTES = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "aes-128-gcm": None,
    "aes-256-gcm": None,
    "chacha20-poly1305": None,
}
REALITY_NETWORK = "raw"
REALITY_FLOW = "xtls-rprx-vision"
REALITY_FINGERPRINT = "chrome"
REALITY_SPIDER_X = "/"
XRAY_API_ADDRESS = "127.0.0.1:10085"
XRAY_METRICS_ADDRESS = "127.0.0.1:11111"

if not ADMIN_CREDENTIAL or not SIGNING_SECRET:
    raise RuntimeError("Administrator credential and application signing secret are required")

app = FastAPI(title="NodeLite", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")

STATE_LOCK = threading.RLock()
STOP_EVENT = threading.Event()
WORKER: threading.Thread | None = None
RATE_STATE: dict[int, tuple[int, int, float]] = {}
TELEMETRY: dict[int, dict] = {}
RUNTIME_DIRTY = False


class ExpirationFields(BaseModel):
    expiration_mode: Literal["never", "date", "days"] | None = None
    expires_at: datetime | None = None
    expires_in_days: int | None = Field(default=None, ge=1, le=3650)


class NodeInput(ExpirationFields):
    name: str = Field(min_length=1, max_length=80)
    protocol: str
    port: int | None = Field(default=None, ge=1, le=65535)
    username: str | None = None
    password: str | None = None
    method: str | None = None
    destination: str | None = None
    server_name: str | None = None
    max_connections: int | None = Field(default=None, ge=1, le=100000)


class NodeUpdate(ExpirationFields):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    max_connections: int | None = Field(default=None, ge=1, le=100000)


def connect_db():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def _columns(conn) -> set[str]:
    return {row[1] for row in conn.execute("PRAGMA table_info(nodes)")}


def init_db():
    """Create the original schema, then apply repeatable additive migrations."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with STATE_LOCK, closing(connect_db()) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""
        CREATE TABLE IF NOT EXISTS nodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          protocol TEXT NOT NULL,
          port INTEGER NOT NULL UNIQUE,
          enabled INTEGER NOT NULL DEFAULT 1,
          config TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
        """)
        conn.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at INTEGER NOT NULL
        )
        """)
        migrations = [
            (1, "expires_at", "ALTER TABLE nodes ADD COLUMN expires_at INTEGER"),
            (2, "max_connections", "ALTER TABLE nodes ADD COLUMN max_connections INTEGER"),
            (3, "traffic_uplink_base", "ALTER TABLE nodes ADD COLUMN traffic_uplink_base INTEGER NOT NULL DEFAULT 0"),
            (4, "traffic_downlink_base", "ALTER TABLE nodes ADD COLUMN traffic_downlink_base INTEGER NOT NULL DEFAULT 0"),
            (5, "traffic_uplink_raw", "ALTER TABLE nodes ADD COLUMN traffic_uplink_raw INTEGER NOT NULL DEFAULT 0"),
            (6, "traffic_downlink_raw", "ALTER TABLE nodes ADD COLUMN traffic_downlink_raw INTEGER NOT NULL DEFAULT 0"),
            (7, "traffic_sampled_at", "ALTER TABLE nodes ADD COLUMN traffic_sampled_at REAL"),
        ]
        columns = _columns(conn)
        for version, column, statement in migrations:
            if column not in columns:
                conn.execute(statement)
                columns.add(column)
            conn.execute(
                "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(?,?)",
                (version, int(time.time())),
            )
        conn.execute(
            "UPDATE nodes SET enabled=0 WHERE enabled=1 AND expires_at IS NOT NULL AND expires_at<=?",
            (int(time.time()),),
        )
        conn.commit()


def auth_token():
    raw = f"{ADMIN_USER}\0{ADMIN_CREDENTIAL}".encode()
    return hmac.new(SIGNING_SECRET.encode(), raw, hashlib.sha256).hexdigest()


def require_admin(request: Request):
    value = request.cookies.get("node_panel_session", "")
    if value and secrets.compare_digest(value, auth_token()):
        return ADMIN_USER
    raise HTTPException(401, "请先登录")


def docker_client():
    try:
        return docker.DockerClient(base_url="unix://var/run/docker.sock")
    except DockerException as exc:
        raise HTTPException(500, f"Docker 连接失败：{exc}") from exc


def named_container(name: str):
    try:
        return docker_client().containers.get(name)
    except NotFound:
        return None
    except DockerException as exc:
        raise HTTPException(500, f"读取容器失败：{exc}") from exc


def xray_container():
    return named_container(XRAY_CONTAINER)


def xray_exec(*args):
    container = xray_container()
    if not container:
        raise HTTPException(503, "Xray 尚未启动")
    result = container.exec_run(["xray", *args])
    text = result.output.decode(errors="replace").strip()
    if result.exit_code:
        raise HTTPException(500, text)
    return text


def netguard_exec(*args):
    if not NETGUARD_REQUIRED:
        return "{}"
    container = named_container(NETGUARD_CONTAINER)
    if not container:
        raise HTTPException(503, "连接限制执行器尚未启动")
    result = container.exec_run(["python3", "/netguard.py", *args])
    text = result.output.decode(errors="replace").strip()
    if result.exit_code:
        raise HTTPException(500, text or "连接限制规则执行失败")
    return text


def reconcile_limits():
    if NETGUARD_REQUIRED:
        netguard_exec("reconcile")


def active_connections(ports: list[int]) -> dict[int, int]:
    if not ports:
        return {}
    if not NETGUARD_REQUIRED:
        return {port: 0 for port in ports}
    text = netguard_exec("status", *[str(port) for port in ports])
    payload = json.loads(text or "{}")
    return {port: int(payload.get(str(port), 0)) for port in ports}


def free_port():
    with closing(connect_db()) as conn:
        used = {row[0] for row in conn.execute("SELECT port FROM nodes")}
    for _ in range(300):
        port = 20000 + secrets.randbelow(30000)
        if port in used:
            continue
        sock = socket.socket()
        try:
            sock.bind(("0.0.0.0", port))
            return port
        except OSError:
            pass
        finally:
            sock.close()
    raise HTTPException(500, "没有可用端口")


def x25519():
    output = xray_exec("x25519")
    private_key = public_key = ""
    for line in output.splitlines():
        label, separator, value = line.partition(":")
        if not separator:
            continue
        normalized = "".join(character for character in label.lower() if character.isalnum())
        if normalized == "privatekey":
            private_key = value.strip()
        elif normalized in {"password", "publickey", "passwordpublickey"}:
            public_key = value.strip()
    if not private_key or not public_key:
        raise HTTPException(500, "Reality 密钥生成失败")
    return private_key, public_key


def shadowsocks_method(value: str | None):
    method = (value or DEFAULT_SS_METHOD).strip()
    if method not in SS_METHOD_KEY_BYTES:
        raise HTTPException(422, "不支持的 Shadowsocks 加密方式")
    return method


def shadowsocks_password(method: str, value: str | None = None):
    key_bytes = SS_METHOD_KEY_BYTES[method]
    if key_bytes is None:
        # Traditional AEAD methods derive their key from an ordinary password.
        return value if value else secrets.token_urlsafe(24)
    if not value:
        return base64.b64encode(secrets.token_bytes(key_bytes)).decode()
    candidate = value.strip()
    try:
        decoded = base64.b64decode(candidate, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(
            422, f"{method} 密钥必须是 Base64 编码的 {key_bytes} 字节密钥"
        ) from exc
    if len(decoded) != key_bytes:
        raise HTTPException(422, f"{method} 密钥解码后必须正好为 {key_bytes} 字节")
    return base64.b64encode(decoded).decode()


def ss2022_key(value: str | None = None):
    """Backward-compatible validator for the original SS-2022 128-bit method."""
    return shadowsocks_password(DEFAULT_SS_METHOD, value)


def config_shadowsocks_method(cfg: dict):
    """Legacy Shadowsocks nodes predate per-node method storage."""
    return shadowsocks_method(cfg.get("method") or DEFAULT_SS_METHOD)


def reality_values(server_name: str | None, destination: str | None):
    name = (server_name or "www.apple.com").strip()
    if not name or "://" in name or any(character in name for character in "/?# "):
        raise HTTPException(422, "SNI 域名格式不正确")
    target = (destination or f"{name}:443").strip()
    host, separator, port_text = target.rpartition(":")
    if "://" in target or not separator or not host or not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        raise HTTPException(422, "Reality 目标必须使用 主机:端口 格式")
    return name, target


def resolve_expiration(fields: ExpirationFields, *, creating: bool, now: float | None = None):
    now = now if now is not None else time.time()
    mode = fields.expiration_mode
    if mode is None:
        if creating:
            mode = "never"
        else:
            return ...
    if mode == "never":
        if fields.expires_at is not None or fields.expires_in_days is not None:
            raise HTTPException(422, "永不过期模式不能同时填写日期或天数")
        return None
    if mode == "date":
        if fields.expires_at is None or fields.expires_in_days is not None:
            raise HTTPException(422, "按日期到期必须且只能填写 expires_at")
        value = fields.expires_at
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        timestamp = int(value.timestamp())
    else:
        if fields.expires_in_days is None or fields.expires_at is not None:
            raise HTTPException(422, "按天数到期必须且只能填写 expires_in_days")
        timestamp = int(now + fields.expires_in_days * 86400)
    if timestamp <= int(now):
        raise HTTPException(422, "到期时间必须晚于当前时间")
    return timestamp


def is_expired(row, now: int | None = None):
    expires_at = row["expires_at"]
    return expires_at is not None and expires_at <= (now if now is not None else int(time.time()))


def inbound(row):
    cfg = json.loads(row["config"])
    item = {
        "tag": f"node-{row['id']}",
        "listen": "0.0.0.0",
        "port": row["port"],
        "protocol": row["protocol"],
    }
    if row["protocol"] == "socks":
        item["settings"] = {
            "auth": "password",
            "accounts": [{"user": cfg["username"], "pass": cfg["password"]}],
            "udp": True,
        }
    elif row["protocol"] == "shadowsocks":
        item["settings"] = {
            "method": config_shadowsocks_method(cfg),
            "password": cfg["password"],
            "network": "tcp,udp",
        }
    else:
        item["settings"] = {
            "clients": [{"id": cfg["uuid"], "flow": REALITY_FLOW, "email": row["name"]}],
            "decryption": "none",
        }
        item["streamSettings"] = {
            "network": REALITY_NETWORK,
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": cfg["destination"],
                "xver": 0,
                "serverNames": [cfg["server_name"]],
                "privateKey": cfg["private_key"],
                "shortIds": [cfg["short_id"]],
            },
        }
    return item


def config_for(rows, now: int | None = None):
    now = now if now is not None else int(time.time())
    return {
        "log": {"loglevel": "warning"},
        "api": {"tag": "api", "listen": XRAY_API_ADDRESS, "services": ["StatsService"]},
        "metrics": {"tag": "Metrics", "listen": XRAY_METRICS_ADDRESS},
        "stats": {},
        "policy": {"system": {"statsInboundUplink": True, "statsInboundDownlink": True}},
        "inbounds": [inbound(row) for row in rows if row["enabled"] and not is_expired(row, now)],
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "blocked"},
        ],
        "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]},
    }


def current_rows():
    with closing(connect_db()) as conn:
        return conn.execute("SELECT * FROM nodes ORDER BY id").fetchall()


def write_config(rows=None):
    rows = rows if rows is not None else current_rows()
    XRAY_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    temp = XRAY_CONFIG_PATH.with_suffix(".tmp")
    temp.write_text(json.dumps(config_for(rows), ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(XRAY_CONFIG_PATH)


def parse_xray_stats(payload: str | dict) -> dict[int, dict[str, int]]:
    if isinstance(payload, str):
        start = payload.find("{")
        if start < 0:
            raise ValueError("Xray statistics response was not JSON")
        payload = json.loads(payload[start:])
    result: dict[int, dict[str, int]] = {}
    pattern = re.compile(r"^inbound>>>node-(\d+)>>>traffic>>>(uplink|downlink)$")
    for stat in payload.get("stat", []):
        match = pattern.match(str(stat.get("name", "")))
        if match:
            result.setdefault(int(match.group(1)), {})[match.group(2)] = int(stat.get("value", 0))
    return result


def query_xray_stats():
    return parse_xray_stats(xray_exec("api", "statsquery", f"--server={XRAY_API_ADDRESS}"))


def _telemetry_for_row(row, now: float, connections: int, rate: tuple[float, float] = (0.0, 0.0)):
    expires_at = row["expires_at"]
    expired = is_expired(row, int(now))
    total_up = int(row["traffic_uplink_base"] + row["traffic_uplink_raw"])
    total_down = int(row["traffic_downlink_base"] + row["traffic_downlink_raw"])
    return {
        "traffic_uplink": total_up,
        "traffic_downlink": total_down,
        "uplink_rate": max(0.0, rate[0]),
        "downlink_rate": max(0.0, rate[1]),
        "active_connections": max(0, int(connections)),
        "max_connections": row["max_connections"],
        "expires_at": expires_at,
        "remaining_seconds": None if expires_at is None else max(0, expires_at - int(now)),
        "expired": expired,
        "status": "expired" if expired else ("active" if row["enabled"] else "disabled"),
    }


def sample_telemetry(stats: dict[int, dict[str, int]] | None = None, connections: dict[int, int] | None = None, now: float | None = None):
    now = now if now is not None else time.time()
    with STATE_LOCK:
        stats = query_xray_stats() if stats is None else stats
        rows = current_rows()
        if connections is None:
            connections = active_connections([row["port"] for row in rows])
        with closing(connect_db()) as conn:
            for row in rows:
                values = stats.get(row["id"], {})
                raw_up = max(0, int(values.get("uplink", 0)))
                raw_down = max(0, int(values.get("downlink", 0)))
                base_up = int(row["traffic_uplink_base"])
                base_down = int(row["traffic_downlink_base"])
                old_raw_up = int(row["traffic_uplink_raw"])
                old_raw_down = int(row["traffic_downlink_raw"])
                if raw_up < old_raw_up:
                    base_up += old_raw_up
                if raw_down < old_raw_down:
                    base_down += old_raw_down
                conn.execute(
                    """UPDATE nodes SET traffic_uplink_base=?, traffic_downlink_base=?,
                       traffic_uplink_raw=?, traffic_downlink_raw=?, traffic_sampled_at=? WHERE id=?""",
                    (base_up, base_down, raw_up, raw_down, now, row["id"]),
                )
            conn.commit()
            rows = conn.execute("SELECT * FROM nodes ORDER BY id").fetchall()
        for row in rows:
            total_up = int(row["traffic_uplink_base"] + row["traffic_uplink_raw"])
            total_down = int(row["traffic_downlink_base"] + row["traffic_downlink_raw"])
            previous = RATE_STATE.get(row["id"])
            rate = (0.0, 0.0)
            if previous and now > previous[2]:
                elapsed = now - previous[2]
                rate = ((total_up - previous[0]) / elapsed, (total_down - previous[1]) / elapsed)
            RATE_STATE[row["id"]] = (total_up, total_down, now)
            TELEMETRY[row["id"]] = _telemetry_for_row(
                row, now, connections.get(row["port"], 0), rate
            )
        live_ids = {row["id"] for row in rows}
        for stale_id in set(TELEMETRY) - live_ids:
            TELEMETRY.pop(stale_id, None)
            RATE_STATE.pop(stale_id, None)
        return dict(TELEMETRY)


def rebuild():
    global RUNTIME_DIRTY
    with STATE_LOCK:
        try:
            sample_telemetry()
        except Exception:
            pass
        rows = current_rows()
        old = XRAY_CONFIG_PATH.read_bytes() if XRAY_CONFIG_PATH.exists() else None
        write_config(rows)
        container = xray_container()
        if not container:
            RUNTIME_DIRTY = True
            return
        check = container.exec_run(["xray", "run", "-test", "-config", "/etc/xray/config.json"])
        if check.exit_code:
            if old is not None:
                XRAY_CONFIG_PATH.write_bytes(old)
            else:
                XRAY_CONFIG_PATH.unlink(missing_ok=True)
            raise HTTPException(422, check.output.decode(errors="replace"))
        raw_snapshot = {
            row["id"]: (int(row["traffic_uplink_raw"]), int(row["traffic_downlink_raw"])) for row in current_rows()
        }
        container.restart(timeout=15)
        with closing(connect_db()) as conn:
            for node_id, (raw_up, raw_down) in raw_snapshot.items():
                conn.execute(
                    """UPDATE nodes SET traffic_uplink_base=traffic_uplink_base+?,
                       traffic_downlink_base=traffic_downlink_base+?,
                       traffic_uplink_raw=0, traffic_downlink_raw=0
                       WHERE id=? AND traffic_uplink_raw=? AND traffic_downlink_raw=?""",
                    (raw_up, raw_down, node_id, raw_up, raw_down),
                )
            conn.commit()
        RUNTIME_DIRTY = False


def expire_due_nodes(now: int | None = None):
    global RUNTIME_DIRTY
    now = now if now is not None else int(time.time())
    with STATE_LOCK, closing(connect_db()) as conn:
        due = [row[0] for row in conn.execute(
            "SELECT id FROM nodes WHERE enabled=1 AND expires_at IS NOT NULL AND expires_at<=?", (now,)
        )]
        if not due:
            return []
        conn.executemany("UPDATE nodes SET enabled=0 WHERE id=?", [(node_id,) for node_id in due])
        conn.commit()
    RUNTIME_DIRTY = True
    rebuild()
    reconcile_limits()
    return due


def background_tick():
    global RUNTIME_DIRTY
    expire_due_nodes()
    if RUNTIME_DIRTY:
        rebuild()
        reconcile_limits()
    sample_telemetry()


def background_loop():
    while not STOP_EVENT.is_set():
        try:
            background_tick()
        except Exception as exc:
            print(f"NodeLite background task failed: {exc}", flush=True)
        STOP_EVENT.wait(BACKGROUND_INTERVAL)


@app.on_event("startup")
def startup():
    global WORKER, RUNTIME_DIRTY
    init_db()
    write_config()
    # The control-plane must restore both the generated Xray configuration and
    # the dedicated connection-limit chain after every container/host restart.
    RUNTIME_DIRTY = True
    try:
        reconcile_limits()
    except Exception:
        if NETGUARD_REQUIRED:
            raise
    STOP_EVENT.clear()
    if WORKER is None or not WORKER.is_alive():
        WORKER = threading.Thread(target=background_loop, name="nodelite-controls", daemon=True)
        WORKER.start()


@app.on_event("shutdown")
def shutdown():
    STOP_EVENT.set()


def link_for(row):
    cfg = json.loads(row["config"])
    name = quote(row["name"], safe="")
    host = PUBLIC_HOST.strip()
    if row["protocol"] == "socks":
        username = quote(cfg["username"], safe="")
        password = quote(cfg["password"], safe="")
        return f"socks://{username}:{password}@{host}:{row['port']}#{name}"
    if row["protocol"] == "shadowsocks":
        userinfo = f"{config_shadowsocks_method(cfg)}:{cfg['password']}"
        auth = base64.urlsafe_b64encode(userinfo.encode()).decode().rstrip("=")
        return f"ss://{auth}@{host}:{row['port']}#{name}"
    query = urlencode(
        {
            "type": REALITY_NETWORK,
            "security": "reality",
            "flow": REALITY_FLOW,
            "sni": cfg["server_name"],
            "fp": REALITY_FINGERPRINT,
            "pbk": cfg["public_key"],
            "sid": cfg["short_id"],
            "spx": REALITY_SPIDER_X,
        }, quote_via=quote, safe="",
    )
    return f"vless://{cfg['uuid']}@{host}:{row['port']}?{query}#{name}"


def serial(row):
    cfg = json.loads(row["config"])
    if row["protocol"] == "shadowsocks":
        cfg["method"] = config_shadowsocks_method(cfg)
    telemetry = TELEMETRY.get(row["id"]) or _telemetry_for_row(row, time.time(), 0)
    return {
        "id": row["id"],
        "name": row["name"],
        "protocol": row["protocol"],
        "port": row["port"],
        "enabled": bool(row["enabled"]),
        "config": {key: value for key, value in cfg.items() if key != "private_key"},
        "link": link_for(row),
        "qr": f"api/nodes/{row['id']}/qr",
        **telemetry,
    }


def request_app_path(request: Request):
    path = request.scope.get("path", "/")
    root_path = request.scope.get("root_path", "")
    if root_path and path.startswith(root_path):
        path = path[len(root_path):] or "/"
    return path


def request_cookie_path(request: Request):
    forwarded_prefix = request.headers.get("x-forwarded-prefix", "").strip()
    root_path = forwarded_prefix or request.scope.get("root_path", "")
    return "/" if not root_path else "/" + root_path.strip("/") + "/"


def render_login(error: str = ""):
    template = (BASE_DIR / "static/login.html").read_text(encoding="utf-8")
    replacements = {
        "{error_hidden}": "" if error else "hidden",
        "{error_message}": error,
        "{invalid}": 'aria-invalid="true"' if error else "",
    }
    for marker, value in replacements.items():
        template = template.replace(marker, value)
    return template


def no_store(response: Response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@app.exception_handler(HTTPException)
async def handle_http(request, exc):
    path = request_app_path(request)
    if exc.status_code == 401 and not path.startswith("/api/") and path != "/login":
        return RedirectResponse("login", 303)
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)


@app.get("/healthz")
def healthz():
    statuses = {"xray": "unavailable", "netguard": "disabled" if not NETGUARD_REQUIRED else "unavailable"}
    for key, name in (("xray", XRAY_CONTAINER), ("netguard", NETGUARD_CONTAINER)):
        if key == "netguard" and not NETGUARD_REQUIRED:
            continue
        try:
            container = named_container(name)
            if container:
                container.reload()
                statuses[key] = "running" if container.status == "running" else container.status
            else:
                statuses[key] = "starting"
        except HTTPException:
            pass
    with closing(connect_db()) as conn:
        conn.execute("SELECT 1").fetchone()
    return {"status": "ok", **statuses}


@app.get("/login", response_class=HTMLResponse, response_model=None)
def login_page(request: Request) -> Response:
    if request.cookies.get("node_panel_session") == auth_token():
        return RedirectResponse("./", 303)
    return no_store(HTMLResponse(render_login()))


@app.post("/login", response_class=HTMLResponse, response_model=None)
def login(request: Request, username: str = Form(...), password: str = Form(...)) -> Response:
    if not (secrets.compare_digest(username, ADMIN_USER) and secrets.compare_digest(password, ADMIN_CREDENTIAL)):
        return no_store(HTMLResponse(render_login("用户名或密码错误，请重新输入。"), 401))
    response = RedirectResponse("./", 303)
    response.set_cookie(
        "node_panel_session", auth_token(), httponly=True,
        secure=request.url.scheme == "https", samesite="lax", max_age=604800,
        path=request_cookie_path(request),
    )
    return no_store(response)


@app.post("/logout")
def logout(request: Request):
    response = RedirectResponse("login", 303)
    response.delete_cookie("node_panel_session", path=request_cookie_path(request))
    return no_store(response)


@app.get("/", response_class=HTMLResponse)
def home(_=Depends(require_admin)):
    return no_store(HTMLResponse((BASE_DIR / "static/index.html").read_text(encoding="utf-8")))


@app.get("/api/nodes")
def nodes(_=Depends(require_admin)):
    with closing(connect_db()) as conn:
        return [serial(row) for row in conn.execute("SELECT * FROM nodes ORDER BY id DESC").fetchall()]


@app.get("/api/nodes/telemetry")
def nodes_telemetry(_=Depends(require_admin)):
    with closing(connect_db()) as conn:
        rows = conn.execute("SELECT * FROM nodes ORDER BY id DESC").fetchall()
    return [{"id": row["id"], **(TELEMETRY.get(row["id"]) or _telemetry_for_row(row, time.time(), 0))} for row in rows]


@app.post("/api/nodes", status_code=201)
def create(payload: NodeInput, _=Depends(require_admin)):
    protocol = payload.protocol.lower().strip()
    if protocol not in {"socks", "shadowsocks", "vless"}:
        raise HTTPException(422, "不支持的协议")
    name = payload.name.strip()
    if not name:
        raise HTTPException(422, "节点名称不能为空")
    expires_at = resolve_expiration(payload, creating=True)
    port = payload.port or free_port()
    if protocol == "socks":
        cfg = {
            "username": (payload.username or f"user{1000 + secrets.randbelow(9000)}").strip(),
            "password": payload.password or secrets.token_urlsafe(12),
        }
        if not cfg["username"]:
            raise HTTPException(422, "SOCKS 用户名不能为空")
    elif protocol == "shadowsocks":
        method = shadowsocks_method(payload.method)
        cfg = {"method": method, "password": shadowsocks_password(method, payload.password)}
    else:
        server_name, destination = reality_values(payload.server_name, payload.destination)
        private_key, public_key = x25519()
        cfg = {
            "uuid": str(uuid.uuid4()), "private_key": private_key, "public_key": public_key,
            "short_id": secrets.token_hex(4), "server_name": server_name, "destination": destination,
        }
    with STATE_LOCK, closing(connect_db()) as conn:
        try:
            cursor = conn.execute(
                """INSERT INTO nodes(name, protocol, port, config, created_at, expires_at, max_connections)
                   VALUES(?,?,?,?,?,?,?)""",
                (name, protocol, port, json.dumps(cfg), int(time.time()), expires_at, payload.max_connections),
            )
            conn.commit()
            node_id = cursor.lastrowid
        except sqlite3.IntegrityError as exc:
            raise HTTPException(409, "端口已占用") from exc
    try:
        rebuild()
        reconcile_limits()
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            conn.commit()
        rebuild()
        reconcile_limits()
        raise
    with closing(connect_db()) as conn:
        return serial(conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone())


@app.put("/api/nodes/{node_id}")
def update(node_id: int, payload: NodeUpdate, _=Depends(require_admin)):
    expires_at = resolve_expiration(payload, creating=False)
    with STATE_LOCK, closing(connect_db()) as conn:
        old = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not old:
            raise HTTPException(404, "节点不存在")
        name = old["name"] if payload.name is None else payload.name.strip()
        if not name:
            raise HTTPException(422, "节点名称不能为空")
        new_expiry = old["expires_at"] if expires_at is ... else expires_at
        max_connections = old["max_connections"]
        if "max_connections" in payload.model_fields_set:
            max_connections = payload.max_connections
        conn.execute(
            "UPDATE nodes SET name=?, expires_at=?, max_connections=? WHERE id=?",
            (name, new_expiry, max_connections, node_id),
        )
        conn.commit()
    try:
        rebuild()
        reconcile_limits()
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute(
                "UPDATE nodes SET name=?, expires_at=?, max_connections=?, enabled=? WHERE id=?",
                (old["name"], old["expires_at"], old["max_connections"], old["enabled"], node_id),
            )
            conn.commit()
        rebuild()
        reconcile_limits()
        raise
    with closing(connect_db()) as conn:
        return serial(conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone())


@app.post("/api/nodes/{node_id}/toggle")
def toggle(node_id: int, _=Depends(require_admin)):
    with STATE_LOCK, closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(404, "节点不存在")
        if not row["enabled"] and is_expired(row):
            raise HTTPException(409, "节点已到期，请先修改有效期")
        conn.execute("UPDATE nodes SET enabled=? WHERE id=?", (0 if row["enabled"] else 1, node_id))
        conn.commit()
    try:
        rebuild()
        reconcile_limits()
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute("UPDATE nodes SET enabled=? WHERE id=?", (row["enabled"], node_id))
            conn.commit()
        rebuild()
        reconcile_limits()
        raise
    with closing(connect_db()) as conn:
        return serial(conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone())


@app.delete("/api/nodes/{node_id}", status_code=204)
def delete(node_id: int, _=Depends(require_admin)):
    with STATE_LOCK, closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(404, "节点不存在")
        conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
        conn.commit()
    try:
        rebuild()
        reconcile_limits()
    except Exception:
        with closing(connect_db()) as conn:
            columns = [key for key in row.keys()]
            placeholders = ",".join("?" for _ in columns)
            conn.execute(f"INSERT INTO nodes({','.join(columns)}) VALUES({placeholders})", tuple(row[key] for key in columns))
            conn.commit()
        rebuild()
        reconcile_limits()
        raise
    TELEMETRY.pop(node_id, None)
    RATE_STATE.pop(node_id, None)
    return Response(status_code=204)


@app.get("/api/nodes/{node_id}/qr")
def qr(node_id: int, _=Depends(require_admin)):
    with closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not row:
        raise HTTPException(404, "节点不存在")
    image = qrcode.make(link_for(row), box_size=7, border=3)
    output = BytesIO()
    image.save(output, "PNG")
    return Response(output.getvalue(), media_type="image/png")
