#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${NODELITE_NETGUARD_E2E_IMAGE:-nodelite-netguard-nft-e2e:local}"
NAME="nodelite-netguard-nft-e2e-$$"
WORK="$(mktemp -d /tmp/nodelite-netguard-nft-e2e.XXXXXX)"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker build -t "$IMAGE" "$ROOT/netguard" >/dev/null
docker run -d --name "$NAME" --privileged \
  -v "$ROOT/netguard/netguard.py:/netguard.py:ro" \
  "$IMAGE" sleep 300 >/dev/null

cat >"$WORK/e2e.py" <<'PY'
import json
import os
import signal
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

PORT = 18080
TIMEOUT = 2
LOG = Path("/tmp/server-events.jsonl")

def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def ns(name, code, *args, check=True):
    return run("ip", "netns", "exec", name, "python3", "-c", code, *args, check=check)

def wait_for(path, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if Path(path).exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}")

for name, host, peer in (("source_a", "veth_a_host", "veth_a_peer"), ("source_b", "veth_b_host", "veth_b_peer")):
    run("ip", "netns", "add", name)
    run("ip", "link", "add", host, "type", "veth", "peer", "name", peer)
    run("ip", "link", "set", peer, "netns", name)
    suffix = "2" if name == "source_a" else "3"
    run("ip", "addr", "add", f"10.77.0.1/24", "dev", host)
    run("ip", "link", "set", host, "up")
    run("ip", "netns", "exec", name, "ip", "link", "set", "lo", "up")
    run("ip", "netns", "exec", name, "ip", "addr", "add", f"10.77.0.{suffix}/24", "dev", peer)
    run("ip", "netns", "exec", name, "ip", "link", "set", peer, "up")

# The two host veths intentionally share 10.77.0.1; each namespace has its own
# L2 segment, while packets reach the same host input hook and listening port.
db = sqlite3.connect("/tmp/panel.db")
db.execute("CREATE TABLE nodes(id INTEGER, port INTEGER, enabled INTEGER, max_connections INTEGER, max_devices INTEGER, expires_at INTEGER)")
db.execute("INSERT INTO nodes VALUES(1, ?, 1, 99, 1, NULL)", (PORT,))
db.commit(); db.close()

env = os.environ.copy()
env.update(DB_PATH="/tmp/panel.db", NETGUARD_LOCK_PATH="/tmp/netguard.lock")
reconcile = run("python3", "/netguard.py", "reconcile", check=False)
if reconcile.returncode:
    raise AssertionError(f"reconcile failed: {reconcile.stderr}")
health = run("python3", "/netguard.py", "health", check=False)
if health.returncode or json.loads(health.stdout) != {"status": "ok"}:
    raise AssertionError(f"health failed: stdout={health.stdout!r} stderr={health.stderr!r}")

# Prove the lock is cross-process, not merely an in-process convention.
holder_code = r'''
import fcntl, os, time
with open("/tmp/netguard.lock", "a+") as lock:
 fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
 open("/tmp/flock-held", "w").close()
 while not os.path.exists("/tmp/flock-release"): time.sleep(.05)
'''
holder = subprocess.Popen(["python3", "-c", holder_code])
wait_for("/tmp/flock-held")
blocked_reconcile = subprocess.Popen(["python3", "/netguard.py", "reconcile"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(0.4)
if blocked_reconcile.poll() is not None:
    raise AssertionError("reconcile did not block on cross-process flock")
Path("/tmp/flock-release").touch()
holder.wait(timeout=3)
stdout, stderr = blocked_reconcile.communicate(timeout=3)
if blocked_reconcile.returncode:
    raise AssertionError(f"locked reconcile failed after release: {stderr.decode()}")

# A reconcile failure inside the daemon and a normal SIGTERM must both retain
# the last installed table. This exercises real nftables state, not a mock.
bad_env = os.environ.copy(); bad_env["DB_PATH"] = "/tmp/missing-panel.db"
daemon = subprocess.Popen(["python3", "/netguard.py", "daemon"], env=bad_env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(0.8)
daemon.terminate(); _, daemon_stderr = daemon.communicate(timeout=3)
if b"retaining previous rules" not in daemon_stderr:
    raise AssertionError(f"daemon failure path was not exercised: {daemon_stderr!r}")
retained = run("nft", "list", "table", "inet", "nodelite_netguard", check=False)
if retained.returncode:
    raise AssertionError("daemon failure/stop rolled back installed nftables table")

server_code = r'''
import json, socket, threading
log = open("/tmp/server-events.jsonl", "a", buffering=1)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 18080)); s.listen()
open("/tmp/server-ready", "w").close()
def worker(c, address):
    log.write(json.dumps({"event":"accept", "source":address[0]})+"\n")
    try:
        while True:
            data=c.recv(1024)
            if not data: break
            log.write(json.dumps({"event":"data", "source":address[0], "data":data.decode()})+"\n")
            c.sendall(data)
    except Exception as exc:
        log.write(json.dumps({"event":"error", "source":address[0], "error":type(exc).__name__})+"\n")
    finally: c.close()
while True:
    c,a=s.accept(); threading.Thread(target=worker,args=(c,a),daemon=True).start()
'''
server = subprocess.Popen(["python3", "-c", server_code])
try:
    wait_for("/tmp/server-ready")
    a_code = r'''
import socket, time
s=socket.create_connection(("10.77.0.1",18080),2); s.settimeout(2)
s.sendall(b"A-first"); assert s.recv(64)==b"A-first"
open("/tmp/a-admitted","w").close()
while not __import__('os').path.exists("/tmp/a-resume"): time.sleep(.05)
try:
 s.sendall(b"A-after-timeout"); data=s.recv(64)
 open("/tmp/a-result","w").write("unexpected-pass:"+data.decode())
except Exception as e:
 open("/tmp/a-result","w").write("blocked:"+type(e).__name__)
time.sleep(.2)
'''
    a = subprocess.Popen(["ip", "netns", "exec", "source_a", "python3", "-c", a_code])
    wait_for("/tmp/a-admitted")
    # Membership timeout is refreshed by A's first data packet, so measure the
    # release window from the last observed A payload rather than connect time.
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if LOG.exists() and "A-first" in LOG.read_text():
            break
        time.sleep(0.05)
    else:
        raise AssertionError("server did not receive A-first")

    b_probe = ns("source_b", r'''
import socket, struct
s=socket.socket(); s.settimeout(1); s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii',1,0)); s.bind(("10.77.0.3",41001))
try:
 s.connect(("10.77.0.1",18080)); s.sendall(b"B-too-early"); print("unexpected-pass")
except Exception as e: print("blocked:"+type(e).__name__)
finally: s.close()
''', check=False)
    if "blocked:" not in b_probe.stdout:
        raise AssertionError(f"source B was not refused at capacity: {b_probe.stdout!r} {b_probe.stderr!r}")
    # Remove the refused probe's conntrack entry. The packet-level policy is
    # what is under test; retaining an old rejected TCP tuple can otherwise
    # obscure the later, deliberately fresh admission attempt in some kernels.
    subprocess.run(["conntrack", "-D", "-s", "10.77.0.3", "-d", "10.77.0.1", "-p", "tcp", "--dport", str(PORT)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    time.sleep(TIMEOUT + 1.5)
    snapshot_before_b = run("nft", "list", "set", "inet", "nodelite_netguard", "devices_1_v4").stdout
    if "10.77.0.2" in snapshot_before_b:
        raise AssertionError(f"source A did not expire from dynamic set: {snapshot_before_b}")
    # Use a new namespace/address for the post-timeout occupant. This proves a
    # distinct source can claim the released slot without depending on the
    # rejected probe's host/conntrack cache behavior.
    run("ip", "netns", "add", "source_c")
    run("ip", "link", "add", "veth_c_host", "type", "veth", "peer", "name", "veth_c_peer")
    run("ip", "link", "set", "veth_c_peer", "netns", "source_c")
    run("ip", "addr", "add", "10.78.0.1/24", "dev", "veth_c_host")
    run("ip", "link", "set", "veth_c_host", "up")
    run("ip", "netns", "exec", "source_c", "ip", "link", "set", "lo", "up")
    run("ip", "netns", "exec", "source_c", "ip", "addr", "add", "10.78.0.3/24", "dev", "veth_c_peer")
    run("ip", "netns", "exec", "source_c", "ip", "link", "set", "veth_c_peer", "up")
    b_code = r'''
import socket, time, traceback
try:
 s=socket.socket(); s.settimeout(2); s.bind(("10.78.0.3",41002)); s.connect(("10.78.0.1",18080))
 open("/tmp/b-connected","w").close()
 s.sendall(b"B-after-timeout"); data=s.recv(64)
 open("/tmp/b-result","w").write(repr(data))
 assert data==b"B-after-timeout"
 open("/tmp/b-admitted","w").close(); time.sleep(3)
except Exception:
 open("/tmp/b-error","w").write(traceback.format_exc()); raise
'''
    b = subprocess.Popen(["ip", "netns", "exec", "source_c", "python3", "-c", b_code])
    try:
        wait_for("/tmp/b-admitted")
    except AssertionError as exc:
        error = Path("/tmp/b-error").read_text() if Path("/tmp/b-error").exists() else "no child error"
        connected = Path("/tmp/b-connected").exists()
        result_b = Path("/tmp/b-result").read_text() if Path("/tmp/b-result").exists() else "no result"
        events_now = LOG.read_text() if LOG.exists() else "no events"
        rules = run("nft", "list", "table", "inet", "nodelite_netguard").stdout
        raise AssertionError(f"{exc}; before_b={snapshot_before_b!r}; connected={connected}; result_b={result_b!r}; child={error!r}; events={events_now!r}; rules={rules!r}") from exc
    Path("/tmp/a-resume").touch()
    wait_for("/tmp/a-result")
    a.wait(timeout=5); b.wait(timeout=5)
    result = Path("/tmp/a-result").read_text()
    if not result.startswith("blocked:"):
        raise AssertionError(f"old established A flow bypassed enforcement: {result}")
    events = [json.loads(line) for line in LOG.read_text().splitlines()]
    if any(e.get("data") == "B-too-early" for e in events):
        raise AssertionError("server received source B while source A occupied the only slot")
    if not any(e.get("data") == "B-after-timeout" for e in events):
        raise AssertionError("source B did not occupy the released slot")
    if any(e.get("data") == "A-after-timeout" for e in events):
        raise AssertionError("server received resumed data from expired source A")
    members = run("nft", "-j", "list", "set", "inet", "nodelite_netguard", "devices_1_v4").stdout
    print(json.dumps({
        "initial_a": "admitted_and_echoed",
        "initial_b": b_probe.stdout.strip(),
        "after_timeout_b": "admitted_and_echoed",
        "resumed_old_a": result,
        "server_saw_resumed_old_a": False,
        "health": json.loads(health.stdout),
        "flock": "second_process_blocked_then_completed",
        "daemon_failure_and_sigterm": "installed_table_retained",
        "set_snapshot": json.loads(members),
    }, separators=(",", ":")))
finally:
    server.send_signal(signal.SIGTERM)
    try: server.wait(timeout=2)
    except subprocess.TimeoutExpired: server.kill()
PY

docker cp "$WORK/e2e.py" "$NAME:/e2e.py"
docker exec \
  -e DB_PATH=/tmp/panel.db \
  -e NETGUARD_LOCK_PATH=/tmp/netguard.lock \
  -e NETGUARD_DEVICE_TIMEOUT_SECONDS=2 \
  "$NAME" python3 /e2e.py
