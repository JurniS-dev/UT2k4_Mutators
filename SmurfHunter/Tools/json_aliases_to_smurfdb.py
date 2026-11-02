#!/usr/bin/env python3
"""json_aliases_to_smurfdb.py - merge a game-ID -> aliases JSON export into a SmurfDB.ini.

Usage:
    python3 json_aliases_to_smurfdb.py <aliases.json> <SmurfDB.ini> <output.ini> [new-record-label]

JSON format: {"<32-hex game id>": ["alias1", "alias2", ...], ...}

Merge semantics mirror the mutator's SmurfDB.Register() EXACTLY so the
merged file is indistinguishable from what the engine itself would have
converged to (and is safe against later union merges / hub sync):
  - names sanitized exactly like SmurfDB.SanitizeName():
    commas -> spaces, quotes + control chars (incl. ESC) dropped, outer
    spaces trimmed;
  - hash lookup is case-insensitive (Register uses ~= / FindHash);
  - an alias is appended to an existing record ONLY if not already in its
    alias list, case-insensitively (HasAlias ~=) - existing aliases keep
    their order (oldest first), new aliases append in JSON order;
  - FirstSeen is NEVER overwritten for existing records (first writer wins);
  - new records get FirstSeen = the label argument, defaulting to the
    CURRENT TIMESTAMP in MutSmurfHunter.BuildStamp() format
    ("YYYY-MM-DD hh:mm", zero-padded, local time) so seeded records are
    byte-identical in shape to live-written ones;
  - invalid hashes / aliases empty after sanitize / aliases > 64 chars
    (the wire validator's cap) are reported and skipped, never guessed at.

Output ini preserves the [SmurfHunter.SmurfDB] section header and any
non-Records lines (e.g. IgnoredHashes/IgnoredNames) verbatim, keeps the
existing record order, and appends new records in JSON key order. Field
order matches the PlayerRecord struct (Hash, Aliases, FirstSeen) so the
file stays diff-friendly against the engine's StaticSaveConfig rewrites.

Encoding note: the ini is read/written as latin-1 (legacy engine byte
behavior; same choice as csv_to_smurfdb.py). Aliases that cannot be
represented in latin-1 are reported and skipped - report them to the
source owner rather than mangling them.
"""
import json
import re
import sys
from datetime import datetime

HEX = set("0123456789abcdef")
REC_RE = re.compile(
    r'Records=\(Hash="([^"]*)",Aliases="([^"]*)",FirstSeen="([^"]*)"\)')


def sanitize(s: str) -> str:
    out = []
    for ch in s:
        if ch == ",":
            out.append(" ")
        elif ord(ch) >= 32 and ord(ch) != 34:
            out.append(ch)
    return ("".join(out)).strip(" ")


def valid_hash(h: str) -> bool:
    h = h.strip().lower()
    return len(h) == 32 and all(c in HEX for c in h)


def load_ini_lines(path):
    raw = open(path, "rb").read()
    for enc in ("latin-1", "utf-8"):
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            continue
    raise SystemExit(f"ERROR: cannot decode {path} as latin-1 or utf-8")


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    src_json, src_ini, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    label = sys.argv[4] if len(sys.argv) > 4 else \
        datetime.now().strftime("%Y-%m-%d %H:%M")

    data = json.load(open(src_json, encoding="utf-8"))

    ini_text, ini_enc = load_ini_lines(src_ini)
    ini_lines = ini_text.splitlines()

    # ---- parse existing records, preserving header/other lines verbatim
    records = {}          # lower(hash) -> {"aliases": [...], "firstseen": str}
    order = []            # lower(hash) in file order
    other_lines = {}      # lineno -> verbatim line (non-Records)
    header_lines = []     # leading [Section] etc. before first Records line
    saw_first_record = False
    for lineno, line in enumerate(ini_lines):
        m = REC_RE.search(line)
        if not saw_first_record and not m:
            header_lines.append((lineno, line))
            continue
        if m:
            saw_first_record = True
            h = m.group(1).lower()
            if h in records:
                print(f"  !! duplicate record for hash {h} in {src_ini} "
                      f"(line {lineno + 1}) - merged into the first one")
            else:
                records[h] = {
                    "aliases": [a for a in m.group(2).split(",") if a != ""],
                    "firstseen": m.group(3),
                }
                order.append(h)
        else:
            other_lines[lineno] = line

    stats = {
        "new_records": 0, "merged_records": 0, "aliases_added": 0,
        "aliases_known": 0, "skipped_bad_hash": 0, "skipped_alias": 0,
        "intra_key_dupes": 0,
    }
    skipped_report = []

    # ---- merge (JSON key order preserved for new records)
    for key, aliases in data.items():
        h = key.strip().lower()
        if not valid_hash(h):
            stats["skipped_bad_hash"] += 1
            skipped_report.append(f"invalid hash key {key!r} -> whole entry skipped")
            continue
        if h not in records:
            records[h] = {"aliases": [], "firstseen": label}
            order.append(h)
            stats["new_records"] += 1
        else:
            stats["merged_records"] += 1
        known = {a.lower() for a in records[h]["aliases"]}
        for raw_alias in aliases:
            name = sanitize(str(raw_alias))
            if name == "":
                stats["skipped_alias"] += 1
                skipped_report.append(f"{h[:8]}…: empty alias after sanitize -> skipped")
                continue
            if len(name) > 64:
                stats["skipped_alias"] += 1
                skipped_report.append(f"{h[:8]}…: alias {name[:20]!r}… >64 chars -> skipped")
                continue
            try:
                name.encode("latin-1")
            except UnicodeEncodeError:
                stats["skipped_alias"] += 1
                skipped_report.append(f"{h[:8]}…: alias {name!r} not latin-1 representable -> skipped")
                continue
            if name.lower() in known:
                stats["aliases_known"] += 1
                continue
            known.add(name.lower())
            records[h]["aliases"].append(name)
            stats["aliases_added"] += 1

    # ---- emit (existing record order first, then new records in JSON order)
    # header lines stay first, the record block follows, and any other
    # config lines (e.g. IgnoredHashes/IgnoredNames) are appended after it
    # in their original relative order.
    out = [line for _, line in header_lines]
    for h in order:
        r = records[h]
        out.append('Records=(Hash="%s",Aliases="%s",FirstSeen="%s")'
                   % (h, ",".join(r["aliases"]), r["firstseen"]))
    for lineno in sorted(other_lines):
        out.append(other_lines[lineno])

    with open(dst, "w", encoding="latin-1", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    print(f"OK: merged {src_json} into {dst}")
    print(f"  existing records : {len(order) - stats['new_records']}")
    print(f"  new records      : {stats['new_records']} (FirstSeen=\"{label}\")")
    print(f"  records updated  : {stats['merged_records']}")
    print(f"  aliases added    : {stats['aliases_added']}")
    print(f"  aliases known/deduped: {stats['aliases_known']}")
    print(f"  total records now: {len(order)}")
    if stats["skipped_bad_hash"] or stats["skipped_alias"]:
        print(f"  skipped          : {stats['skipped_bad_hash']} bad hash key(s), "
              f"{stats['skipped_alias']} alias(es)")
        for s in skipped_report:
            print(f"    - {s}")


if __name__ == "__main__":
    main()
