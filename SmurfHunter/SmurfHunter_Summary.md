# SmurfHunter — What It Is and How to Use It

Ever wonder if that "new" player who shows up already suspiciously good is actually someone you've played against a dozen times before? That's **smurfing** — a veteran playing under a fresh name — and SmurfHunter is the server-side mutator that calls it out.

## The short version

Every player in UT2004 has a stable, hidden ID tied to their game key (the same ID the ban system uses). SmurfHunter quietly records **every name that ID has ever used on the server** — including all renames — and lets *anyone* look them up with a simple console command.

Change your name mid-game, change it back, change it again — it's all logged. The database only grows as new players and new names show up, and it survives restarts.

## How to use it

Open the console and type:

```
mutate whois <name>
```

That's it. The reply comes straight back to your console — private, never shown in chat, and nobody else sees that you asked.

- Works with **partial names** — `mutate whois bob` finds "BobTheSlayer".
- Works with **any capitalization** — `mutate whois`, `MUTATE WHOIS`, `Mutate WhoIs` are all the same.
- Works on **symbols and weird characters** in names — `Bob,Jr` and `Bob Jr` even find each other, and backslash clan-tag names are stored and matched exactly as typed (fixed in v1.3.0).
- Works on **connected players and past players alike** — the registry remembers.
- The reply is **private** — only you see it.

Who you get: if a player matching the name is **on the server right now**, you get their record and only theirs. If nobody connected matches but several stored records do, you get the **full name history of every matching player**, one block each — just retype with more of the name to narrow it down.

Example output: someone whois-able under `ProGamer` might turn out to also be `xX_Slayer_Xx`, `N00bDestroyer`, and `TotallyNewHere` — one player, four names, caught.

**New in v1.4.0 — the Main line.** Every player's record now leads with their **Main**: who the player actually *is*, as confirmed by the server admins, separate from the list of names they've *worn*. The reply now looks like:

```
[SmurfHunter] 'newname` is online now - first seen 2026-11-01 11:06
[SmurfHunter] Main: ProGamer (admin-set 2026-11-04 18:50)
[SmurfHunter] Also seen as (3): xX_Slayer_Xx, N00bDestroyer, TotallyNewHere
```

First line = who's in front of you right now. **Main line = who they actually are** (the stamp shows it was confirmed by an admin, and when). Last line = the full alias history minus the Main. If no admin has confirmed a Main yet, the registry's best guess (their oldest known name) is shown unmarked. Admins set the Main with `mutate smurfmainset <player name> <password>` on any synced server — it propagates to the whole cluster automatically.

There are also three more commands, same style:

```
mutate whoare
mutate smurfstats
mutate smurfhelp
```

- **`mutate whoare`** lists **every other player currently on the server** with their full name history, in one go — no need to whois each person one at a time. (You're skipped — you already know your own aliases.)
- **`mutate smurfstats`** just tells you how many players the server's registry has seen so far.
- **`mutate smurfhelp`** prints the command list in-game, in case you forget any of this.

All of them work in any capitalization.

## What it catches (and what it doesn't)

**Catches:** alt accounts, rename games, "totally new" players who are very much not new, ban evaders using different *names* — anything where the same person keeps the same game key.

**Doesn't catch:** someone using a genuinely *different* game key (a second copy of the game, or certain paid spoofer setups). The ID is only as stable as the key behind it. SmurfHunter is honest about this — it's a name-history tool, not magic. In practice, most casual smurfs don't bother with extra keys, so it catches the overwhelming majority.

**Who gets recorded:** players and spectators. Bots are excluded automatically, and so are engine-generated fake "players" (like the demo-recording spectator and the web admin panel's invisible "WebAdmin" connection), so they don't pollute the results. A real player genuinely named "WebAdmin" would still be recorded normally — the exclusion recognizes the engine's fake connection by its type, not by its name.

## Your privacy, in plain terms

- Your **raw ID is never shown to players** — whois only ever displays names, never the underlying identifier.
- Lookups are **one-way**: other players can see your name history, but there's no way to ask "who else plays from X machine" or anything beyond name history.
- The data stays **on the servers running the mutator** (see below for how server clusters share it).

## For the server nerds (short version)

- **Zero performance impact.** It's a once-per-second background check that costs microseconds, and lookups are instant memory reads. No bandwidth touches the game ports. Players cannot perceive it, period.
- **Nothing to download or install for players.** It's entirely server-side — you don't need the package, it never gets pushed to your client.
- **No special rights needed.** Any player can use `mutate whois` and the other commands — no admin login.
- **Server fleets can share one database.** Multiple servers can sync their registries through a central hub, so a name spotted on one server in the cluster is whois-able from all of them, live. Individual server operators can even link their databases with each other (opt-in, per-partner), so a smurf who hops communities gets recognized anyway. Each server still keeps its own full copy, so everything keeps working even if the network link drops.
- **Junk entries are ignored.** Server owners can maintain ignore lists so panel-monitor connections and other fake records never enter the database.
- **Backslash-name storage fixed (v1.3.0).** An engine ini quirk used to re-record names containing a backslash over and over, flooding whois with duplicate aliases; they're now stored once, matched exactly, and existing databases self-heal at startup. Idle servers also refresh their sync connection on the first join after a long quiet period, so lookups stay fresh.
- **Main identity (v1.4.0).** Server admins can confirm which alias is the player's real identity (`mutate smurfmainset`); it syncs across the whole cluster with conflict-free ordering and shows up as the `Main:` line in every whois. Server owners opt in by setting an admin password in the config — off by default.

## TL;DR

Type `mutate whois <name>` in the console. If that "new guy" has three other names in the registry, you'll know immediately. Type `mutate whoare` to check the whole server at once, and `mutate smurfhelp` if you forget the commands. That's the whole trick — and it's why smurfing on servers running SmurfHunter is basically pointless.
