#!/usr/bin/env python3
"""Fail-safe source-IP device-limit enforcement for NodeLite.

A device is approximated by a distinct public source IP. Each limited node owns
one bounded nftables dynamic set per address family. Admitted addresses are
kept in the kernel and are not rebuilt during normal reconciliation. Separate
sets avoid mixed-family concat constants that older nftables releases cannot
parse.
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

DB_PATH = os.getenv("NETGUARD_DB_PATH", os.getenv("DB_PATH", "/data/panel.db"))
DB_IMMUTABLE = os.getenv("NETGUARD_DB_IMMUTABLE", "0") == "1"
LOCK_PATH = os.getenv("NETGUARD_LOCK_PATH", "/run/nodelite/netguard.lock")
TABLE_FAMILY = "inet"
TABLE = "nodelite_netguard"
CHAIN = "input"
SET_PREFIX = "devices_"
COMMENT_PREFIX = "nodelite-node-"
LEGACY_CHAIN = "NODELITE_CONN_LIMIT"
DEFAULT_DEVICE_TIMEOUT_SECONDS = 15
DEVICE_TIMEOUT_SECONDS = int(os.getenv("NETGUARD_DEVICE_TIMEOUT_SECONDS", str(DEFAULT_DEVICE_TIMEOUT_SECONDS)))
if not 1 <= DEVICE_TIMEOUT_SECONDS <= 86400:
    raise ValueError("invalid device timeout")
RULE_ROLES = (
    "ipv4-refresh", "ipv4-add", "ipv4-accept", "ipv4-reject",
    "ipv6-refresh", "ipv6-add", "ipv6-accept", "ipv6-reject",
)


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
    if DB_IMMUTABLE:
        # Native installs publish a closed, atomically replaced SQLite backup.
        # immutable avoids creating journal/WAL sidecars in netguard's
        # read-only sandbox; it is safe only for that snapshot, never the live
        # panel database.
        uri += "&immutable=1"
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


def _set_name(node_id: int, family: str) -> str:
    suffix = {"ipv4": "v4", "ipv6": "v6"}.get(family)
    if suffix is None:
        raise ValueError("invalid address family")
    return f"{SET_PREFIX}{node_id}_{suffix}"


def _parse_set_name(name: str) -> tuple[int, str | None] | None:
    """Return (node id, family); family=None identifies the legacy concat set."""
    match = re.fullmatch(rf"{re.escape(SET_PREFIX)}(\d+)(?:_(v4|v6))?", name)
    if not match:
        return None
    node_id = int(match.group(1))
    suffix = match.group(2)
    return node_id, {"v4": "ipv4", "v6": "ipv6"}.get(suffix)


def _rule_comment(node_id: int, role: str) -> str:
    return f'{COMMENT_PREFIX}{node_id}-{role}'


def render_ruleset(
    desired: list[tuple[int, int, int]],
    sources: dict[int, set[str]],
    timeout_seconds: int | None = None,
) -> str:
    """Render one atomic replacement for NodeLite's private nftables table."""
    timeout_seconds = DEVICE_TIMEOUT_SECONDS if timeout_seconds is None else timeout_seconds
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
        names = {family: _set_name(node_id, family) for family in ("ipv4", "ipv6")}
        lines.append(
            f"add set {TABLE_FAMILY} {TABLE} {names['ipv4']} "
            f"{{ type ipv4_addr; flags dynamic,timeout; "
            f"timeout {timeout_seconds}s; size {limit}; }}"
        )
        lines.append(
            f"add set {TABLE_FAMILY} {TABLE} {names['ipv6']} "
            f"{{ type ipv6_addr; flags dynamic,timeout; "
            f"timeout {timeout_seconds}s; size {limit}; }}"
        )
        raw_addresses = sources.get(port, set())
        if isinstance(raw_addresses, (list, tuple)):
            addresses = list(raw_addresses)
        else:
            addresses = sorted(
                raw_addresses,
                key=lambda value: (ipaddress.ip_address(value).version, int(ipaddress.ip_address(value))),
            )
        for family, version in (("ipv4", 4), ("ipv6", 6)):
            family_addresses = [address for address in addresses if ipaddress.ip_address(address).version == version]
            if family_addresses:
                elements = ", ".join(
                    f"{address} timeout {timeout_seconds}s" for address in family_addresses[:limit]
                )
                lines.append(f"add element {TABLE_FAMILY} {TABLE} {names[family]} {{ {elements} }}")
            key = "ip saddr" if family == "ipv4" else "ip6 saddr"
            name = names[family]
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
    # nftables JSON has emitted both a bare list and an {"elements": [...]}
    # wrapper across supported releases.
    if isinstance(parts, dict):
        parts = parts.get("elements")
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


def _element_address(value, family: str | None) -> str | None:
    """Decode current single-family elements and legacy concat elements."""
    if family is None:
        return _concat_address(value)
    candidate = value
    if isinstance(candidate, dict):
        candidate = candidate.get("prefix", candidate.get("val", candidate))
    if not isinstance(candidate, str):
        return None
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return None
    expected_version = 4 if family == "ipv4" else 6
    return str(address) if address.version == expected_version else None


def installed_sources(desired: list[tuple[int, int, int]]) -> dict[int, set[str]]:
    """Read admitted kernel-set members so config changes do not evict them."""
    by_node = {node_id: port for node_id, port, _ in desired}
    sources = {port: set() for _, port, _ in desired}
    items = _nft_json()
    for item in items:
        nft_set = item.get("set")
        if not nft_set:
            continue
        parsed = _parse_set_name(str(nft_set.get("name", "")))
        if not parsed:
            continue
        node_id, family = parsed
        port = by_node.get(node_id)
        if port is None:
            continue
        for element in nft_set.get("elem", []):
            payload = element.get("elem", element) if isinstance(element, dict) else element
            value = payload.get("val") if isinstance(payload, dict) else payload
            address = _element_address(value, family)
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
    """Check the address family, set reference and verdict of a labelled rule."""
    family, action = role.split("-", 1)
    expression = json.dumps(rule.get("expr", []), sort_keys=True, separators=(",", ":"))
    address_protocol = f'"protocol":"{"ip" if family == "ipv4" else "ip6"}"'
    synthetic_family = f'"right":"{family}"'
    # Reject rules do not carry an address expression, but all preceding
    # family-specific rules do. Their order plus exact labelled rule inventory
    # makes the paired final reject unambiguous. Synthetic test fixtures encode
    # the family as an explicit meta-nfproto comparison.
    if action != "reject" and address_protocol not in expression and synthetic_family not in expression:
        return False
    # nft JSON represents set names either as devices_N or @devices_N,
    # depending on whether it came from libnftables JSON input or parsed CLI.
    if action != "reject" and _set_name(node_id, family) not in expression:
        return False
    # Admission, membership and rejection must apply to every packet.  In
    # particular, an already-established flow can resume after its source's
    # dynamic-set timeout; accepting only ct NEW here would let it fall through
    # the chain's accept policy when capacity is occupied by another source.
    if action in {"add", "accept", "reject"} and '"ct"' in expression:
        return False
    required = {
        # Real nft JSON calls dynamic-set mutation a generic "set" expression
        # and stores the operation in op; synthetic fixtures may use the op as
        # the expression key. Accept both representations while requiring the
        # operation and final verdict.
        "refresh": ('"update"', '"return"'),
        "add": ('"add"',),
        "accept": ('"return"',),
        "reject": ('"reject"',),
    }[action]
    if action == "accept" and not (
        '"lookup"' in expression
        or '"right":"@' + _set_name(node_id, family) + '"' in expression
    ):
        return False
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
    actual_sets: dict[tuple[int, str], int] = {}
    nft_sets = [item["set"] for item in items if "set" in item]
    for nft_set in nft_sets:
        parsed = _parse_set_name(str(nft_set.get("name", "")))
        if not parsed:
            raise InstalledMismatch("unexpected nftables set")
        node_id, family = parsed
        # Legacy mixed-family concat sets are retained long enough to recover
        # their admitted members, but always trigger replacement.
        if family is None:
            raise InstalledMismatch("legacy nftables device set requires migration")
        flags = set(nft_set.get("flags", []))
        expected_type = "ipv4_addr" if family == "ipv4" else "ipv6_addr"
        if (
            nft_set.get("family") != TABLE_FAMILY
            or nft_set.get("table") != TABLE
            or nft_set.get("type") not in (expected_type, [expected_type])
            or flags != {"dynamic", "timeout"}
            or int(nft_set.get("timeout", 0)) != DEVICE_TIMEOUT_SECONDS
        ):
            raise InstalledMismatch(f"invalid nftables set for node {node_id}")
        actual_sets[(node_id, family)] = int(nft_set.get("size", 0))
    expected_sets = {
        (node_id, family): limit
        for node_id, (_port_value, limit) in expected.items()
        for family in ("ipv4", "ipv6")
    }
    if actual_sets != expected_sets:
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
        matched = re.fullmatch(rf"{re.escape(COMMENT_PREFIX)}(\d+)-(ipv4|ipv6)-(.+)", comment)
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


def _merge_sources(*mappings: dict[int, set[str]]) -> dict[int, list[str]]:
    """Merge mappings in priority order while remaining deterministic."""
    merged: dict[int, list[str]] = {}
    for mapping in mappings:
        for port, addresses in mapping.items():
            output = merged.setdefault(port, [])
            ordered = sorted(
                addresses,
                key=lambda value: (ipaddress.ip_address(value).version, int(ipaddress.ip_address(value))),
            )
            output.extend(address for address in ordered if address not in output)
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
