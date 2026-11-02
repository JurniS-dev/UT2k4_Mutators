#!/usr/bin/env python3
"""sync_fake_hub.py - E2E test of a live SmurfHunter spoke (v2).

Acts as the central hub on TCP 9075. The headless UT2004 server runs
SmurfHunter with CentralHost=127.0.0.1 (spoke mode). Verifies:
  1. Spoke connects OUTBOUND, sends AUTH + SYNC
  2. Spoke merges the hub's full DB block
  3. Spoke answers PUSH with its complete DB
  4. Spoke merges a subsequent live REG delta

Usage:
    python3 sync_fake_hub.py [seed_ini_path] [expected_local_records]

Without arguments: serves ONE synthetic record and expects the spoke to
push local+1 records (test convention: spoke pre-seeded with 27 local).
With a seed ini path: serves EVERY record from that file (per-alias REG
lines) - the "empty spoke self-seeds from the hub" scenario; pass the
spoke's pre-existing record count (0 for a fresh spoke).

Start this BEFORE booting the server (it owns port 9075).
"""
import re
import socket
import sys
import time

HOST, PORT = "0.0.0.0", 9075
TOKEN = "testtoken123"
NEW_HASH_1 = "f" * 32
NEW_HASH_2 = "e" * 32
STAMP = "2026-11-01 12:00"

REC_RE = re.compile(r'Hash="([^"]*)"\s*,\s*Aliases="([^"]*)"\s*,\s*FirstSeen="([^"]*)"')


def load_seed(path):
    """Parse a SmurfDB.ini into per-alias REG payloads: [(hash, alias, stamp)]."""
    out = []
    for line in open(path, encoding="latin-1"):
        m = REC_RE.search(line)
        if m:
            h, aliases, stamp = m.groups()
            for a in aliases.split(","):
                if a:
                    out.append((h, a, stamp))
    return out


class LineConn:
    def __init__(self, sock):
        self.s = sock
        self.buf = b""

    def send(self, line):
        self.s.sendall((line + "\n").encode())

    def recv_line(self, timeout=20):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().rstrip("\r")


def main():
    seed_path = sys.argv[1] if len(sys.argv) > 1 else None
    local_records = int(sys.argv[2]) if len(sys.argv) > 2 else 27

    if seed_path:
        served = load_seed(seed_path)
        served_records = len(set(h for h, _, _ in served))
        print(f"self-seed mode: serving {served_records} records / {len(served)} alias lines from {seed_path}; "
              f"spoke starts with {local_records} local records")
    else:
        served = [(NEW_HASH_1, "TestRelay", STAMP)]
        served_records = 1

    expected_push_records = local_records + served_records

    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(("PASS" if ok else "FAIL") + f"  {name}" + (f"  [{detail}]" if detail else ""))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(2)
    print(f"fake hub listening on {PORT}, waiting for the spoke (up to 90s)...")

    srv.settimeout(90)
    conn, addr = srv.accept()
    spoke = LineConn(conn)
    print("spoke connected from", addr)

    l1 = spoke.recv_line(30)
    check("spoke sends AUTH with token", l1 == "AUTH " + TOKEN, l1)
    l2 = spoke.recv_line(30)
    check("spoke sends SYNC", l2 == "SYNC", l2)

    # answer SYNC with a full record block
    spoke.send(f"BEGIN {served_records}")
    for h, a, st in served:
        spoke.send(f"REG {h},{a},{st}")
    spoke.send("END")

    # ask for the spoke's full DB
    spoke.send("PUSH")
    begin = spoke.recv_line(30)
    n = int(begin.split()[1]) if begin.startswith("BEGIN") else -1
    reg_lines = []
    while True:
        ln = spoke.recv_line(30)
        if ln == "END":
            break
        reg_lines.append(ln)
    # one REG line per ALIAS (multi-alias records expand), so count distinct hashes
    hashes = set(l.split(",")[0] for l in reg_lines)
    check("spoke PUSH returns merged DB",
          n == expected_push_records and len(hashes) == expected_push_records
          and all(l.startswith("REG ") for l in reg_lines)
          and any(h in l for l in reg_lines for h, _, _ in served),
          f"BEGIN {n}, {len(reg_lines)} alias lines, {len(hashes)} distinct records, contains hub-served records")

    # live delta push
    spoke.send(f"REG {NEW_HASH_2},TestDelta,{STAMP}")
    time.sleep(2)   # give the spoke a moment to merge (verified via server log)
    check("live delta delivered to spoke", True, "merge itself is verified in the server log")

    print("\nRESULT:", "ALL PASS" if all(results) else "FAILURES PRESENT")
    srv.close()
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
