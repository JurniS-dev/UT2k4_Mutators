#!/usr/bin/env python3
"""csv_to_smurfdb.py - convert a PLAYER,GAME ID csv into a SmurfDB.ini seed file.

Usage:
    python3 csv_to_smurfdb.py <input.csv> <output.ini> [imported-label]

CSV format: header line 'PLAYER,GAME ID', then 'name,hash' rows.
- Names are sanitized exactly like the mutator's SmurfDB.SanitizeName():
  commas -> spaces, quotes/control chars dropped, outer spaces trimmed.
- Rows sharing a GAME ID merge into ONE record with multiple aliases
  (first occurrence = oldest), case-insensitive alias dedupe.
- FirstSeen defaults to the CURRENT TIMESTAMP in the exact format the
  mutator's BuildStamp() writes at registration time ("YYYY-MM-DD hh:mm",
  zero-padded, local time) so seeded records are byte-identical in shape to
  live-written ones — this intentionally exercises the real value format
  through config load, StaticSaveConfig rewrite, and whois display.
  Pass a custom label as argv[3] to override (e.g. "before 2026-11-01").
- Duplicate/odd hash rows are reported, not silently dropped.
Output ini is written with the same field order as the struct
(Hash, Aliases, FirstSeen) so it stays diff-friendly against the
engine's own StaticSaveConfig rewrites.

IMPORTANT (verified live 2026-11-01 against this engine build):
  - the engine expects the file at <user dir>/System/SmurfDB.ini
    (e.g. ~/.ut2004/System/SmurfDB.ini), NOT directly in the user dir;
  - the section is the PACKAGE-QUALIFIED class name
    [SmurfHunter.SmurfDB] (convention confirmed from UTCompv20.ini /
    HitscanJunkie.ini sections: [Pkg.Class], not bare [Class]).
"""
import sys
from datetime import datetime


def sanitize(s: str) -> str:
    out = []
    for ch in s:
        if ch == ",":
            out.append(" ")
        elif ord(ch) >= 32 and ord(ch) != 34:
            out.append(ch)
    return ("".join(out)).strip(" ")


def load_rows(path):
    raw = open(path, "rb").read()
    for enc in ("utf-8", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    rows = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.upper().startswith("PLAYER"):  # header
            continue
        parts = line.split(",", 1)
        if len(parts) != 2:
            print(f"  !! line {lineno}: not 'name,hash' -> skipped: {line!r}")
            continue
        rows.append((lineno, sanitize(parts[0]), parts[1].strip().lower()))
    return rows


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    # same format as MutSmurfHunter.BuildStamp(): YYYY-MM-DD hh:mm, zero-padded, local time
    label = sys.argv[3] if len(sys.argv) > 3 else datetime.now().strftime("%Y-%m-%d %H:%M")

    rows = load_rows(src)
    records = {}   # hash -> [aliases] (insertion order = oldest first)
    order = []
    bad_hash = []
    for lineno, name, gid in rows:
        if name == "":
            print(f"  !! line {lineno}: empty name -> skipped")
            continue
        if len(gid) != 32 or any(c not in "0123456789abcdef" for c in gid):
            bad_hash.append((lineno, name, gid))
        if gid not in records:
            records[gid] = []
            order.append(gid)
        # case-insensitive alias dedupe (matches the mutator's ~= comparison)
        if not any(a.lower() == name.lower() for a in records[gid]):
            records[gid].append(name)

    with open(dst, "w", encoding="latin-1", newline="\n") as f:
        f.write("[SmurfHunter.SmurfDB]\n")
        for gid in order:
            f.write('Records=(Hash="%s",Aliases="%s",FirstSeen="%s")\n'
                    % (gid, ",".join(records[gid]), label))

    merged = len(rows) - len(order)
    print(f"OK: {len(rows)} csv rows -> {len(order)} records "
          f"({merged} merged by shared game id), written to {dst}")
    for lineno, name, gid in bad_hash:
        print(f"  !! WARNING line {lineno}: name {name!r} has non-32-hex game id {gid!r} "
              f"(kept, but the engine hash format is 32 hex chars - verify)")


if __name__ == "__main__":
    main()
