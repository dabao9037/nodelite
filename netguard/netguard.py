#!/usr/bin/env python3
"""Fail-safe source-IP device-limit enforcement for NodeLite.

A device is approximated by a distinct public source IP. Each limited node owns
one bounded nftables dynamic set shared by IPv4 and IPv6. Admitted addresses are
kept in the kernel and are not rebuilt during normal reconciliation.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

DB_PATH = os.getenv("DB_PATH", "/data/panel.db")
LOCK_PATH = os.getenv("NETGUARD_LOCK_PATH", "/run/nodelite/netguard.lock")
TABLE_FAMILY = "inet"
TABLE = "nodelite_netguard"
CHAIN = "input"
SET_PREFIX = "devices_"
COMMENT_PREFIX = "nodelite-node-"
LEGACY_CHAIN = "NODELITE_CONN_LIMIT"
DEFAULT_DEVICE_TIMEOUT_SECONDS = 15
RULE_ROLES = (
    "ipv4-refresh", "ipv4-add", "ipv4-accept", "ipv4-reject",
    "ipv6-refresh", "ipv6-add", "ipv6-accept", "ipv6-reject",
)


class TableMissing(RuntimeError):
    """The private nftables table has not been installed yet."""


class InstalledMismatch(RuntimeError):
    """The installed private table does not match the desired configuration."""


class TableMissing(RuntimeError):
    """The private nftables table has not been installed yet."""


class InstalledMismatch(RuntimeError):
    """The installed private table does not match the desired configuration."""


def run(*args: str, check: bool = True) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"command failed: {args[0]}")
    return result.stdout


@contextmanager
def operation_lock():
    directory = os.path.dirname(LOCK_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(LOCK_PATH, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def desired_rules(now: int | None = None) -> list[tuple[int, int, int]]:
    """Read one transactionally consistent desired-state snapshot.

    A missing DB is valid during first boot. Any other SQLite failure is fatal:
    callers must retain the last installed rules rather than treating an
    unreadable database as an empty configuration.
    """
    now = int(time.time()) if now is None else now
    if not os.path.exists(DB_PATH):
        return []
    uri = f"file:{os.path.abspath(DB_PATH)}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(nodes)")}
        if "expires_at" not in columns or "max_devices" not in columns:
            return []
        rows = connection.execute(
            """SELECT id,port,max_devices FROM nodes
               WHERE enabled=1 AND max_devices IS NOT NULL AND max_devices>0
               AND (expires_at IS NULL OR expires_at>?) ORDER BY id""",
            (now,),
        ).fetchall()
        return [(int(row[0]), int(row[1]), int(row[2])) for row in rows]
    finally:
        connection.close()


def _endpoints(line: str) -> tuple[str, str] | None:
    fields = line.split()
    if len(fields) < 4:
        return None
    return (fields[-2], fields[-1]) if len(fields) == 4 else (fields[-3], fields[-2])


def _port(endpoint: str) -> int | None:
    match = re.search(r":(\d+)$", endpoint)
    return int(match.group(1)) if match else None


def _host(endpoint: str) -> str | None:
    if endpoint.startswith("["):
        end = endpoint.rfind("]:")
        return endpoint[1:end] if end >= 0 else None
    host, separator, _ = endpoint.rpartition(":")
    return host if separator else None


def established_sources(ports: list[int]) -> dict[int, set[str]]:
    """Return currently ESTABLISHED unique source addresses for each port."""
    wanted = set(ports)
    sources = {port: set() for port in ports}
    if not wanted:
        return sources
    output = run("ss", "-Hnt", "state", "established")
    for line in output.splitlines():
        endpoints = _endpoints(line)
        if not endpoints:
            continue
        local, peer = endpoints
        port = _port(local)
        host = _host(peer)
        if port not in wanted or not host:
            continue
        try:
            address = ipaddress.ip_address(host.split("%", 1)[0])
        except ValueError:
            continue
        if not address.is_loopback and not address.is_unspecified:
            sources[port].add(str(address))
    return sources


def _set_name(node_id: int) -> str:
    return f"{SET_PREFIX}{node_id}"


def _nft_key(address: str) -> str:
    parsed = ipaddress.ip_address(address)
    return f"{parsed} . ::" if parsed.version == 4 else f"0.0.0.0 . {parsed}"


def _rule_comment(node_id: int, role: str) -> str:
    return f'{COMMENT_PREFIX}{node_id}-{role}'


def render_ruleset(
    desired: list[tuple[int, int, int]],
    sources: dict[int, set[str]],
    timeout_seconds: int = DEFAULT_DEVICE_TIMEOUT_SECONDS,
) -> str:
    """Render one atomic replacement for NodeLite's private nftables table."""
    if timeout_seconds < 1:
        raise ValueError("device timeout must be positive")
    lines = [
        f"delete table {TABLE_FAMILY} {TABLE}",
        f"add table {TABLE_FAMILY} {TABLE}",
        f"add chain {TABLE_FAMILY} {TABLE} {CHAIN} {{ type filter hook input priority -5; policy accept; }}",
    ]
    for node_id, port, limit in desired:
        if node_id < 1 or not 1 <= port <= 65535 or limit < 1:
            raise ValueError("invalid device-limit rule")
        name = _set_name(node_id)
        lines.append(
            f"add set {TABLE_FAMILY} {TABLE} {name} "
            f"{{ type ipv4_addr . ipv6_addr; flags dynamic,timeout; "
            f"timeout {timeout_seconds}s; size {limit}; }}"
        )
        addresses = sorted(
            sources.get(port, set()),
            key=lambda value: (ipaddress.ip_address(value).version, int(ipaddress.ip_address(value))),
        )
        if addresses:
            elements = ", ".join(
                f"{_nft_key(address)} timeout {timeout_seconds}s" for address in addresses[:limit]
            )
            lines.append(f"add element {TABLE_FAMILY} {TABLE} {name} {{ {elements} }}")
        for family, key in (("ipv4", "ip saddr . ::"), ("ipv6", "0.0.0.0 . ip6 saddr")):
            prefix = f"add rule {TABLE_FAMILY} {TABLE} {CHAIN} tcp dport {port} meta nfproto {family}"
            lines.append(
                f'{prefix} {key} @{name} update @{name} {{ {key} timeout {timeout_seconds}s }} '
                f'return comment "{_rule_comment(node_id, family + "-refresh")}"'
            )
            # Admission must run for every non-member packet, not just ct NEW.
            # An established connection may sit idle longer than the set
            # timeout; when traffic resumes it is no longer ct NEW. Limiting
            # this rule to NEW would let that flow fall through policy accept.
            lines.append(
                f'{prefix} add @{name} {{ {key} timeout {timeout_seconds}s }} '
                f'comment "{_rule_comment(node_id, family + "-add")}"'
            )
            lines.append(
                f'{prefix} {key} @{name} return '
                f'comment "{_rule_comment(node_id, family + "-accept")}"'
            )
            lines.append(
                f'{prefix} reject with tcp reset '
                f'comment "{_rule_comment(node_id, family + "-reject")}"'
            )
    return "\n".join(lines) + "\n"


def _apply_ruleset(script: str):
    with tempfile.NamedTemporaryFile("w", prefix="nodelite-nft-", suffix=".nft") as rules:
        rules.write(script)
        rules.flush()
        run("nft", "-c", "-f", rules.name)
        # nft -f is one transaction: a failed replacement leaves the previous
        # complete table in place.
        run("nft", "-f", rules.name)


def _ensure_table():
    result = subprocess.run(
        ["nft", "list", "table", TABLE_FAMILY, TABLE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        run("nft", "add", "table", TABLE_FAMILY, TABLE)


def _nft_json() -> list[dict]:
    try:
        payload = run("nft", "-j", "list", "table", TABLE_FAMILY, TABLE)
    except RuntimeError as exc:
        message = str(exc).lower()
        if "no such file or directory" in message or "does not exist" in message:
            raise TableMissing(str(exc)) from exc
        raise
    try:
        items = json.loads(payload)["nftables"]
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError("invalid nftables JSON response") from exc
    if not isinstance(items, list):
        raise RuntimeError("invalid nftables JSON response")
    return items


def _concat_address(value) -> str | None:
    if not isinstance(value, dict) or "concat" not in value:
        return None
    parts = value["concat"]
    if not isinstance(parts, list) or len(parts) != 2:
        return None
    if parts[1] == "::":
        try:
            address = ipaddress.ip_address(parts[0])
            return str(address) if address.version == 4 else None
        except ValueError:
            return None
    if parts[0] == "0.0.0.0":
        try:
            address = ipaddress.ip_address(parts[1])
            return str(address) if address.version == 6 else None
        except ValueError:
            return None
    return None


def installed_sources(desired: list[tuple[int, int, int]]) -> dict[int, set[str]]:
    """Read admitted kernel-set members so config changes do not evict them."""
    by_node = {node_id: port for node_id, port, _ in desired}
    sources = {port: set() for _, port, _ in desired}
    items = _nft_json()
    for item in items:
        nft_set = item.get("set")
        if not nft_set or not str(nft_set.get("name", "")).startswith(SET_PREFIX):
            continue
        try:
            node_id = int(nft_set["name"][len(SET_PREFIX):])
        except ValueError:
            continue
        port = by_node.get(node_id)
        if port is None:
            continue
        for element in nft_set.get("elem", []):
            payload = element.get("elem", element) if isinstance(element, dict) else {}
            address = _concat_address(payload.get("val")) if isinstance(payload, dict) else None
            if address:
                sources[port].add(address)
    return sources


def _rule_port(rule: dict) -> int | None:
    for expression in rule.get("expr", []):
        match = expression.get("match") if isinstance(expression, dict) else None
        if not match or match.get("op") != "==":
            continue
        left = match.get("left")
        if isinstance(left, dict) and left.get("payload") == {"protocol": "tcp", "field": "dport"}:
            right = match.get("right")
            return int(right) if isinstance(right, int) else None
    return None


def _rule_shape_is_valid(rule: dict, node_id: int, role: str) -> bool:
    """Check the family, set reference and verdict encoded by a labelled rule."""
    family, action = role.split("-", 1)
    expression = json.dumps(rule.get("expr", []), sort_keys=True, separators=(",", ":"))
    if family not in expression or _set_name(node_id) not in expression:
        return False
    required = {
        "refresh": ('"update"', '"return"'),
        "add": ('"add"',),
        "accept": ('"return"',),
        "reject": ('"reject"', "tcp reset"),
    }[action]
    return all(token in expression for token in required)


def validate_installed(desired: list[tuple[int, int, int]]) -> None:
    """Require the installed table to match desired nodes, limits and rules."""
    items = _nft_json()
    chains = [item["chain"] for item in items if "chain" in item]
    if len(chains) != 1:
        raise InstalledMismatch("nftables input chain is incomplete")
    chain = chains[0]
    if any(chain.get(key) != value for key, value in {
        "family": TABLE_FAMILY, "table": TABLE, "name": CHAIN,
        "type": "filter", "hook": "input", "prio": -5, "policy": "accept",
    }.items()):
        raise InstalledMismatch("nftables input chain is incomplete")

    expected = {node_id: (port, limit) for node_id, port, limit in desired}
    actual_sets: dict[int, int] = {}
    nft_sets = [item["set"] for item in items if "set" in item]
    for nft_set in nft_sets:
        if not str(nft_set.get("name", "")).startswith(SET_PREFIX):
            raise InstalledMismatch("unexpected nftables set")
        try:
            node_id = int(nft_set["name"][len(SET_PREFIX):])
        except ValueError as exc:
            raise InstalledMismatch("unexpected nftables device set") from exc
        flags = set(nft_set.get("flags", []))
        if (
            nft_set.get("family") != TABLE_FAMILY
            or nft_set.get("table") != TABLE
            or nft_set.get("type") != ["ipv4_addr", "ipv6_addr"]
            or flags != {"dynamic", "timeout"}
        ):
            raise InstalledMismatch(f"invalid nftables set for node {node_id}")
        actual_sets[node_id] = int(nft_set.get("size", 0))
    if actual_sets != {node_id: limit for node_id, (_port_value, limit) in expected.items()}:
        raise InstalledMismatch("nftables device sets do not match desired limits")

    actual_rules: dict[str, int] = {}
    for item in items:
        rule = item.get("rule")
        if not rule:
            continue
        if rule.get("family") != TABLE_FAMILY or rule.get("table") != TABLE or rule.get("chain") != CHAIN:
            raise InstalledMismatch("unexpected rule in NodeLite table")
        comment = rule.get("comment", "")
        if not comment.startswith(COMMENT_PREFIX):
            raise InstalledMismatch("unexpected unlabelled rule in NodeLite table")
        port = _rule_port(rule)
        if port is None or comment in actual_rules:
            raise InstalledMismatch("invalid or duplicate NodeLite nftables rule")
        matched = re.fullmatch(rf"{re.escape(COMMENT_PREFIX)}(\d+)-(.+)", comment)
        if not matched:
            raise InstalledMismatch("invalid NodeLite nftables rule label")
        node_id, role = int(matched.group(1)), matched.group(2)
        if node_id not in expected or role not in RULE_ROLES or not _rule_shape_is_valid(rule, node_id, role):
            raise InstalledMismatch("invalid NodeLite nftables rule expression")
        actual_rules[comment] = port
    expected_rules = {
        _rule_comment(node_id, role): port
        for node_id, (port, _limit) in expected.items()
        for role in RULE_ROLES
    }
    if actual_rules != expected_rules:
        raise InstalledMismatch("nftables rules do not match desired device limits")


def _merge_sources(*mappings: dict[int, set[str]]) -> dict[int, set[str]]:
    merged: dict[int, set[str]] = {}
    for mapping in mappings:
        for port, addresses in mapping.items():
            merged.setdefault(port, set()).update(addresses)
    return merged


def _legacy_rollback():
    """Remove rules created by versions that used iptables connlimit."""
    if not shutil.which("iptables"):
        return
    run("iptables", "-F", LEGACY_CHAIN, check=False)
    while subprocess.run(
        ["iptables", "-C", "INPUT", "-j", LEGACY_CHAIN],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        run("iptables", "-D", "INPUT", "-j", LEGACY_CHAIN)
    run("iptables", "-X", LEGACY_CHAIN, check=False)


def _reconcile_locked() -> list[dict]:
    desired = desired_rules()
    try:
        validate_installed(desired)
    except (InstalledMismatch, TableMissing) as mismatch:
        # A missing database is valid on a truly fresh install, but must never
        # turn an already configured table into an empty one if the DB mount
        # disappears temporarily.
        if not os.path.exists(DB_PATH) and not isinstance(mismatch, TableMissing):
            raise RuntimeError("database unavailable; retaining installed rules") from mismatch
        ports = [port for _, port, _ in desired]
        retained = {} if isinstance(mismatch, TableMissing) else installed_sources(desired)
        live = established_sources(ports)
        _ensure_table()
        _apply_ruleset(render_ruleset(desired, _merge_sources(retained, live)))
        validate_installed(desired)
        _legacy_rollback()
    active = established_sources([port for _, port, _ in desired])
    return [
        {
            "id": node_id,
            "port": port,
            "limit": limit,
            "max_devices": limit,
            "active_devices": len(active.get(port, set())),
        }
        for node_id, port, limit in desired
    ]


def reconcile() -> list[dict]:
    with operation_lock():
        return _reconcile_locked()


def rollback():
    """Explicit uninstall/test cleanup only; crashes must retain last rules."""
    with operation_lock():
        run("nft", "delete", "table", TABLE_FAMILY, TABLE, check=False)
        _legacy_rollback()


def status(ports: list[int]) -> dict[str, int]:
    sources = established_sources(ports)
    return {str(port): len(sources[port]) for port in ports}


def health() -> dict[str, str]:
    desired = desired_rules()
    validate_installed(desired)
    return {"status": "ok"}


def daemon(interval: float = 2.0, health_socket: str | None = None):
    """Continuously reconcile; retain last valid rules on errors and shutdown."""
    stopping = False
    listener = None
    socket_path = health_socket or os.getenv("NETGUARD_SOCKET", "")
    if socket_path:
        os.makedirs(os.path.dirname(socket_path), exist_ok=True)
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(socket_path)
        listener.listen(4)
        listener.setblocking(False)
        os.chmod(socket_path, 0o660)

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            try:
                reconcile()
            except Exception as exc:
                print(f"netguard reconcile failed; retaining previous rules: {exc}", file=sys.stderr, flush=True)
            if listener:
                try:
                    client, _ = listener.accept()
                except BlockingIOError:
                    pass
                else:
                    with client:
                        try:
                            response = health()
                        except Exception as exc:
                            response = {"status": "error", "error": str(exc)}
                        client.sendall((json.dumps(response, separators=(",", ":")) + "\n").encode())
            deadline = time.monotonic() + interval
            while not stopping and time.monotonic() < deadline:
                time.sleep(min(0.2, deadline - time.monotonic()))
    finally:
        if listener:
            listener.close()
            try:
                os.unlink(socket_path)
            except FileNotFoundError:
                pass


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "reconcile":
        print(json.dumps({"rules": reconcile()}, separators=(",", ":")))
    elif command == "status":
        ports = []
        for value in sys.argv[2:]:
            port = int(value)
            if not 1 <= port <= 65535:
                raise ValueError("invalid port")
            ports.append(port)
        print(json.dumps(status(ports), separators=(",", ":")))
    elif command == "rules":
        print(run("nft", "list", "table", TABLE_FAMILY, TABLE))
    elif command == "health":
        print(json.dumps(health(), separators=(",", ":")))
    elif command == "rollback":
        rollback()
        print("{}")
    elif command == "daemon":
        interval = float(os.getenv("NETGUARD_INTERVAL_SECONDS", "2"))
        if not 0.5 <= interval <= 300:
            raise ValueError("invalid daemon interval")
        daemon(interval)
    else:
        print("usage: netguard.py reconcile|status <port...>|rules|health|rollback|daemon", file=sys.stderr)
        raise SystemExit(64)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
