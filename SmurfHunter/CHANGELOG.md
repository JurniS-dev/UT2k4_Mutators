# Changelog - SmurfHunter

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
