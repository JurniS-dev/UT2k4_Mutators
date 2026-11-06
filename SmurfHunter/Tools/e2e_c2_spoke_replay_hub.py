#!/usr/bin/env python3
"""E2E-B fake hub: replays the block captured from the REAL v3.07 hub
(e2e_capture.txt) to a live fresh-spoke SmurfHunter binary, then requests
PUSH and captures the spoke's merged DB push-back to e2e_pushback.txt."""
import socket, sys, time

HOST, PORT = "0.0.0.0", 9075
TOKEN = "testtoken123"
CAPTURE = sys.argv[1] if len(sys.argv) > 1 else "e2e_capture.txt"
PUSHBACK = sys.argv[2] if len(sys.argv) > 2 else "e2e_pushback.txt"

block = [l for l in open(CAPTURE, encoding="latin-1").read().split("\n") if l]

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((HOST, PORT))
srv.listen(2)
print(f"fake hub listening on {PORT} (replaying {len(block)} captured lines), waiting for spoke...", flush=True)

srv.settimeout(150)
conn, addr = srv.accept()
buf = b""
def send(line):
    conn.sendall((line + "\n").encode("latin-1"))
def recv_line(timeout=30):
    global buf
    conn.settimeout(timeout)
    while b"\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line.decode("latin-1").rstrip("\r")

l1 = recv_line(60)
print("spoke sent:", l1, flush=True)
assert l1 == "AUTH " + TOKEN, f"unexpected auth: {l1}"
l2 = recv_line(30)
print("spoke sent:", l2, flush=True)
assert l2 == "SYNC", f"unexpected second line: {l2}"

for l in block:
    send(l)
print(f"replayed {len(block)} lines (real v3.07 hub block)", flush=True)

# request the spoke's merged DB back
send("PUSH")
lines = []
while True:
    ln = recv_line(60)
    lines.append(ln)
    if ln == "END":
        break
with open(PUSHBACK, "w", encoding="latin-1") as f:
    f.write("\n".join(lines) + "\n")
print(f"captured push-back: {lines[0]}, {sum(1 for l in lines if l.startswith('REG '))} REG lines", flush=True)
conn.close()
srv.close()
print("FAKE HUB DONE", flush=True)
