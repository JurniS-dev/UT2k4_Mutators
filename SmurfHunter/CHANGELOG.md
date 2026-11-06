# Changelog - SmurfHunter

## v1.4.3 (2026-11-06)
Corresponds to internal build v3.07.

- **Main identity on the wire (sync fix, hub-side only)** — before this build, a node that received a record over sync invented its own Main: the wire carried only per-alias `REG` lines, so a fresh spoke seeded `Main = first alias received` (a player curated as `Main: BlazerOne` showed up on a fresh spoke as `Main: blazer`), and records whose alias list was empty but Main was set had **no wire representation at all** — they never left the hub (a fresh spoke synced 63 of 253 records in the production fleet). The hub's full-sync block now leads **every** record with an ordinary `REG <hash>,<Main>,<stamp>` line, emitted before that record's alias lines — so the receiving node creates the record with the **curated Main** and every record propagates, including alias-less Main-only rows. No data repair needed; receivers dedup a Main spelling that also rides the alias list via the case-insensitive `HasAlias` key (never stored twice, never displayed).
- **Zero spoke-side changes, fully wire-compatible** — the new line is an ordinary `REG` line accepted and deduped by every v3.02+ binary; mixed fleets work in any order. Roll the `.u` to the **hub first** for the effect; spokes can update at any pace. Push-back (`SendLocalRecords`) is untouched — no synthesized lines on the uplink.
- **Caveat for spokes that synced before this build**: a node that already seeded a wrong Main keeps it (Main is assigned once at record creation; re-sync only appends aliases). Fix per player with `mutate smurfmainset` (rev 1 propagates fleet-wide and overrides the rev-0 seed), or wipe that spoke's `SmurfDB.ini` once and let it re-sync fresh.
- Verified against the real binaries: hub egress E2E — `BEGIN 253` block, all 253 records on the wire, first line per record = curated Main + correct `FirstSeen` (253/253), the 190 alias-less records emit exactly one line each, zero malformed lines; fresh-spoke E2E (real hub block replayed to a live spoke with no DB) — **253/253 records, Main identical to the hub's curated Main on every record, FirstSeen preserved 253/253, full alias history merged, 253 pushed back**, zero ScriptWarnings. Harness: `Tools/e2e_c2_hub_capture_client.py` + `Tools/e2e_c2_spoke_replay_hub.py`.

## v1.4.2 (2026-11-05)
Corresponds to internal build v3.06.

- **Console display fix (bugfix for the 19-alias `whois` garble)** — the stock drop-down console word-wraps each message but
  only advances one row per stored message, so any reply longer than one console row overprinted the next. `whois`/`whoare`
  alias lists now wrap at one console row (every message ≤ 90 chars), and the "Ambiguous, matching connected players:" line
  is capped the same way, ending with `(+N more)` when the list doesn't fit. Display-only; data unchanged.
- **Empty-alias REG guard (log-flood fix)** — records with an empty alias list produced a malformed `REG <hash>,,<stamp>`
  wire line on every full sync (one per record — ~190 in the production seed), each rejected and logged by every receiver.
  Guarded on **both** push paths (`SmurfSpoke.SendLocalRecords` and the hub-side `SendAllRecordsTo`). Empty-alias records
  still don't propagate by design (whois finds them via their Main since v1.4.1); receivers keep their rejection logic.
- **Durable storage codec (new)** — this engine's ini reader strips raw backslashes from config strings, so names like
  `Sam\Slash` could never survive a save (they decayed to `SamSlash` moments after each write). Alias and Main values are
  now stored with `\` as `%5C` (lax URL-style): normal names stay byte-identical in the ini, hand-curation writes `%5C`,
  and the bundled Tools encode automatically. **Wire protocol unchanged** — REG/MAIN lines always carry the canonical live
  spelling; mixed v3.02–v3.05 fleets behave identically (whois matching is backslash-blind on both spellings).
- **Stored-spelling auto-repair (new, durable)** — when a player rejoins carrying a backslash spelling the stored entry
  lost, that one alias entry is rewritten with the faithful live spelling. Fires at most once per spelling (stable fixpoint),
  relays as a normal DB change, and — thanks to the codec — now survives saves, reboots and fleet syncs.
- Ops notes: never hand-edit `SmurfDB.ini` while the server runs (edits are silently clobbered by the next internal save);
  write `%5C` (uppercase) for backslashes when curating by hand.

## v1.4.1 (2026-11-05)
Corresponds to internal build v3.05.

- **whois searches Main (bugfix for v1.4.0)** — offline `mutate whois <name>` searched only the
  alias history, so records with a known **Main** but an empty alias list (curated fleet seed rows,
  single-name players) returned "No records found" until the player physically joined a node —
  whois only "saw" them after their first join. `FindByAlias()` now also matches each record's Main
  through the same case-insensitive, backslash-blind `AliasKey()` pipeline, so those records resolve
  offline. The Main spelling is still never copied into the alias list (no duplication) and is still
  filtered out of "Also seen as" on display. Exactly one caller changed (whois route 2): capture,
  dedup, sync, federation and wire behavior are untouched. No config/DB/layout changes — the upgrade
  is the usual single-file `.u` swap, fully compatible with mixed v3.02–v3.05 fleets.

## v1.4.0 (2026-11-04)
Corresponds to internal build v3.04.

- **Main identity** - every record now carries a **Main** (who the player IS) alongside the
  alias history (names they've worn). whois/whoare lead with the Main line:
  `Main: ProGamer (admin-set 2026-11-04 18:50)` followed by `Also seen as (N): ...` - the alias list
  is the filtered everything-else, so a smurf is readable at a glance instead of buried in a
  wall of names. New records seed `Main` from the player's first alias; legacy DBs self-heal
  at startup (`SeedMissingMains`, one write) - upgrading changes nothing manually.
- **`mutate smurfmainset <player name> <password>`** - admin command that sets a connected
  player's Main to their **exact current name** (players and spectators, case-insensitive match;
  the stored value is the server's live spelling). The retired Main is pushed into the alias
  history, the new Main's spelling is carved out of it. Password gate: `MainAdminPassword` in
  `SmurfHunter.ini` - **empty (default) = command disabled** (fail closed); compare is exact and
  case-sensitive, never logged. Password is the LAST space-delimited token, so names with
  spaces work naturally.
- **Fleet-wide convergence without clocks** - Main changes propagate over a new `MAIN` wire
  line, ordered by a per-record revision counter (Lamport-style) instead of timestamps: each
  admin change takes highest-seen+1 and stamps the node's `ServerID`; equal-rev conflicts
  (two admins, disconnected servers) resolve deterministically - smaller `ServerID` wins,
  logged as `MAIN conflict` on both outcomes. Timezone and clock-skew irrelevant by
  construction; full-SYNC reconciliation on reconnect heals anything missed. Seeds (rev 0)
  never travel - no conflict surface at all for auto-seeded data.
- **`ServerID` config key** - stable node identity for the tiebreak. Optional: empty (default)
  = a unique random 16-char hex ID is generated once and saved back on first boot. Hand-set
  values must be letters/digits/dash (max 32) and UNIQUE per node.
- Wire compatibility: v1.4.0 nodes exchange REG with older peers unchanged; older nodes
  ignore MAIN lines (never crash) but strip the new ini fields on their own saves - for full
  Main durability across a mixed fleet, roll the new `.u` to all nodes.
- Verified: compile first-pass clean; DM-Rankin regression zero ScriptWarnings with the
  `v3.04 active` marker, `SeedMissingMains` + `ServerID` generation observed live; **wire E2E
  8/8 against a live hub** (seed-only sync carries no MAIN lines; rev adoption; both tiebreak
  outcomes; stale rejection; malformed/rev-0/bad-origin/unknown-hash rejection; full-sync
  echo) plus on-disk alias-surgery verification. `.ucl`/`.int` byte-identical (servers only need
  the new `.u`).

## v1.3.0 (2026-11-04)
Corresponds to internal build v3.03.

- **Backslash name round-trip bug fixed** - names containing a backslash (clan prefixes etc.) never
  survived the ini save/load cycle (UE2.5 writes config strings raw but processes backslash escapes
  on import), so `Register()` re-appended the same alias on every capture and whois accumulated
  dozens-to-hundreds of duplicate aliases per player. Fixed at the storage boundary:
  `ToStorage()`/`FromStorage()` escape/unescape, `AliasKey()` backslash-blind matching for every
  comparison, and `ScrubDuplicates()` - a startup heal that dedupes existing databases in place
  (one write, only if something changed). Upgrading = replace the `.u` and restart; the live DB
  heals itself.
- **Idle spoke heal** - an idle server's sync link can be silently dropped by NAT/firewalls without
  the mutator ever noticing (half-open black hole until the next map change). On the first player
  join after >5 minutes of link silence the mutator now recycles the fleet connection
  (reconnect + full reconciliation). No wire protocol change, no config, no heartbeat traffic.
- **Federation peer retry interval 30s -> 300s** - a `FederationPeers` entry pointing at an
  unreachable or rejecting peer hub now retries every 5 minutes instead of every 30 seconds.
  The fleet spoke (your own hub uplink) keeps the 30s backoff.
- Verified: compile first-pass clean; DM-Rankin regression zero ScriptWarnings with the `v3.03
  active` marker; federation E2E re-run 16/16 ALL PASS against this build. `.ucl`/`.int` byte-identical
  to v1.2.0 (servers only need the new `.u`). See the README verification log and the new
  "Upgrading from v3.02" section.

## v1.2.0 (2026-11-02)
Corresponds to internal build v3.02.

- **Console-only commands** - the v1.1.0 plain-chat experiment is removed: `SmurfSayHandler` is gone,
  no broadcast handler is registered in the engine chain, and every command is `mutate`-prefixed
  again (`mutate whois <name>` / `mutate whoare` / `mutate smurfstats`). The mutator remains pure
  server-side with zero client downloads.
- **Ambiguous offline `whois` now prints every match in full** - if nobody connected matches the
  query but several stored game IDs do, each matching game ID gets its own full record block
  (first-seen + complete alias history, wrapped like the single-match reply), separated by `---`,
  uncapped. A player matching the query **on the server** still answers with that player's record
  only (priority unchanged), and ambiguous connected matches still return a candidate name list.
- **`mutate smurfhelp`** - new command listing every command with a one-line how-to.
- Verified: compile first-pass clean; DM-Rankin regression zero ScriptWarnings, `v3.02 active`
  marker confirmed, `.ucl`/`.int` byte-identical to v1.1.0 (servers only need the new `.u`).
  See the README verification log.

## v1.1.0 (2026-11-02)
Corresponds to internal build v3.01.

- **WebAdmin junk records, fixed at the root**: the engine's webadmin console proxy
  (`XWebAdmin.UTServerAdminSpectator` - an engine-spawned `MessagingSpectator`
  pseudo-player named "WebAdmin" with an unstable per-session ID hash) is now excluded
  structurally at capture time, so it can no longer be recorded at all. A real player
  genuinely named "WebAdmin" is still recorded normally - the exclusion matches the
  engine's fake connection by class, never by name. Junk records already on disk are
  purged by adding their hashes to `IgnoredHashes` (startup scrub + the sync choke
  point blocks re-entry from any node still holding a copy).
- **`whoare`** - every other player currently connected (players and spectators alike)
  with their full alias history in one command; the player running it is skipped.
- **Plain-chat commands** - `whois <partial name>`, `whoare` and `smurfstats` now work
  as plain chat text (say or team-say; `say whois bob` from the bare console too), no
  `mutate` prefix. Command lines are swallowed (only the sender sees the reply);
  only line-initial keywords trigger, so normal chat is never affected. All `mutate`
  spellings still work identically - both entry points share one command core.
- Verified: compile first-pass clean; DM-Rankin regression zero ScriptWarnings;
  chat-parser logic validated 23/23 edge cases. See the README verification log.

## v1.0.0 (2026-11-01)
First public release. This repository snapshot corresponds to internal build v3.00.

- **Local alias registry (internal v1.x)**: 1s poll captures players, spectators and renames (bots and
  engine pseudo-players excluded); records each player's stable CD-key ID (`GetPlayerIDHash()`) with
  their full alias history to `SmurfDB.ini`; public `mutate whois <partial name>` + `mutate smurfstats`;
  symbol-safe name sanitization applied identically at store and query time; case-insensitive matching.
- **Multi-server sync (internal v2.x)**: optional central hub (TCP 9075); spokes dial outbound-only;
  full-DB reconciliation handshake + per-alias deltas; idempotent union merge (convergence guaranteed);
  self-seeding spokes; bulk write coalescing; exact-match token auth + full input validation on every
  inbound record; ignore-list filter with startup scrub (junk/poison safety net).
- **Hub-to-hub federation (internal v3.00)**: `bFederate` + `FederationPeers` pairwise-secret peering;
  `LINKTYPE HUB` handshake; in-code peer source-IP check; relay-on-change over the unchanged v2 wire
  protocol; trust-circle topology with no central authority and no single point of failure.
- Verified on the OldUnreal 64-bit Linux engine build: local regression + hub/spoke/federation E2E
  (16/16 checks, real sockets), zero ScriptWarnings. See the README verification log.
