from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import importlib
import json
import os
import re
import secrets
import socket
import sqlite3
import subprocess
import threading
import time
import uuid
from contextlib import closing
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from typing import Literal
from urllib.parse import quote, urlencode

import qrcode
from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator, model_validator

BASE_DIR = Path(__file__).resolve().parent
RUNTIME_BACKEND = os.getenv("RUNTIME_BACKEND", "native").strip().lower()
if RUNTIME_BACKEND not in {"native", "docker"}:
    raise RuntimeError("RUNTIME_BACKEND must be native or docker")
NODELITE_HOME = Path(os.getenv("NODELITE_HOME", "/opt/nodelite"))
DB_PATH = Path(os.getenv("DB_PATH", str(NODELITE_HOME / "data/panel.db") if RUNTIME_BACKEND == "native" else "/data/panel.db"))
XRAY_CONFIG_PATH = Path(os.getenv("XRAY_CONFIG_PATH", str(NODELITE_HOME / "xray-config/config.json") if RUNTIME_BACKEND == "native" else "/xray-config/config.json"))
XRAY_CONTAINER = os.getenv("XRAY_CONTAINER", "simple-node-xray")
NETGUARD_CONTAINER = os.getenv("NETGUARD_CONTAINER", "simple-node-netguard")
XRAY_SERVICE = "nodelite-xray.service"
NETGUARD_SERVICE = "nodelite-netguard.service"
NATIVE_XRAY_BIN = NODELITE_HOME / "bin/xray"
NATIVE_NETGUARD_BIN = NODELITE_HOME / "bin/nodelite-netguard"
NATIVE_NETGUARD_SOCKET = Path(os.getenv("NETGUARD_SOCKET", "/run/nodelite/netguard.sock"))
NETGUARD_REQUIRED = os.getenv("NETGUARD_REQUIRED", "1") != "0"
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_CREDENTIAL = os.getenv("ADMIN_" + "PASSWORD", "")
SIGNING_SECRET = os.getenv("APP_" + "SECRET", "")
PUBLIC_HOST = os.getenv("PUBLIC_HOST", "127.0.0.1")
BACKGROUND_INTERVAL = max(1.0, float(os.getenv("BACKGROUND_INTERVAL_SECONDS", "2")))

if RUNTIME_BACKEND == "native":
    # The native process neither imports nor connects to Docker.
    docker = None
    DockerException = NotFound = ()
else:
    docker = importlib.import_module("docker")
    DockerException = docker.errors.DockerException
    NotFound = docker.errors.NotFound

DEFAULT_SS_METHOD = "2022-blake3-aes-128-gcm"
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
MIB = 1024 * 1024
MAX_TRAFFIC_LIMIT_MB = 1_000_000_000

if not ADMIN_CREDENTIAL or not SIGNING_SECRET:
    raise RuntimeError("Administrator credential and application signing secret are required")

app = FastAPI(title="NodeLite", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")

STATE_LOCK = threading.RLock()
REBUILD_LOCK = threading.Lock()
TELEMETRY_LOCK = threading.Lock()
STOP_EVENT = threading.Event()
WORKER: threading.Thread | None = None
RATE_STATE: dict[int, tuple[int, int, float]] = {}
TELEMETRY: dict[int, dict] = {}
RUNTIME_DIRTY = False
LAST_SERVICE_STATUSES = {
    "xray": "starting",
    "netguard": "starting" if NETGUARD_REQUIRED else "disabled",
}


class ExpirationFields(BaseModel):
    expiration_mode: Literal["never", "date", "days"] | None = None
    expires_at: datetime | None = None
    expires_in_days: int | None = Field(default=None, ge=1, le=3650)


class TrafficLimitFields(BaseModel):
    traffic_limit_mb: int | None = None

    @field_validator("traffic_limit_mb", mode="before")
    @classmethod
    def validate_traffic_limit_mb(cls, value):
        if value is None or value == "":
            return None
        if isinstance(value, bool):
            raise ValueError("流量上限必须是整数 MB")
        if isinstance(value, str):
            if not value.strip().isdigit():
                raise ValueError("流量上限必须是整数 MB")
            value = int(value.strip())
        if not isinstance(value, int):
            raise ValueError("流量上限必须是整数 MB")
        if not 1 <= value <= MAX_TRAFFIC_LIMIT_MB:
            raise ValueError(f"流量上限必须在 1 到 {MAX_TRAFFIC_LIMIT_MB} MB 之间")
        return value


class DeviceLimitFields(BaseModel):
    max_devices: int | None = Field(default=None, ge=1, le=100000)
    # Deprecated request alias retained for clients deployed before the device
    # limit replaced the old aggregate TCP connection limit.
    max_connections: int | None = Field(default=None, ge=1, le=100000)

    @model_validator(mode="after")
    def matching_device_limit_aliases(self):
        fields = self.model_fields_set
        if {"max_devices", "max_connections"}.issubset(fields) and self.max_devices != self.max_connections:
            raise ValueError("max_devices 与旧字段 max_connections 不能冲突")
        return self

    def requested_device_limit(self):
        if "max_devices" in self.model_fields_set:
            return self.max_devices
        if "max_connections" in self.model_fields_set:
            return self.max_connections
        return ...


class NodeInput(ExpirationFields, TrafficLimitFields, DeviceLimitFields):
    name: str = Field(min_length=1, max_length=80)
    protocol: str
    port: int | None = Field(default=None, ge=1, le=65535)
    username: str | None = None
    password: str | None = None
    method: str | None = None
    destination: str | None = None
    server_name: str | None = None


class NodeUpdate(ExpirationFields, TrafficLimitFields, DeviceLimitFields):
    name: str | None = Field(default=None, min_length=1, max_length=80)


class TelemetrySample(dict):
    def __init__(self, telemetry: dict[int, dict], exceeded_ids: list[int]):
        super().__init__(telemetry)
        self.exceeded_ids = exceeded_ids


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
            (8, "traffic_limit_mb", "ALTER TABLE nodes ADD COLUMN traffic_limit_mb INTEGER"),
            (9, "traffic_uplink_origin", "ALTER TABLE nodes ADD COLUMN traffic_uplink_origin INTEGER NOT NULL DEFAULT 0"),
            (10, "traffic_downlink_origin", "ALTER TABLE nodes ADD COLUMN traffic_downlink_origin INTEGER NOT NULL DEFAULT 0"),
            (11, "disabled_reason", "ALTER TABLE nodes ADD COLUMN disabled_reason TEXT"),
            (12, "max_devices", "ALTER TABLE nodes ADD COLUMN max_devices INTEGER"),
        ]
        columns = _columns(conn)
        legacy_without_disabled_reason = "disabled_reason" not in columns
        for version, column, statement in migrations:
            if column not in columns:
                conn.execute(statement)
                columns.add(column)
            conn.execute(
                "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(?,?)",
                (version, int(time.time())),
            )
        # Preserve old databases and old API clients without changing the
        # meaning of their stored value during an in-place upgrade.
        conn.execute(
            "UPDATE nodes SET max_devices=max_connections WHERE max_devices IS NULL AND max_connections IS NOT NULL"
        )
        now = int(time.time())
        if legacy_without_disabled_reason:
            # Upgrade inference is deliberately conservative: expired wins
            # over quota, quota is inferred only when persisted counters prove
            # it, and every other legacy disabled row remains manual/unknown.
            conn.execute(
                """UPDATE nodes SET enabled=0, disabled_reason='expired'
                   WHERE expires_at IS NOT NULL AND expires_at<=?""",
                (now,),
            )
            conn.execute(
                """UPDATE nodes SET enabled=0, disabled_reason='traffic_limit'
                   WHERE disabled_reason IS NULL AND traffic_limit_mb IS NOT NULL
                     AND traffic_uplink_base + MAX(traffic_uplink_raw-traffic_uplink_origin, 0)
                       + traffic_downlink_base + MAX(traffic_downlink_raw-traffic_downlink_origin, 0)
                       >= traffic_limit_mb * ?""",
                (MIB,),
            )
            conn.execute(
                "UPDATE nodes SET disabled_reason='manual' WHERE enabled=0 AND disabled_reason IS NULL"
            )
        else:
            # On normal restarts preserve the explicit reason already stored.
            # Only active rows can acquire a new automatic stop reason.
            conn.execute("UPDATE nodes SET disabled_reason=NULL WHERE enabled=1")
            conn.execute(
                """UPDATE nodes SET enabled=0, disabled_reason='expired'
                   WHERE enabled=1 AND expires_at IS NOT NULL AND expires_at<=?""",
                (now,),
            )
            conn.execute(
                """UPDATE nodes SET enabled=0, disabled_reason='traffic_limit'
                   WHERE enabled=1 AND traffic_limit_mb IS NOT NULL
                     AND traffic_uplink_base + MAX(traffic_uplink_raw-traffic_uplink_origin, 0)
                       + traffic_downlink_base + MAX(traffic_downlink_raw-traffic_downlink_origin, 0)
                       >= traffic_limit_mb * ?""",
                (MIB,),
            )
            conn.execute(
                "UPDATE nodes SET disabled_reason='manual' WHERE enabled=0 AND disabled_reason IS NULL"
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


def _run_native(command: list[str], *, failure_status: int = 500) -> str:
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise HTTPException(failure_status, f"本地服务命令失败：{exc}") from exc
    text = (result.stdout or result.stderr).strip()
    if result.returncode:
        raise HTTPException(failure_status, text or "本地服务命令失败")
    return text


def _systemctl(action: str, service: str, *, failure_status: int = 500) -> str:
    if action not in {"is-active", "restart"} or service not in {XRAY_SERVICE, NETGUARD_SERVICE}:
        raise RuntimeError("refusing non-whitelisted systemctl operation")
    return _run_native(["systemctl", action, service], failure_status=failure_status)


def _native_netguard_health() -> bool:
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2)
        try:
            client.connect(str(NATIVE_NETGUARD_SOCKET))
            payload = client.recv(4096)
        finally:
            client.close()
        return json.loads(payload.decode()).get("status") == "ok"
    except (OSError, ValueError, json.JSONDecodeError):
        return False


def native_service_status(service: str) -> str:
    try:
        value = _systemctl("is-active", service, failure_status=503)
        running = value == "active"
        if running and service == NETGUARD_SERVICE:
            running = _native_netguard_health()
        return "running" if running else (value if value != "active" else "unhealthy")
    except HTTPException:
        return "unavailable"


def runtime_service_statuses() -> dict[str, str]:
    if RUNTIME_BACKEND == "native":
        return {
            "xray": native_service_status(XRAY_SERVICE),
            "netguard": "disabled" if not NETGUARD_REQUIRED else native_service_status(NETGUARD_SERVICE),
        }
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
    return statuses


def refresh_runtime_service_statuses() -> dict[str, str]:
    statuses = runtime_service_statuses()
    with TELEMETRY_LOCK:
        LAST_SERVICE_STATUSES.update(statuses)
        return dict(LAST_SERVICE_STATUSES)


def mark_runtime_service_statuses(*, xray: str | None = None, netguard: str | None = None):
    with TELEMETRY_LOCK:
        if xray is not None:
            LAST_SERVICE_STATUSES["xray"] = xray
        if netguard is not None:
            LAST_SERVICE_STATUSES["netguard"] = netguard


def docker_client():
    if RUNTIME_BACKEND != "docker":
        raise RuntimeError("Docker API is disabled by the native runtime backend")
    try:
        return docker.DockerClient(base_url="unix://var/run/docker.sock")
    except Exception as exc:
        if DockerException and isinstance(exc, DockerException):
            raise HTTPException(500, f"Docker 连接失败：{exc}") from exc
        raise


def named_container(name: str):
    try:
        return docker_client().containers.get(name)
    except Exception as exc:
        if NotFound and isinstance(exc, NotFound):
            return None
        if DockerException and isinstance(exc, DockerException):
            raise HTTPException(500, f"读取容器失败：{exc}") from exc
        raise


def xray_container():
    return named_container(XRAY_CONTAINER)


def xray_exec(*args):
    if RUNTIME_BACKEND == "native":
        return _run_native([str(NATIVE_XRAY_BIN), *args], failure_status=503)
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
    if RUNTIME_BACKEND == "native":
        return _run_native([str(NATIVE_NETGUARD_BIN), *args], failure_status=503)
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


def active_devices(ports: list[int]) -> dict[int, int]:
    if not ports:
        return {}
    if not NETGUARD_REQUIRED:
        return {port: 0 for port in ports}
    text = netguard_exec("status", *[str(port) for port in ports])
    payload = json.loads(text or "{}")
    return {port: int(payload.get(str(port), 0)) for port in ports}


def active_connections(ports: list[int]) -> dict[int, int]:
    """Deprecated internal alias retained for integrations/tests."""
    return active_devices(ports)


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


def ss2022_key(value: str | None = None):
    if not value:
        return base64.b64encode(secrets.token_bytes(SS2022_KEY_BYTES)).decode()
    candidate = value.strip()
    try:
        decoded = base64.b64decode(candidate, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(422, "SS-2022 密钥必须是 Base64 编码的 16 字节密钥") from exc
    if len(decoded) != SS2022_KEY_BYTES:
        raise HTTPException(422, "SS-2022 密钥解码后必须正好为 16 字节")
    return base64.b64encode(decoded).decode()


def reality_values(server_name: str | None, destination: str | None):
    name = (server_name or "www.atlasobscura.com").strip()
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


def shadowsocks_method(value: str | None) -> str:
    method = (value or DEFAULT_SS_METHOD).strip().lower()
    if method not in SS_METHOD_KEY_BYTES:
        raise HTTPException(422, "不支持的 Shadowsocks 加密方式")
    return method


def shadowsocks_password(method: str, password: str | None) -> str:
    key_bytes = SS_METHOD_KEY_BYTES[method]
    if key_bytes is None:
        return password or secrets.token_urlsafe(18)
    if not password:
        return base64.b64encode(secrets.token_bytes(key_bytes)).decode()
    try:
        decoded = base64.b64decode(password, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(422, "SS-2022 密钥必须是有效的 Base64") from exc
    if len(decoded) != key_bytes:
        raise HTTPException(422, f"该 SS-2022 加密方式需要 {key_bytes} 字节密钥")
    return password


def config_shadowsocks_method(config: dict) -> str:
    # Configs written before cipher selection did not persist a method.
    return shadowsocks_method(config.get("method"))


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


def traffic_totals(row) -> tuple[int, int]:
    total_up = int(row["traffic_uplink_base"] + max(row["traffic_uplink_raw"] - row["traffic_uplink_origin"], 0))
    total_down = int(row["traffic_downlink_base"] + max(row["traffic_downlink_raw"] - row["traffic_downlink_origin"], 0))
    return max(0, total_up), max(0, total_down)


def traffic_limit_values(row, used: int | None = None) -> dict:
    used = sum(traffic_totals(row)) if used is None else max(0, int(used))
    limit_mb = row["traffic_limit_mb"]
    limit_bytes = None if limit_mb is None else int(limit_mb) * MIB
    exceeded = limit_bytes is not None and used >= limit_bytes
    return {
        "traffic_limit_mb": limit_mb,
        "traffic_limit_bytes": limit_bytes,
        "traffic_used_bytes": used,
        "traffic_remaining_bytes": None if limit_bytes is None else max(0, limit_bytes - used),
        "traffic_percent": None if limit_bytes is None else round(used * 100 / limit_bytes, 2),
        "traffic_exceeded": exceeded,
    }


def _device_limit(row):
    keys = row.keys()
    if "max_devices" in keys and row["max_devices"] is not None:
        return row["max_devices"]
    return row["max_connections"] if "max_connections" in keys else None


def _telemetry_for_row(row, now: float, devices: int, rate: tuple[float, float] = (0.0, 0.0)):
    expires_at = row["expires_at"]
    expired = is_expired(row, int(now))
    total_up, total_down = traffic_totals(row)
    limit = traffic_limit_values(row, total_up + total_down)
    status = "expired" if expired else ("traffic_exceeded" if limit["traffic_exceeded"] else ("active" if row["enabled"] else "disabled"))
    return {
        "traffic_uplink": total_up,
        "traffic_downlink": total_down,
        "uplink_rate": max(0.0, rate[0]),
        "downlink_rate": max(0.0, rate[1]),
        "active_devices": max(0, int(devices)),
        "max_devices": _device_limit(row),
        # Response aliases keep older dashboards/API consumers working. Their
        # semantics are upgraded to source-IP devices, not TCP socket count.
        "active_connections": max(0, int(devices)),
        "max_connections": _device_limit(row),
        "expires_at": expires_at,
        "remaining_seconds": None if expires_at is None else max(0, expires_at - int(now)),
        "expired": expired,
        "status": status,
        **limit,
    }


def sample_telemetry(stats: dict[int, dict[str, int]] | None = None, devices: dict[int, int] | None = None, now: float | None = None):
    """Persist one Xray sample and return telemetry plus newly exceeded IDs.

    Runtime enforcement deliberately happens in ``background_tick`` after this
    function has released both SQLite and ``STATE_LOCK``. This keeps sampling
    free of Xray restarts and prevents rebuild -> sample -> rebuild recursion.
    """
    now = now if now is not None else time.time()
    stats = query_xray_stats() if stats is None else stats
    with closing(connect_db()) as conn:
        rows = conn.execute("SELECT * FROM nodes ORDER BY id").fetchall()
    if devices is None:
        devices = active_devices([row["port"] for row in rows])
    exceeded_ids = []
    with STATE_LOCK, closing(connect_db()) as conn:
        rows = conn.execute("SELECT * FROM nodes ORDER BY id").fetchall()
        for row in rows:
            values = stats.get(row["id"], {})
            raw_up = max(0, int(values.get("uplink", 0)))
            raw_down = max(0, int(values.get("downlink", 0)))
            base_up = int(row["traffic_uplink_base"])
            base_down = int(row["traffic_downlink_base"])
            old_raw_up = int(row["traffic_uplink_raw"])
            old_raw_down = int(row["traffic_downlink_raw"])
            origin_up = int(row["traffic_uplink_origin"])
            origin_down = int(row["traffic_downlink_origin"])
            if raw_up < old_raw_up:
                base_up += max(0, old_raw_up - origin_up)
                origin_up = 0
            if raw_down < old_raw_down:
                base_down += max(0, old_raw_down - origin_down)
                origin_down = 0
            conn.execute(
                """UPDATE nodes SET traffic_uplink_base=?, traffic_downlink_base=?,
                   traffic_uplink_raw=?, traffic_downlink_raw=?, traffic_uplink_origin=?,
                   traffic_downlink_origin=?, traffic_sampled_at=? WHERE id=?""",
                (base_up, base_down, raw_up, raw_down, origin_up, origin_down, now, row["id"]),
            )
        exceeded_ids = [row[0] for row in conn.execute(
            """SELECT id FROM nodes WHERE enabled=1 AND traffic_limit_mb IS NOT NULL
               AND traffic_uplink_base + MAX(traffic_uplink_raw-traffic_uplink_origin, 0)
                 + traffic_downlink_base + MAX(traffic_downlink_raw-traffic_downlink_origin, 0)
                 >= traffic_limit_mb * ?""",
            (MIB,),
        )]
        conn.commit()
        rows = conn.execute("SELECT * FROM nodes ORDER BY id").fetchall()
    with TELEMETRY_LOCK:
        for row in rows:
            total_up, total_down = traffic_totals(row)
            previous = RATE_STATE.get(row["id"])
            rate = (0.0, 0.0)
            if previous and now > previous[2]:
                elapsed = now - previous[2]
                rate = ((total_up - previous[0]) / elapsed, (total_down - previous[1]) / elapsed)
            RATE_STATE[row["id"]] = (total_up, total_down, now)
            TELEMETRY[row["id"]] = _telemetry_for_row(
                row, now, devices.get(row["port"], 0), rate
            )
        live_ids = {row["id"] for row in rows}
        for stale_id in set(TELEMETRY) - live_ids:
            TELEMETRY.pop(stale_id, None)
            RATE_STATE.pop(stale_id, None)
        return TelemetrySample(dict(TELEMETRY), exceeded_ids)


def validate_native_xray_config():
    try:
        result = subprocess.run(
            [str(NATIVE_XRAY_BIN), "run", "-test", "-config", str(XRAY_CONFIG_PATH)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise HTTPException(422, f"无法执行 Xray 配置验证：{exc}") from exc
    if result.returncode:
        raise HTTPException(422, (result.stderr or result.stdout).strip())


def rebuild():
    global RUNTIME_DIRTY
    # Serialize rebuilds without monopolising STATE_LOCK while Xray validates
    # and restarts. Panel HTTP and SQLite reads remain available throughout.
    with REBUILD_LOCK:
        with STATE_LOCK:
            rows = current_rows()
            old = XRAY_CONFIG_PATH.read_bytes() if XRAY_CONFIG_PATH.exists() else None
            write_config(rows)
            raw_snapshot = {
                row["id"]: (
                    int(row["traffic_uplink_raw"]), int(row["traffic_downlink_raw"]),
                    int(row["traffic_uplink_origin"]), int(row["traffic_downlink_origin"]),
                ) for row in rows
            }
        try:
            if RUNTIME_BACKEND == "native":
                validate_native_xray_config()
                _systemctl("restart", XRAY_SERVICE)
            else:
                container = xray_container()
                if not container:
                    RUNTIME_DIRTY = True
                    return
                check = container.exec_run(["xray", "run", "-test", "-config", "/etc/xray/config.json"])
                if check.exit_code:
                    raise HTTPException(422, check.output.decode(errors="replace"))
                container.restart(timeout=15)
            mark_runtime_service_statuses(xray="running")
        except Exception:
            if old is not None:
                XRAY_CONFIG_PATH.write_bytes(old)
            else:
                XRAY_CONFIG_PATH.unlink(missing_ok=True)
            mark_runtime_service_statuses(xray="unavailable")
            RUNTIME_DIRTY = True
            raise
        with STATE_LOCK, closing(connect_db()) as conn:
            for node_id, (raw_up, raw_down, origin_up, origin_down) in raw_snapshot.items():
                conn.execute(
                    """UPDATE nodes SET traffic_uplink_base=traffic_uplink_base+?,
                       traffic_downlink_base=traffic_downlink_base+?,
                       traffic_uplink_raw=0, traffic_downlink_raw=0,
                       traffic_uplink_origin=0, traffic_downlink_origin=0
                       WHERE id=? AND traffic_uplink_raw=? AND traffic_downlink_raw=?
                         AND traffic_uplink_origin=? AND traffic_downlink_origin=?""",
                    (max(0, raw_up - origin_up), max(0, raw_down - origin_down),
                     node_id, raw_up, raw_down, origin_up, origin_down),
                )
            conn.commit()
        RUNTIME_DIRTY = False


def disable_exceeded_nodes(node_ids: list[int]) -> list[int]:
    """Apply sampled quota transitions once, outside the sampling transaction."""
    global RUNTIME_DIRTY
    if not node_ids:
        return []
    placeholders = ",".join("?" for _ in node_ids)
    with STATE_LOCK, closing(connect_db()) as conn:
        applied = [row[0] for row in conn.execute(
            f"SELECT id FROM nodes WHERE enabled=1 AND id IN ({placeholders})", node_ids
        )]
        if applied:
            conn.executemany(
                "UPDATE nodes SET enabled=0, disabled_reason='traffic_limit' WHERE id=?",
                [(node_id,) for node_id in applied],
            )
            conn.commit()
    if applied:
        RUNTIME_DIRTY = True
    return applied


def apply_runtime(*, sample_first: bool = True, force: bool = False):
    """Persist counters, apply state transitions, then rebuild exactly once."""
    global RUNTIME_DIRTY
    if sample_first:
        try:
            exceeded_ids = sample_telemetry().exceeded_ids
        except Exception:
            exceeded_ids = []
        disable_exceeded_nodes(exceeded_ids)
    if force or RUNTIME_DIRTY:
        rebuild()
        reconcile_limits()


def expire_due_nodes(now: int | None = None, apply_runtime: bool = True):
    global RUNTIME_DIRTY
    now = now if now is not None else int(time.time())
    with STATE_LOCK, closing(connect_db()) as conn:
        due = [row[0] for row in conn.execute(
            "SELECT id FROM nodes WHERE enabled=1 AND expires_at IS NOT NULL AND expires_at<=?", (now,)
        )]
        if not due:
            return []
        conn.executemany(
            "UPDATE nodes SET enabled=0, disabled_reason='expired' WHERE id=?",
            [(node_id,) for node_id in due],
        )
        conn.commit()
    RUNTIME_DIRTY = True
    if apply_runtime:
        rebuild()
        reconcile_limits()
    return due


def background_tick():
    global RUNTIME_DIRTY
    expire_due_nodes(apply_runtime=False)
    sample = sample_telemetry()
    disable_exceeded_nodes(getattr(sample, "exceeded_ids", []))
    apply_runtime(sample_first=False)
    refresh_runtime_service_statuses()


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
    with TELEMETRY_LOCK:
        telemetry = TELEMETRY.get(row["id"])
    telemetry = telemetry or _telemetry_for_row(row, time.time(), 0)
    return {
        "id": row["id"],
        "name": row["name"],
        "protocol": row["protocol"],
        "port": row["port"],
        "enabled": bool(row["enabled"]),
        "disabled_reason": row["disabled_reason"],
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
    # Liveness must never wait on Docker/systemctl while a quota rebuild is in
    # progress. The worker refreshes these cached dependency statuses.
    with TELEMETRY_LOCK:
        statuses = dict(LAST_SERVICE_STATUSES)
    with closing(connect_db()) as conn:
        conn.execute("SELECT 1").fetchone()
    return JSONResponse({"status": "ok", **statuses})


@app.get("/readyz")
def readyz():
    """Strict dependency readiness, separate from the non-blocking liveness API."""
    statuses = refresh_runtime_service_statuses()
    with closing(connect_db()) as conn:
        conn.execute("SELECT 1").fetchone()
    healthy = statuses["xray"] == "running" and statuses["netguard"] in {"running", "disabled"}
    return JSONResponse({"status": "ok" if healthy else "degraded", **statuses}, status_code=200 if healthy else 503)


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
    with TELEMETRY_LOCK:
        telemetry = dict(TELEMETRY)
    return [{"id": row["id"], **(telemetry.get(row["id"]) or _telemetry_for_row(row, time.time(), 0))} for row in rows]


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
    requested_device_limit = payload.requested_device_limit()
    max_devices = None if requested_device_limit is ... else requested_device_limit
    with STATE_LOCK, closing(connect_db()) as conn:
        try:
            cursor = conn.execute(
                """INSERT INTO nodes(name, protocol, port, config, created_at, expires_at,
                   max_connections, max_devices, traffic_limit_mb) VALUES(?,?,?,?,?,?,?,?,?)""",
                (name, protocol, port, json.dumps(cfg), int(time.time()), expires_at,
                 max_devices, max_devices, payload.traffic_limit_mb),
            )
            conn.commit()
            node_id = cursor.lastrowid
        except sqlite3.IntegrityError as exc:
            raise HTTPException(409, "端口已占用") from exc
    try:
        apply_runtime(force=True)
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            conn.commit()
        apply_runtime(force=True)
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
        max_devices = _device_limit(old)
        requested_device_limit = payload.requested_device_limit()
        if requested_device_limit is not ...:
            max_devices = requested_device_limit
        traffic_limit_mb = old["traffic_limit_mb"]
        if "traffic_limit_mb" in payload.model_fields_set:
            traffic_limit_mb = payload.traffic_limit_mb
        enabled = int(old["enabled"])
        disabled_reason = old["disabled_reason"]
        if new_expiry is not None and new_expiry <= int(time.time()):
            enabled = 0
            if old["enabled"] or disabled_reason is None:
                disabled_reason = "expired"
        elif disabled_reason == "expired" and (new_expiry is None or new_expiry > int(time.time())):
            enabled = 1
            disabled_reason = None
        elif disabled_reason == "traffic_limit" and "traffic_limit_mb" in payload.model_fields_set:
            used = sum(traffic_totals(old))
            if traffic_limit_mb is None or used < traffic_limit_mb * MIB:
                enabled = 1
                disabled_reason = None
        conn.execute(
            """UPDATE nodes SET name=?, expires_at=?, max_connections=?, max_devices=?, traffic_limit_mb=?,
               enabled=?, disabled_reason=? WHERE id=?""",
            (name, new_expiry, max_devices, max_devices, traffic_limit_mb,
             enabled, disabled_reason, node_id),
        )
        conn.commit()
    try:
        apply_runtime(force=True)
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute(
                """UPDATE nodes SET name=?, expires_at=?, max_connections=?, max_devices=?,
                   traffic_limit_mb=?, enabled=?, disabled_reason=? WHERE id=?""",
                (old["name"], old["expires_at"], old["max_connections"], old["max_devices"],
                 old["traffic_limit_mb"], old["enabled"], old["disabled_reason"], node_id),
            )
            conn.commit()
        apply_runtime(force=True)
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
        if not row["enabled"] and traffic_limit_values(row)["traffic_exceeded"]:
            raise HTTPException(409, "节点流量已达到上限，请先提高或清除上限，或重置已用流量")
        next_enabled = 0 if row["enabled"] else 1
        conn.execute(
            "UPDATE nodes SET enabled=?, disabled_reason=? WHERE id=?",
            (next_enabled, None if next_enabled else "manual", node_id),
        )
        conn.commit()
    try:
        apply_runtime(force=True)
    except Exception:
        with closing(connect_db()) as conn:
            conn.execute(
                "UPDATE nodes SET enabled=?, disabled_reason=? WHERE id=?",
                (row["enabled"], row["disabled_reason"], node_id),
            )
            conn.commit()
        apply_runtime(force=True)
        raise
    with closing(connect_db()) as conn:
        return serial(conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone())


@app.post("/api/nodes/{node_id}/traffic/reset")
def reset_traffic(node_id: int, _=Depends(require_admin)):
    # Query Xray before taking STATE_LOCK; Docker/systemctl calls may be slow.
    stats = query_xray_stats()
    with STATE_LOCK, closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(404, "节点不存在")
        # A reset must use the live Xray counters. Falling back to a stale DB
        # sample would make pre-reset bytes appear again on the next sample.
        current = stats.get(node_id, {})
        raw_up = max(0, int(current.get("uplink", 0)))
        raw_down = max(0, int(current.get("downlink", 0)))
        old = dict(row)
        enable_after_reset = not is_expired(row)
        disabled_after_reset = None
        if not enable_after_reset:
            disabled_after_reset = row["disabled_reason"] if not row["enabled"] and row["disabled_reason"] else "expired"
        conn.execute(
            """UPDATE nodes SET traffic_uplink_base=0, traffic_downlink_base=0,
               traffic_uplink_raw=?, traffic_downlink_raw=?, traffic_uplink_origin=?,
               traffic_downlink_origin=?, traffic_sampled_at=?, enabled=?, disabled_reason=?
               WHERE id=?""",
            (raw_up, raw_down, raw_up, raw_down, time.time(),
             1 if enable_after_reset else 0, disabled_after_reset, node_id),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
    try:
        apply_runtime(sample_first=False, force=True)
    except Exception:
        with STATE_LOCK, closing(connect_db()) as conn:
            columns = list(old)
            assignments = ",".join(f"{column}=?" for column in columns if column != "id")
            values = [old[column] for column in columns if column != "id"]
            conn.execute(f"UPDATE nodes SET {assignments} WHERE id=?", (*values, node_id))
            conn.commit()
        try:
            apply_runtime(sample_first=False, force=True)
        except Exception:
            pass
        raise
    with TELEMETRY_LOCK:
        RATE_STATE.pop(node_id, None)
        TELEMETRY[node_id] = _telemetry_for_row(row, time.time(), 0)
    return serial(row)


@app.delete("/api/nodes/{node_id}", status_code=204)
def delete(node_id: int, _=Depends(require_admin)):
    with STATE_LOCK, closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(404, "节点不存在")
        conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
        conn.commit()
    try:
        apply_runtime(force=True)
    except Exception:
        with closing(connect_db()) as conn:
            columns = [key for key in row.keys()]
            placeholders = ",".join("?" for _ in columns)
            conn.execute(f"INSERT INTO nodes({','.join(columns)}) VALUES({placeholders})", tuple(row[key] for key in columns))
            conn.commit()
        apply_runtime(force=True)
        raise
    with TELEMETRY_LOCK:
        TELEMETRY.pop(node_id, None)
        RATE_STATE.pop(node_id, None)
    return Response(status_code=204)


@app.get("/api/nodes/{node_id}/qr")
def qr(node_id: int, _=Depends(require_admin)):
    with closing(connect_db()) as conn:
        row = conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
    if not row:
        raise HTTPException(404, "节点不存在")
    code = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=12,
        border=4,
    )
    code.add_data(link_for(row))
    code.make(fit=True)
    image = code.make_image(fill_color="black", back_color="white")
    output = BytesIO()
    image.save(output, "PNG")
    return Response(output.getvalue(), media_type="image/png")
