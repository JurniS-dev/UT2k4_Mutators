# Changelog - SmurfHunter

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
