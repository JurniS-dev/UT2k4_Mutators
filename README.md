# UT2k4 Mutators

Server-side mutators for Unreal Tournament 2004, built and verified on the OldUnreal 64-bit Linux
engine build. Every mutator ships with the compiled package **and** the full UnrealScript source,
so any server owner can deploy directly or rebuild from source for their engine version.

| Mutator | Version | What it does |
|---|---|---|
| [SmurfHunter](SmurfHunter/) | v1.2.0 | Alias registry + public `mutate whois`/`whoare`/`smurfstats`/`smurfhelp` console commands - records every name a player's stable CD-key ID has used, with optional multi-server sync and hub-to-hub federation. Server-side only, zero client impact. |

## Layout convention

Every mutator folder follows the same structure:

- `Source_Code/` - full UnrealScript `.uc` sources (the canonical deliverable).
- `Compiled/System/` - ready-to-deploy `.u`/`.ucl`/`.int` plus example data/config files; drop them
  into the server's game-tree `System/` folder.
- `Config_Examples/` - ready-to-edit `.ini` examples for each optional mode.
- `Tools/` - helper scripts (seed-data converters, E2E test harnesses).
- `README.md` - full documentation (install, config, DB format, verification log).
- `CHANGELOG.md` - release history.

> **Binary note**: bundled `.u` files are compiled against the OldUnreal 64-bit Linux engine build.
> Servers on retail/other engine builds should compile from source instead - each mutator README
> documents the one-command `ucc make` procedure.

## License

No open-source license is currently declared; all rights are reserved by the author.
