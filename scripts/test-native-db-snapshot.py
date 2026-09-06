#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import sqlite3
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as raw:
    work = Path(raw)
    live = work / "live" / "panel.db"
    snapshot = work / "state" / "netguard.db"
    live.parent.mkdir()
    snapshot.parent.mkdir()

    writer = sqlite3.connect(live)
    writer.execute("PRAGMA journal_mode=WAL")
    writer.execute("CREATE TABLE nodes (id INTEGER, port INTEGER, max_devices INTEGER, enabled INTEGER, expires_at INTEGER)")
    writer.execute("INSERT INTO nodes VALUES (1, 30001, 2, 1, NULL)")
    writer.commit()

    # Exercise the production backup algorithm while a WAL writer remains open.
    temporary = snapshot.with_name(".netguard.db.tmp")
    with sqlite3.connect(live, timeout=15) as source, sqlite3.connect(temporary) as target:
        source.backup(target)
    os.chmod(temporary, 0o640)
    os.replace(temporary, snapshot)
    writer.close()

    snapshot.parent.chmod(0o555)
    os.environ["NETGUARD_DB_PATH"] = str(snapshot)
    os.environ["NETGUARD_DB_IMMUTABLE"] = "1"
    spec = importlib.util.spec_from_file_location("netguard_snapshot_test", root / "netguard" / "netguard.py")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    assert guard.desired_rules(now=100) == [(1, 30001, 2)]
    assert not Path(f"{snapshot}-wal").exists()
    assert not Path(f"{snapshot}-shm").exists()
    assert snapshot.stat().st_mode & 0o777 == 0o640

print("NATIVE_DB_SNAPSHOT_OK")
