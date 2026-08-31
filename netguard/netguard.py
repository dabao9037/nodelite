#!/usr/bin/env python3
"""Narrow host-network enforcement adapter for NodeLite.

The container has NET_ADMIN/NET_RAW and host networking, but no Docker socket and
no host filesystem mount. Desired state is read-only from the panel SQLite DB.
Only this fixed chain can be changed.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

DB_PATH = os.getenv("DB_PATH", "/data/panel.db")
CHAIN = "NODELITE_CONN_LIMIT"
COMMENT_PREFIX = "nodelite-node-"


def run(*args: str, check: bool = True) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"command failed: {args[0]}")
    return result.stdout


def desired_rules(now: int | None = None) -> list[tuple[int, int, int]]:
    now = int(time.time()) if now is None else now
    # On a brand-new installation Compose starts netguard before the panel so
    # that the panel can require a healthy enforcement service. The panel owns
    # the database schema, therefore the database legitimately does not exist
    # during netguard's first reconciliation. Treat that state as an empty rule
    # set; the panel reconciles again immediately after creating the schema.
    if not os.path.exists(DB_PATH):
        return []
    # SQLite cannot open a WAL database directly from a read-only bind mount:
    # it needs to create/update shared-memory state. `immutable=1` opens it but
    # ignores the WAL, silently losing current limits. Copy the DB snapshot and
    # its WAL sidecars into private writable storage, then query that snapshot.
    with tempfile.TemporaryDirectory(prefix="nodelite-db-") as directory:
        snapshot = os.path.join(directory, "panel.db")
        for suffix in ("", "-wal", "-shm"):
            source = DB_PATH + suffix
            if os.path.exists(source):
                shutil.copyfile(source, snapshot + suffix)
        connection = sqlite3.connect(snapshot)
        try:
            columns = {row[1] for row in connection.execute("PRAGMA table_info(nodes)")}
            if not {"max_connections", "expires_at"}.issubset(columns):
                return []
            return [
                (int(row[0]), int(row[1]), int(row[2]))
                for row in connection.execute(
                    """SELECT id,port,max_connections FROM nodes
                       WHERE enabled=1 AND max_connections IS NOT NULL
                       AND (expires_at IS NULL OR expires_at>?) ORDER BY id""",
                    (now,),
                )
            ]
        finally:
            connection.close()


def ensure_jump():
    run("iptables", "-N", CHAIN, check=False)
    check = subprocess.run(
        ["iptables", "-C", "INPUT", "-j", CHAIN],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if check.returncode:
        run("iptables", "-I", "INPUT", "1", "-j", CHAIN)


def reconcile() -> list[dict]:
    ensure_jump()
    run("iptables", "-F", CHAIN)
    rules = []
    for node_id, port, limit in desired_rules():
        command = [
            "iptables", "-A", CHAIN, "-p", "tcp", "--syn", "--dport", str(port),
            "-m", "connlimit", "--connlimit-above", str(limit), "--connlimit-mask", "0",
            "-m", "comment", "--comment", f"{COMMENT_PREFIX}{node_id}",
            "-j", "REJECT", "--reject-with", "tcp-reset",
        ]
        run(*command)
        rules.append({"id": node_id, "port": port, "limit": limit})
    return rules


def rollback():
    run("iptables", "-F", CHAIN, check=False)
    while subprocess.run(
        ["iptables", "-C", "INPUT", "-j", CHAIN],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0:
        run("iptables", "-D", "INPUT", "-j", CHAIN)
    run("iptables", "-X", CHAIN, check=False)


def status(ports: list[int]) -> dict[str, int]:
    wanted = set(ports)
    counts = {str(port): 0 for port in ports}
    # Count ESTABLISHED TCP sockets by the local listener port. IPv4 and IPv6
    # are both covered. A single accepted client socket counts once.
    output = run("ss", "-Hnt", "state", "established")
    for line in output.splitlines():
        fields = line.split()
        # `ss -Hnt state established` normally emits recv-q/send-q/local/peer
        # (four fields), while some iproute2 builds prepend a state column.
        # Read local from -2 for the former and -3 for the latter.
        if len(fields) < 4:
            continue
        local = fields[-2] if len(fields) == 4 else fields[-3]
        match = re.search(r":(\d+)$", local)
        if match and int(match.group(1)) in wanted:
            counts[match.group(1)] += 1
    return counts


def health() -> dict[str, str]:
    # Health must fail closed. The old `rules` probe ignored iptables failures
    # and could report healthy without NET_ADMIN or without the jump installed.
    run("iptables", "-S", CHAIN)
    run("iptables", "-C", "INPUT", "-j", CHAIN)
    if os.path.exists(DB_PATH):
        desired_rules()
    return {"status": "ok"}


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
        print(run("iptables", "-S", CHAIN))
    elif command == "health":
        print(json.dumps(health(), separators=(",", ":")))
    elif command == "rollback":
        rollback()
        print("{}")
    else:
        print("usage: netguard.py reconcile|status <port...>|rules|health|rollback", file=sys.stderr)
        raise SystemExit(64)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
