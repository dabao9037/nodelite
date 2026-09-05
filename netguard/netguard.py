#!/usr/bin/env python3
"""Host-network source-IP device-limit enforcement for NodeLite.

Each limited node gets one bounded nftables dynamic set.  The set key is a
concatenation of IPv4 and IPv6 addresses so both families consume the same
cardinality limit (IPv4 uses ``address . ::`` and IPv6 uses
``0.0.0.0 . address``).  A source already in the set may open more TCP
connections; a new source is inserted on its first SYN and rejected when the
set is full.
"""
from __future__ import annotations

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
TABLE_FAMILY = "inet"
TABLE = "nodelite_netguard"
CHAIN = "input"
SET_PREFIX = "devices_"
COMMENT_PREFIX = "nodelite-node-"
LEGACY_CHAIN = "NODELITE_CONN_LIMIT"
DEFAULT_DEVICE_TIMEOUT_SECONDS = 15


def run(*args: str, check: bool = True) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"command failed: {args[0]}")
    return result.stdout


def desired_rules(now: int | None = None) -> list[tuple[int, int, int]]:
    now = int(time.time()) if now is None else now
    # Netguard starts before the panel on a fresh install, so a missing database
    # is a valid empty desired state.
    if not os.path.exists(DB_PATH):
        return []
    # A WAL database cannot safely be queried directly through its read-only
    # bind mount. Copy the database and sidecars to private writable storage.
    with tempfile.TemporaryDirectory(prefix="nodelite-db-") as directory:
        snapshot = os.path.join(directory, "panel.db")
        for suffix in ("", "-wal", "-shm"):
            source = DB_PATH + suffix
            if os.path.exists(source):
                shutil.copyfile(source, snapshot + suffix)
        connection = sqlite3.connect(snapshot)
        try:
            columns = {row[1] for row in connection.execute("PRAGMA table_info(nodes)")}
            if "expires_at" not in columns or not ({"max_devices", "max_connections"} & columns):
                return []
            if "max_devices" in columns and "max_connections" in columns:
                limit = "COALESCE(max_devices,max_connections)"
            elif "max_devices" in columns:
                limit = "max_devices"
            else:
                limit = "max_connections"
            return [
                (int(row[0]), int(row[1]), int(row[2]))
                for row in connection.execute(
                    f"""SELECT id,port,{limit} FROM nodes
                        WHERE enabled=1 AND {limit} IS NOT NULL
                        AND {limit}>0
                        AND (expires_at IS NULL OR expires_at>?) ORDER BY id""",
                    (now,),
                )
            ]
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


def render_ruleset(
    desired: list[tuple[int, int, int]],
    sources: dict[int, set[str]],
    timeout_seconds: int = DEFAULT_DEVICE_TIMEOUT_SECONDS,
) -> str:
    """Render an atomic replacement for NodeLite's private nftables table."""
    if timeout_seconds < 1:
        raise ValueError("device timeout must be positive")
    lines = [
        f"flush table {TABLE_FAMILY} {TABLE}",
        f"add chain {TABLE_FAMILY} {TABLE} {CHAIN} {{ type filter hook input priority -5; policy accept; }}",
    ]
    for node_id, port, limit in desired:
        if not 1 <= port <= 65535 or limit < 1:
            raise ValueError("invalid device-limit rule")
        name = _set_name(node_id)
        lines.append(
            f"add set {TABLE_FAMILY} {TABLE} {name} "
            f"{{ type ipv4_addr . ipv6_addr; flags dynamic,timeout; "
            f"timeout {timeout_seconds}s; size {limit}; }}"
        )
        # If a limit was lowered below the number already connected, seed a
        # deterministic subset. Existing excess connections are not killed;
        # they simply cannot create a new connection unless a slot is free.
        addresses = sorted(sources.get(port, set()), key=lambda value: (ipaddress.ip_address(value).version, int(ipaddress.ip_address(value))))
        if addresses:
            elements = ", ".join(
                f"{_nft_key(address)} timeout {timeout_seconds}s" for address in addresses[:limit]
            )
            lines.append(f"add element {TABLE_FAMILY} {TABLE} {name} {{ {elements} }}")
        comment = f'comment "{COMMENT_PREFIX}{node_id}"'
        for family, key in (("ipv4", "ip saddr . ::"), ("ipv6", "0.0.0.0 . ip6 saddr")):
            prefix = f"add rule {TABLE_FAMILY} {TABLE} {CHAIN} tcp dport {port} meta nfproto {family}"
            # Refresh admitted sources while they have traffic.  Unknown NEW
            # sources attempt an insertion; if size is exhausted the dynset
            # expression does not match, the membership test remains false,
            # and the following rule rejects the SYN.
            lines.append(f"{prefix} {key} @{name} update @{name} {{ {key} timeout {timeout_seconds}s }} return {comment}")
            lines.append(f"{prefix} ct state new add @{name} {{ {key} timeout {timeout_seconds}s }} {comment}")
            lines.append(f"{prefix} ct state new {key} @{name} return {comment}")
            lines.append(f"{prefix} ct state new reject with tcp reset {comment}")
    return "\n".join(lines) + "\n"


def _apply_ruleset(script: str):
    with tempfile.NamedTemporaryFile("w", prefix="nodelite-nft-", suffix=".nft") as rules:
        rules.write(script)
        rules.flush()
        # Check before applying; the second invocation is one nft transaction,
        # so readers see either the previous complete table or the new one.
        run("nft", "-c", "-f", rules.name)
        run("nft", "-f", rules.name)


def _ensure_table():
    result = subprocess.run(
        ["nft", "list", "table", TABLE_FAMILY, TABLE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        run("nft", "add", "table", TABLE_FAMILY, TABLE)


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


def reconcile() -> list[dict]:
    desired = desired_rules()
    sources = established_sources([port for _, port, _ in desired])
    _ensure_table()
    _apply_ruleset(render_ruleset(desired, sources))
    _legacy_rollback()
    return [
        {
            "id": node_id,
            "port": port,
            "limit": limit,
            "max_devices": limit,
            "active_devices": len(sources.get(port, set())),
        }
        for node_id, port, limit in desired
    ]


def rollback():
    run("nft", "delete", "table", TABLE_FAMILY, TABLE, check=False)
    _legacy_rollback()


def status(ports: list[int]) -> dict[str, int]:
    sources = established_sources(ports)
    return {str(port): len(sources[port]) for port in ports}


def health() -> dict[str, str]:
    rules = run("nft", "list", "table", TABLE_FAMILY, TABLE)
    if f"chain {CHAIN}" not in rules or "hook input" not in rules:
        raise RuntimeError("nftables input chain is incomplete")
    for node_id, port, _limit in desired_rules():
        if f"set {_set_name(node_id)}" not in rules or f"{COMMENT_PREFIX}{node_id}" not in rules:
            raise RuntimeError(f"nftables rule missing for node {node_id} port {port}")
    return {"status": "ok"}


def daemon(interval: float = 2.0, health_socket: str | None = None):
    """Continuously restore desired rules and always roll them back on exit."""
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
            reconcile()
            if listener:
                try:
                    client, _ = listener.accept()
                except BlockingIOError:
                    pass
                else:
                    with client:
                        client.sendall((json.dumps(health(), separators=(",", ":")) + "\n").encode())
            deadline = time.monotonic() + interval
            while not stopping and time.monotonic() < deadline:
                time.sleep(min(0.2, deadline - time.monotonic()))
    finally:
        rollback()
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
