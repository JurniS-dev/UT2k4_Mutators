#!/usr/bin/env python3
"""sync_test_federation.py - E2E test of SmurfHunter v3 hub-to-hub federation.

Topology under test (all real sockets, one headless UT2004 server):
  - real server = hub on TCP 9075 (fleet token 'fleettoken123')
  - fake PEER HUB listens on 9076 ('peertoken456'); the server's fed spoke
    dials it with "AUTH peertoken456 LINKTYPE HUB"
  - two fake SPOKES dial the real hub on 9075 like ordinary fleet spokes
  - a second FederationPeers entry (Host=192.0.2.99, token 'ipcheck789')
    exercises the in-code source-IP check: a connection presenting that
    token from 127.0.0.1 must be closed.

Verifies (on the wire):
  1. fed spoke handshake is exactly "AUTH peertoken456 LINKTYPE HUB"
  2. startup scrub: ignore-listed 'JunkRecord' absent from the server's DB
  3. reconciliation both ways (full-DB blocks exchanged and merged)
  4. spoke records relay UP to the peer hub live
  5. peer delta relayed DOWN to both spokes live, no echo back to origin
  6. malformed REG rejected without closing the link
  7. ignore-listed REG rejected (absent from DB, never relayed)
  8. unknown peer token -> closed
  9. valid token but source-IP mismatch -> closed

Start this BEFORE booting the server (it owns port 9076; the server owns 9075).
Prints PASS/FAIL per check; writes 'fed_test_results.txt' when done.
"""
import re
import socket
import sys
import time

PEER_PORT = 9076            # we (fake peer hub) listen here
HUB_PORT = 9075             # real server listens here
FLEET_TOKEN = "fleettoken123"
PEER_TOKEN = "peertoken456"
IPCHECK_TOKEN = "ipcheck789"
STAMP = "2026-11-01 12:00"

H_PEER1 = "a" * 32   # peer DB record 1
H_PEER2 = "b" * 32   # peer DB record 2
H_LIVE = "c" * 32    # peer live delta
H_IGN = "d" * 32     # ignore-listed alias record
H_SPOKE1 = "e" * 32  # fake spoke 1 record
H_SPOKE2 = "f" * 32  # fake spoke 2 record

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f"  [{detail}]" if detail else ""), flush=True)


class LineConn:
    def __init__(self, sock):
        self.s = sock
        self.buf = b""

    def send(self, line):
        self.s.sendall((line + "\n").encode())

    def recv_line(self, timeout=30):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().rstrip("\r")

    def try_recv_line(self, timeout=3):
        """Non-fatal read: returns a line or None on timeout/close."""
        try:
            return self.recv_line(timeout)
        except (socket.timeout, ConnectionError, OSError):
            return None

    def recv_block(self, timeout=30):
        """Collects lines of a BEGIN..END block; returns (begin_line, payload_lines)."""
        first = self.recv_line(timeout)
        while not first.startswith("BEGIN"):
            first = self.recv_line(timeout)  # skip any leading noise
        lines = []
        while True:
            ln = self.recv_line(timeout)
            if ln == "END":
                break
            lines.append(ln)
        return first, lines


def wait_closed(conn, timeout=8):
    """True if the socket closes within timeout (server side rejecting us)."""
    try:
        conn.s.settimeout(timeout)
        while True:
            chunk = conn.s.recv(4096)
            if not chunk:
                return True
    except socket.timeout:
        return False
    except ConnectionError:
        return True
    except OSError:
        return True


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PEER_PORT))
    srv.listen(2)
    print(f"fake peer hub listening on {PEER_PORT}, waiting for the server's fed spoke (up to 150s)...", flush=True)

    srv.settimeout(150)
    conn, addr = srv.accept()
    fed = LineConn(conn)
    print("fed spoke connected from", addr, flush=True)

    # ---- 1. federation handshake ----
    l1 = fed.recv_line(60)
    check("1. fed spoke handshake is AUTH <peerToken> LINKTYPE HUB",
          l1 == f"AUTH {PEER_TOKEN} LINKTYPE HUB", l1)
    l2 = fed.recv_line(60)
    check("1b. fed spoke requests our DB (SYNC)", l2 == "SYNC", l2)

    # ---- 2. reconciliation: ask for the server's DB ----
    fed.send("PUSH")
    begin, server_db = fed.recv_block(60)
    joined = "\n".join(server_db)
    check("2. startup scrub removed ignore-listed 'JunkRecord' (absent from server DB push)",
          "JunkRecord" not in joined)
    check("2b. seed DB pushed to the peer hub (BEGIN block received)",
          begin.startswith("BEGIN") and len(server_db) >= 27, f"{len(server_db)} REG lines")

    # hand the server OUR full DB block (reconciliation, our side)
    fed.send(f"BEGIN 2")
    fed.send(f"REG {H_PEER1},PeerOne,{STAMP}")
    fed.send(f"REG {H_PEER2},PeerTwo,{STAMP}")
    fed.send("END")

    # give the fed spoke a few engine ticks to merge our block before the
    # spokes dial in (reconciliation is eventual; a SYNC snapshot taken
    # mid-merge is legitimately incomplete - that is the protocol working)
    time.sleep(5)

    # ---- 3. two fake spokes dial the real hub like fleet members ----
    spokes = []
    for i, (hash_, alias) in enumerate([(H_SPOKE1, "SpokeOne"), (H_SPOKE2, "SpokeTwo")]):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", HUB_PORT))
        sc = LineConn(s)
        sc.send(f"AUTH {FLEET_TOKEN}")
        sc.send("SYNC")
        push_req = sc.recv_line(30)
        check(f"3. spoke {i+1} authenticated (hub sent PUSH request)", push_req == "PUSH", push_req)
        sc.send("BEGIN 1")
        sc.send(f"REG {hash_},{alias},{STAMP}")
        sc.send("END")
        begin, hub_db = sc.recv_block(30)
        joined_hub = "\n".join(hub_db)
        # eventual consistency: retry one SYNC round if the snapshot raced the merge
        if not ("PeerOne" in joined_hub and "PeerTwo" in joined_hub):
            time.sleep(2)
            sc.send("SYNC")
            begin, hub_db = sc.recv_block(30)
            joined_hub = "\n".join(hub_db)
        check(f"3b. spoke {i+1} got hub full DB incl. peer records (reconciliation down-leg)",
              "PeerOne" in joined_hub and "PeerTwo" in joined_hub,
              f"{len(hub_db)} REG lines")
        spokes.append(sc)

    # ---- 4. relay UP: the peer hub must have seen both spoke records live ----
    up_lines = []
    deadline = time.time() + 10
    while time.time() < deadline and len(up_lines) < 2:
        ln = fed.try_recv_line(2)
        if ln:
            up_lines.append(ln)
    check("4. spoke records relayed UP to the peer hub live (on the wire)",
          any("SpokeOne" in l for l in up_lines) and any("SpokeTwo" in l for l in up_lines),
          f"{len(up_lines)} lines: {[l[:40] for l in up_lines]}")

    # ---- 5. relay DOWN: peer live delta reaches both spokes, no echo back ----
    fed.send(f"REG {H_LIVE},PeerLive,{STAMP}")
    got = []
    for sc in spokes:
        deadline = time.time() + 10
        hit = None
        while time.time() < deadline:
            ln = sc.try_recv_line(2)
            if ln and H_LIVE in ln:
                hit = ln
                break
        got.append(hit)
    check("5. peer live delta relayed DOWN to BOTH spokes (on the wire)",
          all(g == f"REG {H_LIVE},PeerLive,{STAMP}" for g in got), str(got))
    echo = fed.try_recv_line(4)
    check("5b. no echo back to the origin link (peer did not receive its own record)",
          echo is None or H_LIVE not in echo, str(echo))

    # ---- 6. malformed REG: rejected, link stays open ----
    fed.send("REG nothexatall,Foo," + STAMP)
    time.sleep(1)
    fed.send("PUSH")
    begin, db_after = fed.recv_block(30)
    check("6. malformed REG rejected, link still open, record absent",
          "Foo" not in "\n".join(db_after))

    # ---- 7. ignore-listed REG: rejected everywhere ----
    fed.send(f"REG {H_IGN},JunkBot,{STAMP}")
    time.sleep(1)
    fed.send("PUSH")
    begin, db_ign = fed.recv_block(30)
    check("7. ignore-listed 'JunkBot' absent from the server DB",
          "JunkBot" not in "\n".join(db_ign))
    junk_relayed = False
    for sc in spokes:
        deadline = time.time() + 4
        while time.time() < deadline:
            ln = sc.try_recv_line(1)
            if ln and "JunkBot" in ln:
                junk_relayed = True
                break
    check("7b. ignore-listed record never relayed to spokes", not junk_relayed)

    # ---- 8. unknown peer token -> closed ----
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", HUB_PORT))
    bad = LineConn(s)
    bad.send("AUTH wrongtoken999 LINKTYPE HUB")
    check("8. unknown peer token -> connection closed", wait_closed(bad))

    # ---- 9. valid token but source-IP mismatch (Host=192.0.2.99) -> closed ----
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", HUB_PORT))
    ipm = LineConn(s)
    ipm.send(f"AUTH {IPCHECK_TOKEN} LINKTYPE HUB")
    check("9. valid token + source-IP mismatch -> connection closed", wait_closed(ipm))

    srv.close()
    n_total = len(results)
    print(f"\nRESULT: {'ALL PASS' if all(results) else 'FAILURES PRESENT'} "
          f"({sum(results)}/{n_total})", flush=True)
    with open("fed_test_results.txt", "w") as f:
        f.write(f"{'ALL PASS' if all(results) else 'FAILURES PRESENT'} "
                f"{sum(results)}/{n_total}\n")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
