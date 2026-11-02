# SmurfHunter (v3.00)

Server-side UT2004 mutator that records every player's **name history keyed by their stable CD-key ID** and answers a public whois command — the "smurf detector".

**Status**: v3.00 built, compiled, and verified on the OldUnreal Linux 64-bit engine (2026-11-01). v1 verified **live in production**; v2 sync layer E2E-verified headless with real sockets in BOTH directions (hub + spoke); v3 hub-to-hub federation E2E-verified live on the wire (16/16 checks, `Tools/sync_test_federation.py`), including the in-code peer source-IP check and the v2.02 ignore-list safety net. Zero ScriptWarnings in all runs.

**v1/v2 are fully live-verified**; v3 adds optional hub-to-hub federation on top. With no sync config, v3 behaves identically to v1.

## What it does (v1.02 — fully local, zero config)

- Detects joins, disconnects, **and renames** via a 1-second `PRIArray` diff poll (players *and* spectators).
- **Excluded by design**: bots, and engine-spawned pseudo-players such as `DemoRecSpectator` (server-side demorec) — which is a full `PlayerController` subclass with its own PRI but no human behind it — so servers running demorec by default will not log the demo spectator (one informational log line per map; nothing enters the DB). The exclusion also covers mod subclasses of `DemoRecSpectator` via `IsA`.
- Records each player's `GetPlayerIDHash()` (the engine's stable CD-key GUID hash — same ID the ban system uses) with all their aliases and a first-seen stamp to `<user dir>/System/SmurfDB.ini` (e.g. `~/.ut2004/System/SmurfDB.ini` on a Linux server — this build keeps all configs in the user-dir `System/` folder).
- Writes to disk **only when something actually changed** (new player or new alias) — never on respawn, never mid-combat.
- Answers, for any player (no admin rights needed):
  - `mutate whois <partial name>` — resolves connected players first (exact match beats partial), falls back to the stored alias DB. Ambiguous queries return a candidate list. Reply is private (console message to the requester only). The raw CD-key hash is **never** shown to players.
  - `mutate smurfstats` — current record count.
  - All other `mutate` keywords chain through untouched.

**Performance**: everything is server-side and event-driven; the poll costs microseconds once per second, the whois lookup is a sub-millisecond memory scan, and no bandwidth ever touches the game ports. Players cannot perceive any of it, by construction.

## For players (in-game quickstart)

Open the console and type any of these — **everything works in any capitalization** (`whois`, `WHOIS`, `WhoIs` are identical), and partial names are fine:

```
mutate whois <partial name>   -- all known aliases for a player (live or from history)
mutate smurfstats              -- how many players the registry has seen
```

Examples: `mutate whois bob`, `mutate WHOIS [T]Clan|Pro`, `mutate whois Bob,Jr`.

- The reply is **private** — only you see it.
- If several players match, you get a candidate list — re-run with more of the name.
- **Symbols in names are handled**: commas become spaces and stray quotes are dropped on both storage and query sides, so `Bob,Jr` and `Bob Jr` find each other. Everything else (`[ ] | { } ! @ # ...`) is stored and matched literally.
- The raw CD-key hash is never shown to players.

## Installation (any server owner)

1. Copy `SmurfHunter.u`, `SmurfHunter.ucl`, and `SmurfHunter.int` from `Compiled/System/` into the server's game-tree `System/` folder.
2. Add to the server launch URL: `?Mutator=SmurfHunter.MutSmurfHunter` — or add `SmurfHunter.MutSmurfHunter` to the `Mutators=` / mutator list in your game config, or select "SmurfHunter" in webadmin's mutator list.
3. (Optional — seed with existing player/ID history) Build a starting DB from your own CSV (`PLAYER,GAME ID` rows — format shown in `Tools/player_intialization.example.csv`) with the included converter:
   `python3 Tools/csv_to_smurfdb.py <your.csv> SmurfDB.ini`
   Then copy the generated `SmurfDB.ini` into the server's **user-dir `System/` folder** (the same folder that holds the server's `UT2004.ini`) **before the first boot** — the mutator loads it as its starting DB and merges new players into it from then on. The converter applies the same name-sanitization as the mutator, merges rows sharing a game ID into one multi-alias record, dedupes aliases case-insensitively, and flags malformed hashes. **Do not** hand-write a bare `[SmurfDB]` section or place the file outside `System/` — see the DB format notes below.
4. Done. The registry file `SmurfDB.ini` is created automatically (user-dir `System/`) on first write if you didn't seed one.

**Do NOT add `ServerPackages=SmurfHunter`** under `[Engine.GameEngine]` — and you don't need to. This is a pure server-side mutator: nothing in it replicates to or is referenced by clients (whois replies ride the standard `ClientMessage` RPC; the mutator actor never leaves the server), so clients need neither the package nor a download of it. Adding it would force every connecting client to download `SmurfHunter.u` pointlessly — and since the bundled `.u` is built for the OldUnreal engine, it could even cause version-mismatch trouble for retail-build clients. The only ini line the build process adds is `EditPackages=SmurfHunter` under `[Editor.EditorEngine]` (the compiler's source list — irrelevant to running servers).

**No `UT2004.ini` section is needed at all** — all SmurfHunter settings live in its own `SmurfHunter.ini` (sync config) and `SmurfDB.ini` (the DB), both in the user-dir `System/` folder. However, two **persistence rules** apply:
1. Add the mutator to the server's **startup URL** (`?Mutator=SmurfHunter.MutSmurfHunter`), not just via webadmin mid-session — webadmin additions do not survive restarts.
2. **If you run map voting (xVoting)**, a passed vote travels to a URL built from that game config's own mutator list, and any mutator not listed there is **unloaded**. Add "SmurfHunter" to every voting game config's Mutator list. Plain map-list rotation is unaffected (it preserves the current URL options).

**About the bundled `.u`**: it was compiled against the **OldUnreal 64-bit Linux engine build**. If you run a different engine version (e.g. retail 3369 or other platform builds), compile from source instead: copy all five `.uc` files from `Source_Code/` into `<game root>/SmurfHunter/Classes/`, add `EditPackages=SmurfHunter` under `[Editor.EditorEngine]` in your ini, and run `ucc make`. The source is the canonical deliverable.

## Files

Standard mutator export layout (see the [repo README](../README.md) for the convention):

| Path | Purpose |
|---|---|
| `Source_Code/MutSmurfHunter.uc` | Mutator: capture poll, `mutate whois`/`smurfstats`, v2 sync config + v3 federation config, hub/spoke/fed-spoke orchestration, `RelayFederated` |
| `Source_Code/SmurfDB.uc` | Persistent registry (`config(SmurfDB)` → `SmurfDB.ini`): hash-keyed records, comma-joined aliases, sanitizer, sync line parsing + validation, **v2.02 ignore lists** (filter + startup scrub) |
| `Source_Code/SmurfSpoke.uc` | Outbound TcpLink client — fleet spoke **or** v3 federation link (`AUTH … LINKTYPE HUB`, relay-on-change for peer records, 30s retry backoff) |
| `Source_Code/SmurfHubListener.uc` | Hub inbound TCP listener (binds CentralPort, spawns SmurfHubLink per connection — spokes and peers alike) |
| `Source_Code/SmurfHubLink.uc` | Per-connection hub handler: fleet-token auth, v3 peer auth (per-peer token + **source-IP check**), input validation, merge + relay with echo suppression |
| `Tools/player_intialization.example.csv` | Example seed CSV (`PLAYER,GAME ID` rows, fake data) for the converter |
| `Compiled/System/SmurfHunter.u` | Compiled package (OldUnreal Linux build — see note above) → server game-tree `System/` |
| `Compiled/System/SmurfHunter.ucl` | Auto-generated mutator registry metadata (webadmin/menu listing) → server game-tree `System/` |
| `Compiled/System/SmurfHunter.int` | Localization: friendly name + description for the mutator list → server game-tree `System/` |
| `Compiled/System/SmurfDB.example.ini` | Example registry file format (fake record + ignore-list usage) → copy to the server's user-dir `System/` as `SmurfDB.ini` only when pre-seeding; otherwise the DB auto-creates on first registration |
| `Tools/csv_to_smurfdb.py` | Reusable CSV → SmurfDB.ini converter (sanitizes like the mutator, merges shared game IDs, flags bad hashes) |
| `Tools/sync_test_hub.py` | v2 E2E test harness: fake spokes exercising a live hub (auth, sync, relay, rejection, bad-token close) |
| `Tools/sync_fake_hub.py` | v2 E2E test harness: fake hub exercising a live spoke (outbound connect, handshake, PUSH reply, delta merge) |
| `Tools/sync_test_federation.py` | **v3 E2E test harness**: fake peer hub + two fake spokes against a live hub+federate server (peer handshake, both-way reconciliation + relay, ignore filter, unknown-token close, source-IP-mismatch close) — 16/16 ALL PASS |
| `SmurfHunter_Summary.md` | Player-facing summary (Discord-shareable) — what smurfing is, how to use `mutate whois` |
| `CHANGELOG.md` | Release history (public v1.0.0 = internal build v3.00) |

## DB format (`SmurfDB.ini` — located in the user-dir `System/` folder)

```ini
[SmurfHunter.SmurfDB]
Records=(Hash="<cd-key hash>",Aliases="NameOne,NameTwo",FirstSeen="2026-11-01 14:32")
```

**Two engine-verified requirements** (learned live 2026-11-01): the section is the **package-qualified** class name `[SmurfHunter.SmurfDB]` (convention shared by `[UTCompv20.UTCompv20_BS_xPlayer]`, `[HitscanJunkie.HJClientSettings]`, etc.), and the file must sit in the user-dir `System/` next to `UT2004.ini` — a bare `[SmurfDB]` section or a file one directory high is silently ignored (the DB just starts empty).

Records key on the CD-key hash. **Aliases are an unbounded comma-joined unique list, oldest first** — a player with 30 renames simply gets one longer line (the two-name example above is illustrative, not a limit); whois output wraps automatically across messages. Stored names are **sanitized** (commas → spaces, quotes/control chars dropped) so name symbols can never corrupt the delimiter or the ini line; searching applies the same sanitization to the query, and all matching is case-insensitive. The file is human-readable/editable if you ever need to prune it.

### Ignore lists (v2.02 — the junk/poison safety net, in this same file/section)

```ini
[SmurfHunter.SmurfDB]
IgnoredHashes=<32-hex cd-key hash>
IgnoredNames=WebAdmin
```

Records whose hash is on `IgnoredHashes`, or that carry an alias on `IgnoredNames` (case-insensitive, sanitized both sides), are **rejected at `SmurfDB.Register()` — the single choke point** every merge source passes through: local capture, spoke inbound, hub inbound, and v3 federation relay. They never touch the DB, so they are never relayed either. At startup a scrub removes any already-stored matching records — this closes the union-merge resurrection hole (a remote node still holding the record cannot push it back), **without coordinated downtime**. A name match removes the whole record (ignore lists are for junk identities, not for pruning one alias). Typical use: the WebAdmin panel-monitor junk record, or a poisoned record arriving over federation. Entries are matched per-join with a log line (bulk sync blocks log a count summary instead of one line per record).

## Multi-server sync (v2 — opt-in, off by default)

All v1 behavior stays local-first. v2 adds an optional central hub so a fleet of servers converges to one shared alias DB:

- **Each server keeps its FULL local DB** — whois always reads local (instant, works during outages), registration is local-first (no data ever lost).
- **Self-seeding spokes**: a new server needs NO `SmurfDB.ini` — with `CentralHost` configured it connects empty, pulls the hub's full DB, and creates its local file automatically (verified E2E: empty spoke → 27-record hub DB → on-disk ini created with identical records and stamps, one bulk write). Only the hub needs the seeded file; every spoke that follows converges from it.
- **Hub server** (`bCentralHub=True`): listens on `CentralPort` (TCP, default **9075**). One hub per fleet (e.g. the GCP VM).
- **Spokes** (`CentralHost=<hub address>`): make **outbound-only** connections — no inbound ports or firewall changes needed on locked-down shared hosting (verified working through the exact outbound path hosted boxes already use).
- **Protocol** (line-based, `MODE_Line`): `AUTH <token>` → hub sends `PUSH` (spoke replies with its full DB) + spoke sends `SYNC` (hub replies with its full DB) → then `REG <hash>,<alias>,<stamp>` deltas (one line per alias). All merges run through the same idempotent union on the hash key — **convergence is guaranteed regardless of ordering, duplicates, or missed deltas**; a spoke that was down or mid-map-change catches up completely at its next connect. No acks, no retry queues: the local DB is the outbox.
- **Relay rule**: a REG that changes the DB is relayed to every OTHER authenticated hub link (echo suppression by sender — loops structurally impossible). Aliases recorded in LA are whois-able from NYC within network RTT.
- **Security (3 layers)**: (1) hub-side firewall allowlist of spoke IPs (yours to add in GCP), (2) shared `CentralToken` — exact-match, pre-auth traffic closes the link instantly, unauthed links close after 15s, (3) input validation on EVERY inbound record both ends: 32-hex hash format, sanitized alias (comma/quote/control chars dropped), stamp charset + length caps; malformed lines rejected and logged, never merged.
- **Outage behavior**: hub down → each server runs as an independent registry (exact v1 behavior); spokes retry every 30s and fully reconcile on reconnect. Hub restarts and map changes are covered by the same handshake.
- **Zero gameplay impact** (unchanged from v1): sync is event-driven push; zero CPU until bytes arrive; no bandwidth on the game ports; whois never waits on the network.
- **Bulk write coalescing (v2.01)**: during a `BEGIN…END` sync block the ini write is deferred and flushed **once** at `END` — a large self-seeding sync is one file write instead of one full-file rewrite per record (a mid-block disconnect also flushes safely). Normal single-record changes still write immediately, as in v1.

### Configuration (`SmurfHunter.ini` in each server's user-dir `System/` folder)

**`CentralToken` is one shared fleet secret — byte-identical on the hub and every spoke.** The spoke sends `AUTH <token>` on connect; the hub exact-match-compares it against its own `CentralToken` and closes the link instantly on mismatch.

> **IMPORTANT: no inline `;` comments in a real .ini** — Unreal's config parser takes everything after `=` as the value, so `CentralPort=9075 ; comment` would break the setting. (Also, the engine rewrites this file on config saves, so comments don't survive on a live server anyway.) The comments below are documentation only — copy values without them. Ready-to-edit examples: [`Config_Examples/SmurfHunter.HUB.example.ini`](Config_Examples/SmurfHunter.HUB.example.ini) and [`Config_Examples/SmurfHunter.SPOKE.example.ini`](Config_Examples/SmurfHunter.SPOKE.example.ini).

```ini
; hub server only:
bCentralHub=True
; spokes only - hub IP or DNS name, NO game port (sync uses CentralPort):
CentralHost=1.2.3.4
; TCP; hub needs it open inbound, spokes nothing:
CentralPort=9075
; required for any sync; share within your fleet only, identical everywhere:
CentralToken=<secret>
```

No file / empty values = pure v1 local mode, zero network activity. **v3 adds two optional keys to this same section** — `bFederate` + `FederationPeers` (hub-to-hub peering; see the federation section and [`Config_Examples/SmurfHunter.FEDERATION.example.ini`](Config_Examples/SmurfHunter.FEDERATION.example.ini)). **Do NOT add `ServerPackages=SmurfHunter`** (see install notes) — sync traffic is server-to-server and invisible to clients.

### Fleet deployment (5-server example)

0. **File ownership — read this before placing anything with `sudo` (live-fleet incident 2026-11-01)**: the engine must be able to WRITE `SmurfDB.ini` (and `SmurfHunter.ini`). If you copy them in with `sudo` (or as any user other than the one the server process runs as), the file loads fine — seed, whois, and even cross-server sync all appear to work — but **every disk write silently fails** and each restart rolls the DB back to the uploaded copy. UE2 logs nothing on config-write failure. On each box, find the daemon user (`ps aux | grep ucc`), then place files with `sudo -u <daemon-user> cp ...` or `sudo cp ...` followed by `sudo chown <daemon-user> <file>`. Read-only artifacts (`.u`/`.ucl`/`.int`) don't care about ownership. Also note: if your server runs with `-nohomedir`, the **install-tree `System/` folder is the config root** (no user-dir redirection) — that's where both ini files live.
1. **Hub (your GCP VM)**: install `.u`/`.ucl`/`.int`, seed `SmurfDB.ini` (with correct ownership), add `?Mutator=SmurfHunter.MutSmurfHunter`, create `SmurfHunter.ini` with `bCentralHub=True` + `CentralToken`. Open **TCP 9075** inbound in the GCP firewall (initially 0.0.0.0/0 + token; tighten to the 4 spoke IPs once known from the hub log).
2. **Spokes (PingPerfect etc.)**: same package + `SmurfHunter.ini` with `CentralHost=<hub IP>`, `CentralToken` same. No port changes needed. Do NOT copy a seed `SmurfDB.ini` onto spokes — they self-seed from the hub on first sync (and a wrongly-owned seed there has the same silent-write-failure problem).
3. **Verify persistence on every box before calling it deployed**: have someone join under a name/alias not yet in the DB, then confirm the ini file's mtime changed and the new record is in it. A whois working while the server is up proves nothing — whois reads the in-memory DB; only the file changing on disk proves writes work. (If a box has been running with an unwritable ini: fix ownership FIRST, then trigger one new record while it's still up — the next write flushes the ENTIRE in-memory DB, rescuing everything captured since the last successful write. Restarting before that flush loses those records.)
4. Watch the server logs: hub prints `listening on TCP 9075`, `link authenticated from <ip>`, `new record`, `rejected malformed REG`; spokes print `connected to hub`, `sync block complete`, `pushed N record(s)`, and reconnect/backoff lines.

### v2 verification (headless E2E, real sockets)

- **Hub** (`Tools/sync_test_hub.py` as two fake spokes): ALL PASS — token auth, full-DB sync (27 records / 28 alias lines), **cross-spoke relay verified on the wire**, malformed REG rejected without closing, wrong token → link closed. Server log independently confirms every step.
- **Spoke** (`Tools/sync_fake_hub.py` as a fake hub): ALL PASS — outbound connect, AUTH+SYNC, merged hub record (27→28), PUSH answered with full merged DB (28 records / 29 alias lines), live delta merged; outage → `connection lost` → 30s backoff retry, verified in the server log.
- **Self-seed scenario (v2.01, user question → proven live)**: spoke booted with NO `SmurfDB.ini` → `v2.01 active - spoke mode; DB has 0 record(s)` → connected → merged all 27 records from the fake hub → `SmurfDB.ini` auto-created on disk with identical records and `FirstSeen` stamps, pushed 27 back, merged the live delta (28 on disk). Fake hub (`sync_fake_hub.py <seed.ini> 0`): ALL PASS.
- Hub re-verified under v2.01: ALL PASS (same six checks as v2.00 — bulk path exercised on inbound pushes).
- Default local mode re-verified after cleanup: `v2.01 active - local mode, DB has 27 record(s)`, zero errors.

## Hub-to-hub federation (v3 — opt-in, off by default, wire protocol unchanged)

N operators, each with their own hub + spokes (the v2 topology is untouched), hubs syncing with each other → one logical global alias DB with no central authority and no SPOF. The v2 sync layer is already a record-level CRDT (idempotent union + full reconciliation on connect + relay-on-change-only), so **the wire protocol did not change at all** — a hub-to-hub link is the existing spoke client dialing the existing hub listener, with one new marker.

- **Config**: `bFederate=True` (master switch) + `FederationPeers=(Host="…",Port=9075,Token="…")` — one entry per peer hub, **pairwise secret per peer** (compromising the A–B relationship never exposes A–C; revoke an operator by deleting their entry). The same entry serves both directions: outbound, your hub dials the peer with `AUTH <token> LINKTYPE HUB`; inbound, the token must match one of YOUR entries AND the source IP must match that entry's `Host`.
- **In-code source-IP check (belt-and-suspenders beyond the OS firewall)**: with a **dotted-IP** Host, a stolen token alone cannot connect from a foreign machine — the link is closed with `peer token valid but source IP mismatch`. A DNS hostname cannot be checked synchronously in UE2, so it degrades to token-only auth with a logged warning — **use dotted IPs for peers**.
- **Record flow, both directions live over ONE dial**: the dialer's TCP connection is inbound to the listener, so the listener's relay travels it back the other way — only ONE side of a pair needs to dial out (if both dial, duplicates are harmless). A peer's record reaches your hub → relays down to your spokes live; your records reach the peer's spokes live. A peer hub down for a week fully catches up on reconnect (same reconciliation handshake).
- **Loops structurally impossible**: relay fires only when `Register()` reports an actual DB change, plus echo suppression by sender identity — a record cycling back to a node that already has it dies at the first already-known hop, no TTLs or route tracking needed.
- **Trust model (the real design problem — read before federating)**: (1) **poisoning propagates globally** — mitigations compose: per-peer tokens + IP allowlist practice + the v2.02 ignore filter at the Register() choke point, which blocks unwanted records from entering YOUR fleet regardless of which peer originated them; (2) **no deletion propagation** — union-merge resurrects anything held anywhere, so deletion is LOCAL policy (ignore lists + startup scrub), not a global forget command; (3) **exposure widens** — the peer operator learns your fleet's data; opt-in per peer, default off. Recommended pattern: trust-circle federation among known operators; a community-global registry only on organic demand (governance dominates).
- **Zero gameplay impact** (same as v2): a federation link is a few string compares per arrived line; full-DB reconciliation is bulk-coalesced into ONE ini write per block. At fleet scale the traffic is invisible; only at hypothetical global scale (tens of thousands of records, heavy multi-hop churn) would write throttling become worth revisiting.

Ready-to-edit example: [`Config_Examples/SmurfHunter.FEDERATION.example.ini`](Config_Examples/SmurfHunter.FEDERATION.example.ini).

### Single-server operators (no fleet of your own)

A one-server admin is a full citizen in v3 — three shapes:

1. **Hub alone** (`bCentralHub=True` + `CentralToken`, no spokes ever connect): behaves exactly like local mode plus a listener — useful as a growth-ready setup (add a second server later and it just dials in). Cost: TCP 9075 open inbound.
2. **Hub + federation peer** (`bCentralHub=True`, `bFederate=True`, `FederationPeers=[...]`): your players' records flow to the peer's fleet and theirs back — whois works globally for you. No spokes of your own needed; the listener may even start with an empty `CentralToken` as long as federation peers are configured.
3. **Outbound-only federation** (no listener at all — for locked-down hosting that can't open ports): just `bFederate=True` + `FederationPeers` pointing at the peer's hub. Your fed spoke dials out, records flow both ways over that one connection. Requires the peer to be the one listening (true whenever you pair with a proper hub).

**Two deployment facts worth knowing:**

- **Dormant peer entries are safe**: an entry pointing at a peer that isn't deployed yet just cycles dial-fail → 30s retry, with zero gameplay/DB impact and nothing blocking. Pre-configure both hubs before either is deployed — convergence starts automatically when the second end comes up.
- **Every hub lists every OTHER hub (N−1 entries, never yourself) — and mutual listing is required per pair**: even a pure-listening hub needs the peer's entry, because inbound peer auth validates the presented token against the hub's OWN `FederationPeers` (and the source-IP check uses that entry's `Host`). Dial direction is flexible (one side per pair suffices); the simplest trust-circle config is everyone lists everyone AND dials everyone. Note `CentralHost` is intentionally absent from a hub's ini — that key is the *spoke-of-my-fleet* uplink only; a hub's outbound peer connections come from `FederationPeers[i].Host`.

### v3 verification (headless E2E, real sockets — `Tools/sync_test_federation.py`, 16/16 ALL PASS)

Against a live hub+federate server (hub TCP 9075 + fake peer hub on 9076 + two fake spokes):

- **Peer handshake**: fed link sends exactly `AUTH <peerToken> LINKTYPE HUB`, then `SYNC`; full-DB reconciliation exchanged both ways (server pushed its 27-record seed; peer's records merged into the server and appeared in spoke SYNC snapshots).
- **Relay UP, on the wire**: both fake spokes' records arrived live at the fake peer hub's socket.
- **Relay DOWN, on the wire**: the peer's live delta arrived at BOTH spoke sockets as the exact REG line; no echo returned to the origin link.
- **Startup scrub**: a record on `IgnoredNames` pre-seeded into the DB was absent from the first push (server log: `DB scrub: removed 1 record(s)`).
- **Ignore filter**: an ignore-listed REG from the peer was absent from every later DB snapshot and never relayed to spokes (server log: `rejected record on the ignore list`).
- **Malformed REG**: rejected, link stayed open, record absent.
- **Unknown peer token → connection closed** (server log: `unknown federation peer - closing`).
- **Valid token + source-IP mismatch → connection closed** (server log: `peer token valid but source IP mismatch - closing`) — the in-code IP check, verified live.
- First-pass harness lesson logged: a SYNC snapshot taken in the same tick-window as an in-flight full-DB merge is legitimately incomplete (eventual consistency by design) — the harness now settles and retries; the code was never at fault.

## Roadmap

- **v3 live deployment** (only remaining step): pair with a second operator's hub — mirrored `FederationPeers` entries (dotted IPs + pairwise tokens), then deploy this v3 build to both hubs (standard stale-`.u`-first recompile procedure only matters on build boxes; servers just take the new `.u`). The v2.02 ignore lists can be populated on any box at any time (scrub runs at next map load).
- **Community-global registry** — only on organic demand; governance (moderation, fake-alias smearing, root-operator trust) dominates the technical side. Not designed beyond the v3 trust-circle model.

## Verification log (this build)

- 2026-11-01 (v1): `compile_and_verify` → SUCCESS, first pass (`ucc-bin-amd64 make`). `execute_regression_test` DM-Rankin + `?Mutator=SmurfHunter.MutSmurfHunter`, 20s window → TEST_COMPLETE, mutator active line confirmed in log, zero errors/ScriptWarnings, graceful SIGTERM shutdown. Repeated after adding `SmurfHunter.int` → clean.
- 2026-11-01 (v1 → v1.01): added the `DemoRecSpectator`/pseudo-player exclusion (user's servers run server-side demorec by default). **Build-tool incident caught and logged**: `compile_and_verify` returned a false-positive SUCCESS on the recompile — ucc make silently skipped the package because a stale `SmurfHunter.u` survived in the user-dir System folder (the engine's actual package-output dir), while the tool's stale-cleanup only clears the install System folder. The regression log's version marker (`v1` instead of `v1.01`) exposed the stale binary. Fixed by clearing the user-dir `.u` before recompile; fresh build verified live (`v1.01 active` in the regression log). Full entry + recommended tool fix in `failure_log.json` (2026-11-01).
- 2026-11-01 (v1.01 → v1.02): symbol-safe name handling — `SmurfDB.SanitizeName()` applied identically at store time and query time (commas → spaces so the alias-list delimiter can never be corrupted; quotes/control chars dropped so ini lines can never be broken; outer-trim). Whois route-1 (connected players) now compares sanitized live names, so symbol names match live and offline records identically. Command keyword + all matching were already case-insensitive (`~=` / `Caps()` everywhere) — now documented as a contract. Sanitizer edge cases validated by simulation (all pass); rebuilt via the documented stale-`.u`-first procedure; `v1.02 active` verified in the regression log. All exports in this folder are the v1.02 build.
- 2026-11-01 (**v3.00 + v2.02 built & verified**): all five classes updated (wire protocol unchanged). `rm ~/.ut2004/System/SmurfHunter.u` → `compile_and_verify` → SUCCESS after one engine-fact fix (IpAddr struct members are `Addr`/`Port`, not `ip` — logged). Local-mode regression: `v3.00 active - local mode; 'mutate whois <name>'; DB has 27 record(s)`, zero ScriptWarnings, graceful SIGTERM. **Federation E2E** (live headless hub + fake peer hub + two fake spokes, real sockets): 16/16 ALL PASS — peer handshake (`AUTH <token> LINKTYPE HUB`), both-way reconciliation, relay up/down on the wire, no echo, startup scrub, ignore-list rejection (absent from DB, never relayed), malformed rejection, unknown-peer-token close, **source-IP-mismatch close** (in-code check). Final clean regression after config restore: local mode, 27 records, zero warnings. All exports in this folder are the v3.00 build.
- 2026-11-01 (DB seeding): a 28-row `PLAYER,GAME ID` history CSV converted to a starting DB via the included `csv_to_smurfdb.py` — 27 records (one shared game ID merged into a single multi-alias record), symbol-heavy names preserved verbatim, all hashes valid 32-hex, `FirstSeen` = current timestamp in the mutator's exact `BuildStamp()` format ("YYYY-MM-DD hh:mm", zero-padded local time — so seeded values are byte-identical in shape to live-written ones and the real format is validated through load/rewrite/display; custom label possible via converter argv[3]). **Two config-system facts verified live during seeding** (initial seed silently ignored → diagnosed → fixed): config files live in `<user dir>/System/` (this build's search root — same folder as `UT2004.ini`), and the section must be package-qualified `[SmurfHunter.SmurfDB]`. Final regression run confirms: **"DB has 27 record(s)"** in the activation line. Logged to `failure_log.json` (2026-11-01).
- Live whois with a human player is pending the user's first live test (join any server running it, type `mutate whois <your name>`; your own record should show up after ~1s of the poll running — pre-seeded players should be whois-able immediately via the offline DB route).
