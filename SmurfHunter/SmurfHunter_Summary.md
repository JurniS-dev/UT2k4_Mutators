# SmurfHunter — What It Is and How to Use It

Ever wonder if that "new" player who shows up already suspiciously good is actually someone you've played against a dozen times before? That's **smurfing** — a veteran playing under a fresh name — and SmurfHunter is the server-side mutator that calls it out.

## The short version

Every player in UT2004 has a stable, hidden ID tied to their game key (the same ID the ban system uses). SmurfHunter quietly records **every name that ID has ever used on the server** — including all renames — and lets *anyone* look them up with a simple console command.

Change your name mid-game, change it back, change it again — it's all logged. The database only grows as new players and new names show up, and it survives restarts.

## How to use it

Just type it in **chat** — press your chat key and type:

```
whois <name>
```

That's it. No console, no `mutate` prefix — the line doesn't even show up in anyone else's chat (only you see the reply). Team-chat works too, and the console spellings (`mutate whois <name>` from the `~` console) still work exactly the same.

- Works with **partial names** — `whois bob` finds "BobTheSlayer".
- Works with **any capitalization** — `whois`, `WHOIS`, `WhoIs` are all the same.
- Works on **symbols and weird characters** in names — `Bob,Jr` and `Bob Jr` even find each other.
- Works on **connected players and past players alike** — the registry remembers.
- The reply is **private** — only you see it, nobody else in chat.

If your search matches several players, you'll get a candidate list — just retype with more of the name.

Example output: someone whois-able under `ProGamer` might turn out to also be `xX_Slayer_Xx`, `N00bDestroyer`, and `TotallyNewHere` — one player, four names, caught.

There are also two more commands, same plain-chat style:

```
whoare
smurfstats
```

- **`whoare`** lists **every other player currently on the server** with their full name history, in one go — no need to whois each person one at a time. (You're skipped — you already know your own aliases.)
- **`smurfstats`** just tells you how many players the server's registry has seen so far.

All three work in any capitalization, in say or team-chat.

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
- **No special rights needed.** Any player can use `whois` and `smurfstats` — no admin login.
- **Server fleets can share one database.** Multiple servers can sync their registries through a central hub, so a name spotted on one server in the cluster is whois-able from all of them, live. Individual server operators can even link their databases with each other (opt-in, per-partner), so a smurf who hops communities gets recognized anyway. Each server still keeps its own full copy, so everything keeps working even if the network link drops.
- **Junk entries are ignored.** Server owners can maintain ignore lists so panel-monitor connections and other fake records never enter the database.

## TL;DR

Type `whois <name>` in chat. If that "new guy" has three other names in the registry, you'll know immediately. Type `whoare` to check the whole server at once. That's the whole trick — and it's why smurfing on servers running SmurfHunter is basically pointless.
