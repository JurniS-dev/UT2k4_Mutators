// ===================================================================
// SmurfHunter - MutSmurfHunter  (v3.02 - console-only commands, full-record ambiguity, smurfhelp)
// Registers every connected human player and spectator by CD-key hash plus
// all their name aliases, and answers public "mutate whois <partial name>".
//
// v1 features (unchanged):
//   - 1-second GRI.PRIArray diff poll: joins, disconnects, renames
//     (players AND spectators; bots and engine-spawned pseudo-players such
//     as UnrealGame.DemoRecSpectator excluded).
//   - DB writes only on actual change; never on respawn of a known player.
//   - whois: case-insensitive everywhere, symbols handled symmetrically
//     via SmurfDB.SanitizeName(); raw hash never echoed; unknown mutate
//     keywords chain via Super.
//   - mutate smurfstats: record count.
//
// v2 (config: SmurfHunter.ini, section [SmurfHunter.MutSmurfHunter]):
//   - bCentralHub=True  : this server runs the hub listener (TCP CentralPort)
//   - CentralHost=ip    : this server is a SPOKE dialing that hub (outbound only)
//   - CentralPort=9075  : sync port (TCP). Hub needs it open inbound; spokes
//                         need nothing open (works on locked-down hosting).
//   - CentralToken=...  : shared fleet secret, required for any sync.
//
// v3 federation (wire protocol UNCHANGED - the v2 union sync is a CRDT):
//   - bFederate=True                     : master switch (default False)
//   - FederationPeers=(Host="1.2.3.4",Port=9075,Token="...")
//       One entry per PEER HUB. Host/Token pairwise per peer; the SAME
//       entry must exist on the peer (mirrored) with OUR Host+shared token.
//       Outbound: we dial each peer as a federation spoke (AUTH <token>
//       LINKTYPE HUB). Inbound: peers dial us; the token must match one of
//       OUR FederationPeers entries AND the source IP must match that
//       entry's Host (dotted IPs enforce the IP check; a DNS hostname falls
//       back to token-only auth with a logged warning).
//       Port<=0 falls back to CentralPort.
//   - Records flow live in BOTH directions over ONE dial: a peer's records
//     arrive on our fed link and relay down to our spokes/other peers, and
//     vice versa. Relay fires only on DB CHANGE, so mesh cycles die at the
//     first already-known hop - loops are structurally impossible.
//   - v2.02 ignore lists live in SmurfDB.ini ([SmurfHunter.SmurfDB]):
//       IgnoredHashes=... / IgnoredNames=... - rejected at Register() (the
//       single choke point: local capture + every inbound source) and
//       scrubbed from the on-disk DB at startup. The federated-data safety
//       net: a poisoned or junk record cannot enter from ANY peer.
//
// v3.01:
//   - GetHumanPC() excludes MessagingSpectator: the webadmin console proxy
//     (XWebAdmin.UTServerAdminSpectator, PRI named "WebAdmin") is an
//     engine-spawned pseudo-player with an UNSTABLE per-session ID hash -
//     v3.00 registered it as junk records. Exclusion is structural
//     (class-based), so a REAL player named "WebAdmin" is never affected.
//     Pair with IgnoredHashes= lines in SmurfDB.ini to purge records
//     already on disk (startup scrub removes them; the Register() choke
//     point means no node's copy can re-enter via union merge).
//   - mutate whoare: every connected player + alias history in one command
//     (the player running it is skipped).
//
// v3.02:
//   - Chat commands REMOVED (the v3.01 SmurfSayHandler experiment): all
//     commands are console-only 'mutate <command>' again - no broadcast
//     handler in the engine chain, and the zero-client-download property
//     stays guaranteed.
//   - whois offline ambiguity: every matching game ID now gets its FULL
//     record block (first-seen + complete alias history), one block per
//     match, uncapped - instead of the compact first-alias candidate list.
//     Connected players keep priority: any in-game match answers with
//     that player's record only.
//   - mutate smurfhelp: lists every command with a one-line how-to.
//
// Empty config = exact v1 local-only behavior, zero network activity.
// ===================================================================

class MutSmurfHunter extends Mutator config(SmurfHunter);

// ---- v2 config (SmurfHunter.ini) ----
var config bool   bCentralHub;
var config string CentralHost;
var config int    CentralPort;
var config string CentralToken;

// ---- v3 federation config ----
struct FederationPeer
{
    var config string Host;    // peer hub address; dotted IP RECOMMENDED (enforces the source-IP check)
    var config int    Port;   // peer sync port (<=0 = use CentralPort)
    var config string Token;  // pairwise secret shared ONLY with this peer
};
var config bool bFederate;
var config array<FederationPeer> FederationPeers;

// ---- v1 capture state ----
var array<PlayerReplicationInfo> WatchedPRIs;
var array<string> WatchedNames;

// ---- v2 sync runtime ----
var SmurfHubListener HubListener;
var array<SmurfHubLink> HubLinks;
var SmurfSpoke Spoke;
var float NextReconnectAt;
var bool bSpokeConfigured;

// ---- v3 federation runtime ----
var array<SmurfSpoke> FedSpokes;         // outbound peer links, parallel to FederationPeers
var array<float> FedNextReconnectAt;      // per-peer 300s backoff clock (v3.03: 5-min peer auth retry)

function PostBeginPlay()
{
    local int i, Scrubbed, Healed, FedCount;

    Super.PostBeginPlay();
    SetTimer(1.0, true);

    // v2.02: purge ignore-listed records BEFORE anything can merge more in
    // (an ignored record held by any remote node can never re-enter:
    // Register() is the single choke point for every merge source).
    Scrubbed = class'SmurfDB'.static.ScrubIgnored();

    // v3.03: heal duplicate / escape-corrupted aliases (backslash ini
    // round-trip bug) BEFORE any sync can re-relay the corrupt forms.
    Healed = class'SmurfDB'.static.ScrubDuplicates();

    bSpokeConfigured = (CentralHost != "" && CentralToken != "");

    if (bCentralHub)
    {
        // a hub needs either a fleet token (own spokes) or federation peers
        // (inbound peer links) - a pure relay hub with no own spokes works
        if (CentralToken != "" || (bFederate && FederationPeers.Length > 0))
        {
            HubListener = Spawn(class'SmurfHubListener');
            if (HubListener == None || !HubListener.StartListen(CentralPort, Self))
            {
                if (HubListener != None)
                {
                    HubListener.Destroy();
                    HubListener = None;
                }
            }
        }
        else
            Log("[SmurfHunter] bCentralHub=True but CentralToken is empty and no federation peers - hub disabled");
    }

    if (bFederate && FederationPeers.Length > 0)
    {
        FedSpokes.Length = FederationPeers.Length;
        FedNextReconnectAt.Length = FederationPeers.Length;
        for (i = 0; i < FederationPeers.Length; i++)
        {
            FedSpokes[i] = None;
            FedNextReconnectAt[i] = 0;   // connect on the first timer tick
            if (FederationPeers[i].Host == "" || FederationPeers[i].Token == "")
                Log("[SmurfHunter] federation: peer[" $ i $ "] has empty Host or Token - entry disabled");
        }
    }
    else if (FederationPeers.Length > 0)
        Log("[SmurfHunter] FederationPeers configured but bFederate=False - federation off");

    if (bSpokeConfigured)
        NextReconnectAt = 0;   // connect on the first timer tick
    else if (CentralHost != "" && CentralToken == "")
        Log("[SmurfHunter] CentralHost set but CentralToken is empty - spoke disabled");

    FedCount = ActivePeerCount();
    if (FedCount > 0)
        Log("[SmurfHunter] v3.03 federation active -" @ FedCount @ "peer hub(s)");
    else if (bFederate)
        Log("[SmurfHunter] v3.03 federation configured but NO usable peers");

    if (HubListener != None && bSpokeConfigured)
        Log("[SmurfHunter] v3.03 active - HUB + SPOKE (unusual, but allowed); DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (HubListener != None)
        Log("[SmurfHunter] v3.03 active - CENTRAL HUB mode, TCP" @ CentralPort $ "; DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (bSpokeConfigured)
        Log("[SmurfHunter] v3.03 active - spoke mode ->" @ CentralHost $ ":" $ string(CentralPort) $ "; DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (FedCount > 0)
        Log("[SmurfHunter] v3.03 active - FEDERATION node (no listener, no fleet spoke); DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else
        Log("[SmurfHunter] v3.03 active - local mode; commands: 'mutate whois <name>' / 'mutate whoare' / 'mutate smurfstats' / 'mutate smurfhelp'; DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
}

// ------------------------- v1: capture + whois -------------------------

// Resolve the owning PlayerController for a PRI if this is a registrable
// human player. Returns None for bots, engine-spawned pseudo-players
// (DemoRecSpectator et al), and anything that is not a PlayerController.
function PlayerController GetHumanPC(PlayerReplicationInfo PRI)
{
    local PlayerController PC;

    if (PRI == None || PRI.bBot || PRI.Owner == None)
        return None;
    PC = PlayerController(PRI.Owner);
    // v3.01: MessagingSpectator covers the webadmin console proxy
    // (XWebAdmin.UTServerAdminSpectator, PRI named "WebAdmin") - an
    // engine-spawned pseudo-player with an unstable per-session ID hash.
    // Class-based exclusion means a REAL player named "WebAdmin" (a normal
    // network PlayerController) is never caught.
    if (PC == None || PC.IsA('DemoRecSpectator') || PC.IsA('MessagingSpectator'))
        return None;
    return PC;
}

function string Pad2(int N)
{
    if (N < 10)
        return "0" $ N;
    return string(N);
}

function string BuildStamp()
{
    return string(Level.Year) $ "-" $ Pad2(Level.Month) $ "-" $ Pad2(Level.Day) $ " " $ Pad2(Level.Hour) $ ":" $ Pad2(Level.Minute);
}

function Timer()
{
    local GameReplicationInfo GRI;
    local PlayerReplicationInfo PRI;
    local PlayerController PC;
    local int i, j;
    local bool bSeen;

    GRI = Level.Game.GameReplicationInfo;
    if (GRI != None)
    {
        // register arrivals + detect renames
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            if (PRI == None || PRI.PlayerName == "")
                continue;
            PC = GetHumanPC(PRI);

            // every named PRI is tracked (including bots/pseudo-players) so we
            // classify each one exactly once instead of reprocessing per tick
            bSeen = false;
            for (j = 0; j < WatchedPRIs.Length; j++)
            {
                if (WatchedPRIs[j] == PRI)
                {
                    bSeen = true;
                    if (PC != None && WatchedNames[j] != PRI.PlayerName)
                    {
                        WatchedNames[j] = PRI.PlayerName;
                        RegisterPlayer(PC, "rename");
                    }
                    break;
                }
            }
            if (!bSeen)
            {
                WatchedPRIs[WatchedPRIs.Length] = PRI;
                WatchedNames[WatchedNames.Length] = PRI.PlayerName;
                if (PC != None)
                    RegisterPlayer(PC, "join");
                else if (!PRI.bBot)
                    Log("[SmurfHunter] tracking non-player '" $ PRI.PlayerName $ "' without registration (engine-spawned spectator, e.g. demorec)");
            }
        }

        // prune departed PRIs (backwards so Remove() stays safe)
        for (j = WatchedPRIs.Length - 1; j >= 0; j--)
        {
            if (WatchedPRIs[j] == None)
            {
                WatchedPRIs.Remove(j, 1);
                WatchedNames.Remove(j, 1);
                continue;
            }
            bSeen = false;
            for (i = 0; i < GRI.PRIArray.Length; i++)
            {
                if (GRI.PRIArray[i] == WatchedPRIs[j])
                {
                    bSeen = true;
                    break;
                }
            }
            if (!bSeen)
            {
                WatchedPRIs.Remove(j, 1);
                WatchedNames.Remove(j, 1);
            }
        }
    }

    // ---- sync housekeeping (event-driven; this is only sweeps/retries) ----
    SyncSweep();
}

function RegisterPlayer(PlayerController PC, string Why)
{
    local string Hash, Alias, Stamp;
    local bool bChanged;

    // v3.03: idle spoke heal. The fleet link carries zero traffic while the
    // server is idle, so NAT/firewalls can silently reap the TCP session
    // without Closed() ever firing (half-open black hole until map change).
    // On a player join after >5 min of link silence, proactively recycle:
    // Close() -> Closed() -> normal 30s backoff -> reconnect + full SYNC.
    // Harmless if the link was actually alive - one cheap reconnect cycle.
    if (Why ~= "join" && Spoke != None && Spoke.IsConnected()
        && Level.TimeSeconds - Spoke.LastHeardAt > 300.0)
    {
        Log("[SmurfHunter] player join after" @ int(Level.TimeSeconds - Spoke.LastHeardAt) @ "s of hub silence - recycling fleet link for a fresh sync");
        Spoke.Close();
    }

    Hash = PC.GetPlayerIDHash();
    if (Hash == "")
    {
        Log("[SmurfHunter]" @ Why @ PC.PlayerReplicationInfo.PlayerName $ ": empty ID hash, not recorded");
        return;
    }

    Alias = class'SmurfDB'.static.SanitizeName(PC.PlayerReplicationInfo.PlayerName);
    Stamp = BuildStamp();
    bChanged = class'SmurfDB'.static.Register(Hash, PC.PlayerReplicationInfo.PlayerName, Stamp);

    if (bChanged)
    {
        BroadcastRecord(Hash, Alias, Stamp);
        Log("[SmurfHunter]" @ Why @ PC.PlayerReplicationInfo.PlayerName @ "-> DB updated, now" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    }
    else
        Log("[SmurfHunter]" @ Why @ PC.PlayerReplicationInfo.PlayerName @ "(already known or ignored, no write)");
}

// ----------------------------- sync -------------------------------

// Local DB changed -> tell the world. Fire-and-forget by design: the local
// DB is the durable outbox, reconciliation on reconnect delivers anything
// missed while a link was down.
function BroadcastRecord(string Hash, string Alias, string Stamp)
{
    local string Line;

    Line = "REG " $ Hash $ "," $ Alias $ "," $ Stamp;
    if (HubListener != None || (bFederate && ActivePeerCount() > 0))
        RelayFederated(Line, None);
    if (Spoke != None && Spoke.IsConnected())
        Spoke.SendRecord(Hash, Alias, Stamp);
}

// ---- hub-side registry of live links ----
function RegisterLink(SmurfHubLink L)
{
    HubLinks[HubLinks.Length] = L;
}

function UnregisterLink(SmurfHubLink L)
{
    local int i;
    for (i = HubLinks.Length - 1; i >= 0; i--)
        if (HubLinks[i] == L)
            HubLinks.Remove(i, 1);
}

// Relay a validated line to every link EXCEPT Source (None = local origin,
// so everyone gets it): inbound spoke links, inbound federation peer
// links, AND our own outbound federation spokes. Relay fires ONLY on DB
// change (callers check Register()), which is what makes mesh cycles die
// at the first already-known hop - loops are structurally impossible.
function RelayFederated(string Line, Actor Source)
{
    local int i;

    for (i = 0; i < HubLinks.Length; i++)
        if (HubLinks[i] != None && HubLinks[i] != Source && HubLinks[i].bAuthed && HubLinks[i].IsConnected())
            HubLinks[i].SendText(Line);

    for (i = 0; i < FedSpokes.Length; i++)
        if (FedSpokes[i] != None && FedSpokes[i] != Source && FedSpokes[i].IsConnected())
            FedSpokes[i].SendText(Line);
}

// Hub sends its complete DB to a requesting link (SYNC / reconciliation).
function SendAllRecordsTo(SmurfHubLink Dest)
{
    local int i, j;
    local array<string> Parts;

    Dest.SendText("BEGIN " $ string(class'SmurfDB'.static.NumRecords()));
    for (i = 0; i < class'SmurfDB'.static.NumRecords(); i++)
    {
        Parts.Length = 0;
        Split(class'SmurfDB'.static.GetAliases(i), ",", Parts);
        for (j = 0; j < Parts.Length; j++)
            Dest.SendText("REG " $ class'SmurfDB'.static.GetHash(i) $ "," $ class'SmurfDB'.static.FromStorage(Parts[j]) $ "," $ class'SmurfDB'.static.GetFirstSeen(i));   // v3.03: wire carries the canonical (single-backslash) form
    }
    Dest.SendText("END");
}

// ---- spoke lifecycle (fleet spoke + federation spokes) ----

// Called by a SmurfSpoke whenever its link dies or fails to open.
// Handles BOTH kinds: federation spokes live in the FedSpokes[] slot that
// matches their FederationPeers[] entry; the fleet spoke stays singular.
function SpokeFailed(SmurfSpoke S)
{
    local int i;
    local bool bFound;

    if (S == None)
        return;

    if (S.bFederation)
    {
        for (i = 0; i < FedSpokes.Length; i++)
        {
            if (FedSpokes[i] == S)
            {
                FedSpokes[i] = None;
                FedNextReconnectAt[i] = Level.TimeSeconds + 300.0;   // v3.03: peer auth retry every 5 min, not 30s
                bFound = true;
                break;
            }
        }
        if (bFound)
            S.Destroy();
        return;
    }

    if (Spoke == S)
    {
        Spoke = None;
        S.Destroy();
        NextReconnectAt = Level.TimeSeconds + 30.0;
    }
}

function TryConnectSpoke()
{
    Spoke = Spawn(class'SmurfSpoke');
    if (Spoke != None)
    {
        if (!Spoke.ConnectTo(Self, CentralHost, CentralPort, CentralToken))
            SpokeFailed(Spoke);
    }
}

function TryConnectFedSpoke(int i)
{
    local int Port;

    Port = FederationPeers[i].Port;
    if (Port <= 0)
        Port = CentralPort;
    FedSpokes[i] = Spawn(class'SmurfSpoke');
    if (FedSpokes[i] != None)
    {
        if (!FedSpokes[i].ConnectTo(Self, FederationPeers[i].Host, Port, FederationPeers[i].Token, true))
            SpokeFailed(FedSpokes[i]);
    }
}

// v3: exact-match lookup of a federation peer by its pairwise token.
// Used by SmurfHubLink for inbound peer authentication.
function int FindPeerByToken(string Token)
{
    local int i;
    if (Token == "")
        return -1;
    for (i = 0; i < FederationPeers.Length; i++)
        if (FederationPeers[i].Token != "" && FederationPeers[i].Token == Token)
            return i;
    return -1;
}

// v3: number of FederationPeers entries with a usable Host + Token.
function int ActivePeerCount()
{
    local int i, n;
    for (i = 0; i < FederationPeers.Length; i++)
        if (FederationPeers[i].Host != "" && FederationPeers[i].Token != "")
            n++;
    return n;
}

// Runs once per second from Timer(): spoke reconnects + hub link hygiene.
// Never blocks gameplay - everything here is pointer checks and arithmetic.
function SyncSweep()
{
    local int i;

    // fleet spoke: (re)connect with 30s backoff while disconnected
    if (bSpokeConfigured && Spoke == None && Level.TimeSeconds >= NextReconnectAt)
        TryConnectSpoke();

    // federation spokes: 300s backoff (v3.03: 5-min peer auth retry), one per peer entry
    if (bFederate)
    {
        for (i = 0; i < FederationPeers.Length; i++)
        {
            if (FederationPeers[i].Host == "" || FederationPeers[i].Token == "")
                continue;
            if (FedSpokes[i] == None && Level.TimeSeconds >= FedNextReconnectAt[i])
                TryConnectFedSpoke(i);
        }
    }

    // hub: close unauthenticated links after 15s; drop dead links
    if (HubListener != None)
    {
        for (i = HubLinks.Length - 1; i >= 0; i--)
        {
            if (HubLinks[i] == None)
            {
                HubLinks.Remove(i, 1);
                continue;
            }
            if (!HubLinks[i].IsConnected())
            {
                UnregisterLink(HubLinks[i]);
                continue;
            }
            if (!HubLinks[i].bAuthed && Level.TimeSeconds - HubLinks[i].ConnectTime > 15.0)
            {
                Log("[SmurfHunter] hub: closing unauthenticated link from" @ HubLinks[i].RemoteIP());
                HubLinks[i].Close();
            }
        }
    }
}

function ReplyRecord(PlayerController Sender, string Hash, optional string OnlineName)
{
    local int idx, i, Count;
    local array<string> Parts;
    local string Line, Part;

    if (Hash == "")
    {
        Sender.ClientMessage("[SmurfHunter] No records found");
        return;
    }
    idx = class'SmurfDB'.static.FindHash(Hash);
    if (idx < 0)
    {
        if (OnlineName != "")
            Sender.ClientMessage("[SmurfHunter] '" $ OnlineName $ "' is connected but has no stored history yet");
        else
            Sender.ClientMessage("[SmurfHunter] No records found");
        return;
    }

    if (OnlineName != "")
        Sender.ClientMessage("[SmurfHunter] '" $ OnlineName $ "' is online now - first seen" @ class'SmurfDB'.static.GetFirstSeen(idx));
    else
        Sender.ClientMessage("[SmurfHunter] First seen" @ class'SmurfDB'.static.GetFirstSeen(idx));

    Parts.Length = 0;
    Split(class'SmurfDB'.static.GetAliases(idx), ",", Parts);
    if (Parts.Length == 1)
    {
        Sender.ClientMessage("[SmurfHunter] Known as: " $ class'SmurfDB'.static.FromStorage(Parts[0]));
        return;
    }

    Line = "[SmurfHunter] Known as (" $ Parts.Length $ " aliases): ";
    Count = 0;
    for (i = 0; i < Parts.Length; i++)
    {
        Part = class'SmurfDB'.static.FromStorage(Parts[i]);   // v3.03: unescape for display
        if (Len(Line) + Len(Part) > 200)  // wrap long lists across messages
        {
            Sender.ClientMessage(Line);
            Line = "[SmurfHunter] ";
            Count = 0;
        }
        if (Count > 0)
            Line = Line $ ", ";
        Line = Line $ Part;
        Count++;
    }
    if (Count > 0)
        Sender.ClientMessage(Line);
}

function Mutate(string MutateString, PlayerController Sender)
{
    // our commands: "whois [name]", "whoare", "smurfstats" and "smurfhelp" -
    // everything else chains on to the rest of the mutator list.
    if (MutateString ~= "whois" || Left(MutateString, 6) ~= "whois ")
        CmdWhoIs(Sender, class'SmurfDB'.static.SanitizeName(Mid(MutateString, 5)));
    else if (MutateString ~= "whoare" || Left(MutateString, 7) ~= "whoare ")
        CmdWhoAre(Sender);
    else if (MutateString ~= "smurfstats")
    {
        if (Sender != None)
            Sender.ClientMessage("[SmurfHunter] Registry:" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    }
    else if (MutateString ~= "smurfhelp")
        CmdSmurfHelp(Sender);
    else
        Super.Mutate(MutateString, Sender);
}

// ---------------------- command cores (mutate-only since v3.02) ----------------------
// whois core. Route 1: connected human players (exact match beats partials,
// then partials; ambiguous -> candidate name list). ANY connected match
// wins over the DB. Route 2: offline DB alias search; ambiguous -> one
// FULL record block per matching game ID (v3.02), uncapped.
function CmdWhoIs(PlayerController Sender, string Arg)
{
    local GameReplicationInfo GRI;
    local PlayerReplicationInfo PRI;
    local PlayerController PC;
    local array<int> Matches;
    local string LiveName, Line;
    local int i, Count, HitIndex;

    if (Sender == None)
        return;

    if (Arg == "")
    {
        Sender.ClientMessage("[SmurfHunter] Usage: whois <partial name>  (case-insensitive, partial names OK)");
        return;
    }

    // route 1: connected human players - exact name match beats all partials
    GRI = Level.Game.GameReplicationInfo;
    Count = 0;
    HitIndex = -1;
    if (GRI != None)
    {
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            PC = GetHumanPC(PRI);
            if (PC == None)
                continue;
            LiveName = class'SmurfDB'.static.SanitizeName(PRI.PlayerName);
            if (LiveName ~= Arg)
            {
                Count = 1;
                HitIndex = i;
                break;
            }
            if (InStr(Caps(LiveName), Caps(Arg)) >= 0)
            {
                Count++;
                HitIndex = i;
            }
        }
    }

    if (Count == 1)
    {
        PC = GetHumanPC(GRI.PRIArray[HitIndex]);
        ReplyRecord(Sender, PC.GetPlayerIDHash(), GRI.PRIArray[HitIndex].PlayerName);
        return;
    }
    if (Count > 1)
    {
        Line = "[SmurfHunter] Ambiguous, matching connected players:";
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            PC = GetHumanPC(PRI);
            if (PC == None)
                continue;
            LiveName = class'SmurfDB'.static.SanitizeName(PRI.PlayerName);
            if (LiveName ~= Arg || InStr(Caps(LiveName), Caps(Arg)) >= 0)
                Line = Line @ PRI.PlayerName $ " /";
        }
        if (Right(Line, 1) == "/")
            Line = Left(Line, Len(Line) - 1);
        Sender.ClientMessage(Line);
        return;
    }

    // route 2: offline DB search over stored aliases
    if (class'SmurfDB'.static.FindByAlias(Arg, Matches) == 0)
    {
        Sender.ClientMessage("[SmurfHunter] No records found for '" $ Arg $ "'");
        return;
    }
    // v3.02: ambiguous offline match - every matching game ID gets its FULL
    // record block (first-seen + complete alias history), uncapped; the
    // querier refines if it is too much. Hashes stay hidden in all output.
    if (Matches.Length > 1)
    {
        Sender.ClientMessage("[SmurfHunter] No connected player matches '" $ Arg $ "' -" @ Matches.Length @ "record(s) matched, full history each:");
        for (i = 0; i < Matches.Length; i++)
        {
            if (i > 0)
                Sender.ClientMessage("[SmurfHunter] ---");
            ReplyRecord(Sender, class'SmurfDB'.static.GetHash(Matches[i]));
        }
        return;
    }
    ReplyRecord(Sender, class'SmurfDB'.static.GetHash(Matches[0]));
}

// whoare core - every connected human player (players + spectators) with
// their stored alias history, in one command. The player running it is
// skipped: their own history is one 'whois <own name>' away. Records are
// resolved by CD-key hash, so there is no ambiguity resolution here.
function CmdWhoAre(PlayerController Sender)
{
    local GameReplicationInfo GRI;
    local PlayerReplicationInfo PRI;
    local PlayerController PC;
    local int i, N;

    if (Sender == None)
        return;

    GRI = Level.Game.GameReplicationInfo;
    N = 0;
    if (GRI != None)
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PC = GetHumanPC(GRI.PRIArray[i]);
            if (PC != None && PC != Sender)
                N++;
        }

    if (N == 0)
    {
        Sender.ClientMessage("[SmurfHunter] No other players connected");
        return;
    }

    Sender.ClientMessage("[SmurfHunter] Players online (" $ N $"):");
    for (i = 0; i < GRI.PRIArray.Length; i++)
    {
        PRI = GRI.PRIArray[i];
        PC = GetHumanPC(PRI);
        if (PC == None || PC == Sender)
            continue;
        ReplyRecord(Sender, PC.GetPlayerIDHash(), PRI.PlayerName);
    }
}

// smurfhelp core (v3.02): one-line how-to per command, console only.
function CmdSmurfHelp(PlayerController Sender)
{
    if (Sender == None)
        return;
    Sender.ClientMessage("[SmurfHunter] Commands (type in console, case-insensitive):");
    Sender.ClientMessage("[SmurfHunter] mutate whois <name> - look up a player by name or alias (partial OK)");
    Sender.ClientMessage("[SmurfHunter] mutate whoare - every connected player with their alias history");
    Sender.ClientMessage("[SmurfHunter] mutate smurfstats - how many records the registry holds");
    Sender.ClientMessage("[SmurfHunter] mutate smurfhelp - this list");
}

defaultproperties
{
    bCentralHub=False
    CentralHost=""
    CentralPort=9075
    CentralToken=""
    bFederate=False
}
