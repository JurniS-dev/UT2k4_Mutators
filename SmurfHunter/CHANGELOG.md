# Changelog - SmurfHunter

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
