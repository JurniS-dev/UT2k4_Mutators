#!/usr/bin/env python3
"""E2E-A capture client: connects to the real v3.07 hub as a fleet spoke,
sends AUTH + SYNC, captures the full sync block to e2e_capture.txt."""
import socket, sys, time

HOST, PORT = "127.0.0.1", 9075
TOKEN = "testtoken123"
OUT = sys.argv[1] if len(sys.argv) > 1 else "e2e_capture.txt"

# wait for the hub to bind (regression boot takes ~10-20s)
deadline = time.time() + 120
while True:
    try:
        s = socket.create_connection((HOST, PORT), timeout=5)
        break
    except OSError:
        if time.time() > deadline:
            print("FATAL: hub never came up on 9075"); sys.exit(1)
        time.sleep(1.0)

buf = b""
def send(line):
    s.sendall((line + "\n").encode())
def recv_line(timeout=30):
    global buf
    s.settimeout(timeout)
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line.decode("latin-1").rstrip("\r")

send("AUTH " + TOKEN)
send("SYNC")

lines = []
pre = []
# skip anything before BEGIN (e.g. the hub's PUSH request)
while True:
    ln = recv_line()
    if ln.startswith("BEGIN"):
        lines.append(ln)
        break
    pre.append(ln)
while True:
    ln = recv_line()
    lines.append(ln)
    if ln == "END":
        break

with open(OUT, "w", encoding="latin-1") as f:
    f.write("\n".join(lines) + "\n")
print(f"pre-BEGIN lines: {pre}")
print(f"captured {len(lines)} lines ({lines[0]} .. {lines[-1]})")
n_reg = sum(1 for l in lines if l.startswith("REG "))
print(f"REG lines: {n_reg}")
s.close()
