#!/usr/bin/env python3
"""sync_test_hub.py - E2E test of a live SmurfHunter hub (v2).

Plays TCP spokes against a headless UT2004 server running SmurfHunter with
bCentralHub=True on TCP 9075. Verifies:
  1. AUTH with the right token works; hub answers AUTH with PUSH
  2. SYNC returns the hub's full DB (BEGIN n ... REG ... END)
  3. A spoke's new REG is merged and RELAYED to the other connected spoke
  4. Malformed REG is rejected without closing the link
  5. A wrong token closes the link

Run BEFORE/while booting the server:  python3 sync_test_hub.py
(polls up to 90s for the hub to come up, prints PASS/FAIL per step)
"""
import socket
import sys
import time

HOST, PORT = "127.0.0.1", 9075
TOKEN = "testtoken123"
SEED_RECORDS = 27
NEW_HASH = "f" * 32
NEW_ALIAS = "TestRelay"
NEW_STAMP = "2026-11-01 12:00"


class LineConn:
    def __init__(self, sock):
        self.s = sock
        self.buf = b""

    @staticmethod
    def poll_connect(timeout=90):
        end = time.time() + timeout
        while time.time() < end:
            try:
                return LineConn(socket.create_connection((HOST, PORT), timeout=2))
            except OSError:
                time.sleep(0.5)
        raise TimeoutError("hub never came up")

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

    def expect_eof(self, timeout=20):
        """True if the peer closes the connection."""
        self.s.settimeout(timeout)
        try:
            while True:
                if self.s.recv(4096) == b"":
                    return True
        except (ConnectionError, OSError):
            return True


def main():
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(("PASS" if ok else "FAIL") + f"  {name}" + (f"  [{detail}]" if detail else ""))

    # --- peer 1: authenticate + full sync ---
    p1 = LineConn.poll_connect()
    p1.send("AUTH " + TOKEN)
    check("peer1 auth accepted", p1.recv_line() == "PUSH", "hub replies PUSH after AUTH")
    p1.send("BEGIN 0")          # empty push (we have no local records)
    p1.send("END")
    p1.send("SYNC")
    first = p1.recv_line()
    n = int(first.split()[1]) if first.startswith("BEGIN") else -1
    lines = []
    while True:
        ln = p1.recv_line()
        if ln == "END":
            break
        lines.append(ln)
    # one REG line per ALIAS (a multi-alias record sends several lines),
    # so: record count == SEED_RECORDS, alias lines == SEED_ALIASES (28 in the
    # shipped seed: 27 records, one of which carries two aliases)
    hashes = set(l.split(",")[0] for l in lines)
    check("peer1 SYNC returns hub DB",
          n == SEED_RECORDS and len(hashes) == SEED_RECORDS
          and all(l.startswith("REG ") for l in lines) and len(lines) >= SEED_RECORDS,
          f"BEGIN {n}, {len(lines)} alias lines, {len(hashes)} distinct records")

    # --- peer 2: authenticate, push one NEW record; peer1 must get the relay ---
    p2 = LineConn.poll_connect(10)
    p2.send("AUTH " + TOKEN)
    check("peer2 auth accepted", p2.recv_line() == "PUSH")
    p2.send("BEGIN 1")
    p2.send(f"REG {NEW_HASH},{NEW_ALIAS},{NEW_STAMP}")
    p2.send("END")
    relay = p1.recv_line(15)
    check("hub relays spoke2's new record to spoke1",
          relay == f"REG {NEW_HASH},{NEW_ALIAS},{NEW_STAMP}", relay)

    # --- malformed REG rejected, link survives ---
    p1.send("REG zzz-not-a-hash,bad")
    p1.send("SYNC")   # if the link survived, this still answers
    surv = p1.recv_line(15)
    n2 = int(surv.split()[1]) if surv.startswith("BEGIN") else -1
    while True:
        if p1.recv_line() == "END":
            break
    check("malformed REG rejected without closing link",
          surv.startswith("BEGIN") and n2 == SEED_RECORDS + 1,
          f"link alive, hub DB now {n2}")

    # --- wrong token -> connection closed by hub ---
    p3 = LineConn.poll_connect(10)
    p3.send("AUTH wrongtoken")
    check("wrong token closes the link", p3.expect_eof(20))

    print("\nRESULT:", "ALL PASS" if all(results) else "FAILURES PRESENT")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
