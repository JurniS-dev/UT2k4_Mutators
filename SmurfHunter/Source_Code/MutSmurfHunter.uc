// ===================================================================
// SmurfHunter - MutSmurfHunter  (v3.06 - console display + sync hygiene fixes)
// Registers every connected human player and spectator by CD-key hash plus
// all their name aliases, and answers public "mutate whois <partial name>".
//
// v3.06 (public v1.4.2 - fixes v1.4.1): display + sync hygiene + durable
// name storage.
// (1) whois/whoare output wraps alias lists at ~90 chars (one console row)
//     and caps the ambiguous-match list the same way - stock ExtendedConsole
//     word-wraps but advances one row per message, so longer lines overlap.
// (2) Empty-alias REG guard: SmurfSpoke.SendLocalRecords AND the hub-side
//     SendAllRecordsTo no longer emit the malformed "REG hash,,stamp" line
//     (each was rejected + logged by every receiver on every full sync).
// (3) DURABLE STORAGE CODEC (C1, in SmurfDB): the engine's ini reader
//     strips raw backslashes from config strings, so backslash names never
//     survived a save. Storage now encodes '\' as %5C (lax URL-style);
//     comparisons and egress decode. Wire format unchanged; old plain-form
//     DBs load as-is.
// (4) Register() auto-repairs a stored alias spelling whose backslashes
//     were lost when the live name still carries them - DURABLE under (3),
//     surviving saves, reboots and fleet syncs.
//
// v3.05 (public v1.4.1 - fixes v1.4.0): offline whois (route 2) now matches
// a record's Main in addition to its alias list, so records with an empty
// alias list but a known Main resolve offline. Main is still shown once -
// the display still filters it out of "Also seen as". No config, wire or
// storage changes.
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
//   - mutate whoare: every connected player + alias history in one command
//     (the player running it is skipped).
//
// v3.02:
//   - Chat commands REMOVED (the v3.01 SmurfSayHandler experiment): all
//     commands are console-only 'mutate <command>' again.
//   - whois offline ambiguity: every matching game ID gets its FULL
//     record block, uncapped.
//   - mutate smurfhelp: lists every command with a one-line how-to.
//
// v3.03: backslash-safe storage round-trip + idle-spoke heal + 300s fed
//       peer retry (see SmurfDB header).
//
// v3.04 MAIN IDENTITY (merge semantics: SmurfDB header):
//   - config: MainAdminPassword (gate for 'mutate smurfmainset'; EMPTY =
//     feature disabled, fail-closed; compared EXACTLY, case-sensitive,
//     never logged, never echoed), ServerID (stable node identity for
//     MAIN tiebreaks; auto-generated once on first boot if empty or
//     invalid, then stored - letters/digits/dash, max 32).
//   - mutate smurfmainset <player name> <password>: the PASSWORD is the
//     LAST space-delimited token (names may contain spaces); unique
//     case-insensitive EXACT match against connected humans (players AND
//     spectators); the player's exact current spelling becomes Main
//     (rev = current+1, origin = our ServerID) and the change relays
//     fleet-wide.
//   - whois/whoare: Main gets its own headline line ("Main: X", plus
//     "(admin-set <stamp>)" when rev >= 1); the alias list becomes the
//     filtered "Also seen as (...)".
//   - relay + full sync carry MAIN lines for rev >= 1 records only;
//     seeds (rev 0) stay local and never conflict.
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

// ---- v3.04 config ----
var config string MainAdminPassword;   // 'mutate smurfmainset' gate; empty = feature disabled
var config string ServerID;            // node identity for MAIN merge tiebreaks

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
    local int i, Scrubbed, Healed, Seeded, FedCount;

    Super.PostBeginPlay();
    SetTimer(1.0, true);

    // v2.02: purge ignore-listed records BEFORE anything can merge more in
    // (an ignored record held by any remote node can never re-enter:
    // Register() is the single choke point for every merge source).
    Scrubbed = class'SmurfDB'.static.ScrubIgnored();

    // v3.03: heal duplicate / escape-corrupted aliases (backslash ini
    // round-trip bug) BEFORE any sync can re-relay the corrupt forms.
    Healed = class'SmurfDB'.static.ScrubDuplicates();

    // v3.04: seed a Main for records that have none yet (oldest alias,
    // rev 0 = local-only seed), before any sync runs.
    Seeded = class'SmurfDB'.static.SeedMissingMains();

    // v3.04: stable node identity for MAIN merge tiebreaks. Generated once
    // and persisted on first boot; a hand-set ID must be letters/digits/
    // dash (max 32) or it is replaced - a broken ID would corrupt every
    // wire line it rides on. NOTE: if SmurfHunter.ini is not writable
    // (root-owned), the save silently fails and a fresh ID regenerates
    // every boot - the log line below makes that visible.
    if (ServerID == "")
    {
        ServerID = GenerateServerID();
        SaveConfig();
        Log("[SmurfHunter] ServerID generated:" @ ServerID @ "- stored in SmurfHunter.ini (if a new ID appears every boot, the ini is not writable)");
    }
    else if (!class'SmurfDB'.static.SafeServerID(ServerID))
    {
        Log("[SmurfHunter] ServerID '" $ ServerID $ "' is invalid (letters/digits/dash, max 32 chars) - generating a valid one");
        ServerID = GenerateServerID();
        SaveConfig();
    }

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
                Log("[SmurfHunter] federation: peer[" $ i $"] has empty Host or Token - entry disabled");
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
        Log("[SmurfHunter] v3.06 federation active -" @ FedCount @ "peer hub(s)");
    else if (bFederate)
        Log("[SmurfHunter] v3.06 federation configured but NO usable peers");

    if (HubListener != None && bSpokeConfigured)
        Log("[SmurfHunter] v3.06 active - HUB + SPOKE (unusual, but allowed); DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (HubListener != None)
        Log("[SmurfHunter] v3.06 active - CENTRAL HUB mode, TCP" @ CentralPort $ "; DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (bSpokeConfigured)
        Log("[SmurfHunter] v3.06 active - spoke mode ->" @ CentralHost $ ":" @ string(CentralPort) $ "; DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else if (FedCount > 0)
        Log("[SmurfHunter] v3.06 active - FEDERATION node (no listener, no fleet spoke); DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    else
        Log("[SmurfHunter] v3.06 active - local mode; commands: 'mutate whois <name>' / 'mutate whoare' / 'mutate smurfstats' / 'mutate smurfhelp' (+ 'mutate smurfmainset <name> <password>' when MainAdminPassword is set); DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
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
        Log("[SmurfHunter]" @ Why @ PC.PlayerReplicationInfo.PlayerName $ "(already known or ignored, no write)");
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

// v3.04: local Main changed (admin) -> tell the world. Same fire-and-forget
// outbox model as BroadcastRecord: reconciliation covers missed links.
// MainName is the canonical (single-backslash, sanitized) form.
function BroadcastMain(string Hash, string MainName, int Rev, string Origin, string Stamp)
{
    local string Line;

    Line = "MAIN " $ Hash $ "," $ Rev $ "," $ Origin $ "," $ Stamp $ "," $ MainName;
    if (HubListener != None || (bFederate && ActivePeerCount() > 0))
        RelayFederated(Line, None);
    if (Spoke != None && Spoke.IsConnected())
        Spoke.SendMainLine(Hash, MainName, Rev, Origin, Stamp);
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
// change (callers check Register()/MergeMain()), which is what makes mesh
// cycles die at the first already-known hop - loops are structurally
// impossible.
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
// v3.04: admin-set Main state (rev >= 1) rides AFTER the alias lines inside
// the same block, so a node lacking a record entirely has it by the time
// the record's MAIN arrives. Seeds (rev 0) stay local.
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
        {
            // v3.06: Split('',',') yields ONE empty part for an empty alias
            // list - never emit the malformed "REG hash,,stamp" line (the
            // spoke-side twin of SmurfSpoke.SendLocalRecords; every receiver
            // rejected one per record and flooded the log on every full
            // sync; failure_log 31). Empty-alias records don't propagate by
            // design - whois finds them via Main since v1.4.1.
            if (Parts[j] == "")
                continue;
            Dest.SendText("REG " $ class'SmurfDB'.static.GetHash(i) $ "," $ class'SmurfDB'.static.FromStorage(Parts[j]) $ "," $ class'SmurfDB'.static.GetFirstSeen(i));   // v3.03: wire carries the canonical (single-backslash) form
        }
    }
    for (i = 0; i < class'SmurfDB'.static.NumRecords(); i++)
    {
        if (class'SmurfDB'.static.GetMainSet(i) > 0)
            Dest.SendText("MAIN " $ class'SmurfDB'.static.GetHash(i) $ "," $ class'SmurfDB'.static.GetMainSet(i) $ "," $ class'SmurfDB'.static.GetMainOrigin(i) $ "," $ class'SmurfDB'.static.GetMainStamp(i) $ "," $ class'SmurfDB'.static.FromStorage(class'SmurfDB'.static.GetMain(i)));
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
    local string Line, Part, MainDisp;

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

    // v3.04: the Main gets its own headline line. rev 0 = seeded (just the
    // name); rev >= 1 = admin-set (with the display-only stamp).
    MainDisp = class'SmurfDB'.static.FromStorage(class'SmurfDB'.static.GetMain(idx));
    if (MainDisp != "")
    {
        if (class'SmurfDB'.static.GetMainSet(idx) > 0)
        {
            if (class'SmurfDB'.static.GetMainStamp(idx) != "")
                Sender.ClientMessage("[SmurfHunter] Main: " $ MainDisp $ " (admin-set " $ class'SmurfDB'.static.GetMainStamp(idx) $ ")");
            else
                Sender.ClientMessage("[SmurfHunter] Main: " $ MainDisp $ " (admin-set)");
        }
        else
            Sender.ClientMessage("[SmurfHunter] Main: " $ MainDisp);
    }

    // the alias list is the filtered "everything else": the Main's spelling
    // is carved out at set time for admin-set Mains; rev-0 seeds keep their
    // full history on disk, so the display filter does the job here.
    Parts.Length = 0;
    Split(class'SmurfDB'.static.GetAliases(idx), ",", Parts);
    if (MainDisp != "")
    {
        for (i = Parts.Length - 1; i >= 0; i--)
            if (Parts[i] == "" || class'SmurfDB'.static.AliasKey(Parts[i]) == class'SmurfDB'.static.AliasKey(MainDisp))
                Parts.Remove(i, 1);
    }
    else
    {
        for (i = Parts.Length - 1; i >= 0; i--)
            if (Parts[i] == "")
                Parts.Remove(i, 1);
    }

    if (Parts.Length == 0)
        return;   // Main-only record (or a legacy empty alias list) - nothing else to show
    if (Parts.Length == 1)
    {
        if (MainDisp != "")
            Sender.ClientMessage("[SmurfHunter] Also seen as: " $ class'SmurfDB'.static.FromStorage(Parts[0]));
        else
            Sender.ClientMessage("[SmurfHunter] Known as: " $ class'SmurfDB'.static.FromStorage(Parts[0]));
        return;
    }

    if (MainDisp != "")
        Line = "[SmurfHunter] Also seen as (" $ Parts.Length $ "): ";
    else
        Line = "[SmurfHunter] Known as (" $ Parts.Length $ " aliases): ";
    Count = 0;
    for (i = 0; i < Parts.Length; i++)
    {
        Part = class'SmurfDB'.static.FromStorage(Parts[i]);   // v3.03: unescape for display
        if (Len(Line) + Len(Part) > 88)   // v3.06: max one console row - stock ExtendedConsole word-wraps but advances one row per message (failure_log 33); 88 + the ', ' separator guarantees <= 90 per message
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
    // our commands: "whois [name]", "whoare", "smurfstats", "smurfhelp",
    // and (v3.04) "smurfmainset <name> <password>" - everything else
    // chains on to the rest of the mutator list.
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
    else if (MutateString ~= "smurfmainset" || Left(MutateString, 13) ~= "smurfmainset ")
        CmdSmurfMainSet(Sender, Mid(MutateString, 12));
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
    local string LiveName, Line, Suffix;
    local int i, Count, HitIndex, Shown;

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
        // v3.06: cap the list at one console row (~90 chars) - stock
        // ExtendedConsole overlaps any message longer than one row
        Line = "[SmurfHunter] Ambiguous, matching connected players:";
        Shown = 0;
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            PC = GetHumanPC(PRI);
            if (PC == None)
                continue;
            LiveName = class'SmurfDB'.static.SanitizeName(PRI.PlayerName);
            if (LiveName ~= Arg || InStr(Caps(LiveName), Caps(Arg)) >= 0)
            {
                if (Len(Line) + Len(PRI.PlayerName) + 3 > 90)
                    break;   // row budget spent - remaining matches listed as a count
                Line = Line @ PRI.PlayerName $ " /";
                Shown++;
            }
        }
        if (Right(Line, 1) == "/")
            Line = Left(Line, Len(Line) - 1);
        if (Shown < Count)
        {
            Suffix = " (+" $ (Count - Shown) $ " more)";
            if (Len(Line) + Len(Suffix) > 90)
                Line = Left(Line, 90 - Len(Suffix)) $ Suffix;
            else
                Line = Line $ Suffix;
        }
        Sender.ClientMessage(Line);
        return;
    }

    // route 2: offline DB search over Main + stored aliases (v3.05: Main
    // matches so empty-alias records still resolve; aliases alone matched
    // before v3.05)
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

// v3.04: admin Main setter.
//   mutate smurfmainset <player name> <password>
// The PASSWORD is the LAST space-delimited token; the name is everything
// before it (player names can contain spaces). It is compared EXACTLY
// (case-sensitive) against MainAdminPassword and is never logged, never
// echoed. The target must be a connected human (player or spectator,
// bots excluded) and must match the given name EXACTLY (case-insensitive);
// on a unique match the player's exact current spelling becomes Main
// (rev = current+1, origin = this server's ServerID) and the change
// relays fleet-wide. Refuse, never guess: zero or multiple matches, wrong
// password, missing record, or no change -> nothing is written.
function CmdSmurfMainSet(PlayerController Sender, string Args)
{
    local GameReplicationInfo GRI;
    local PlayerReplicationInfo PRI;
    local PlayerController PC;
    local array<string> Parts;
    local string NameArg, Password, MainName, Line, Stamp;
    local int i, Matches, HitIdx, idx, NewRev;

    if (Sender == None)
        return;

    while (Left(Args, 1) == " " && Args != "")
        Args = Mid(Args, 1);
    while (Right(Args, 1) == " " && Args != "")
        Args = Left(Args, Len(Args) - 1);

    if (Args == "")
    {
        Sender.ClientMessage("[SmurfHunter] Usage: smurfmainset <player name> <password>  (matches connected players/spectators, case-insensitive)");
        return;
    }
    if (MainAdminPassword == "")
    {
        Sender.ClientMessage("[SmurfHunter] smurfmainset is disabled on this server (MainAdminPassword empty in SmurfHunter.ini)");
        return;
    }

    // last token = password, everything before = player name (names may
    // contain spaces; a password containing spaces cannot be expressed -
    // document that)
    Parts.Length = 0;
    Split(Args, " ", Parts);
    if (Parts.Length < 2)
    {
        Sender.ClientMessage("[SmurfHunter] Usage: smurfmainset <player name> <password>");
        return;
    }
    Password = Parts[Parts.Length - 1];
    Parts.Length = Parts.Length - 1;
    NameArg = "";
    for (i = 0; i < Parts.Length; i++)
    {
        if (Parts[i] == "")
            continue;
        if (NameArg != "")
            NameArg = NameArg $ " ";
        NameArg = NameArg $ Parts[i];
    }
    if (NameArg == "")
    {
        Sender.ClientMessage("[SmurfHunter] Usage: smurfmainset <player name> <password>");
        return;
    }

    if (Password != MainAdminPassword)   // exact, case-sensitive; NEVER logged
    {
        Sender.ClientMessage("[SmurfHunter] Wrong password");
        return;
    }

    // unique case-insensitive EXACT match against connected humans
    // (players AND spectators; bots + engine pseudo-players excluded)
    GRI = Level.Game.GameReplicationInfo;
    Matches = 0;
    HitIdx = -1;
    if (GRI != None)
    {
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            PC = GetHumanPC(PRI);
            if (PC == None)
                continue;
            if (class'SmurfDB'.static.SanitizeName(PRI.PlayerName) ~= class'SmurfDB'.static.SanitizeName(NameArg))
            {
                Matches++;
                HitIdx = i;
            }
        }
    }
    if (Matches == 0)
    {
        Sender.ClientMessage("[SmurfHunter] No player named '" $ NameArg $ "' on this server");
        return;
    }
    if (Matches > 1)
    {
        Line = "[SmurfHunter] Ambiguous - multiple players match '" $ NameArg $ "':";
        for (i = 0; i < GRI.PRIArray.Length; i++)
        {
            PRI = GRI.PRIArray[i];
            PC = GetHumanPC(PRI);
            if (PC == None)
                continue;
            if (class'SmurfDB'.static.SanitizeName(PRI.PlayerName) ~= class'SmurfDB'.static.SanitizeName(NameArg))
                Line = Line @ PRI.PlayerName $ " /";
        }
        if (Right(Line, 1) == "/")
            Line = Left(Line, Len(Line) - 1);
        Sender.ClientMessage(Line);
        return;
    }

    PRI = GRI.PRIArray[HitIdx];
    PC = GetHumanPC(PRI);
    MainName = class'SmurfDB'.static.SanitizeName(PRI.PlayerName);   // the server's exact current spelling, ini/wire-safe
    idx = class'SmurfDB'.static.FindHash(PC.GetPlayerIDHash());
    if (idx < 0)
    {
        Sender.ClientMessage("[SmurfHunter] '" $ PRI.PlayerName $ "' has no stored record yet - try again in a moment");
        return;
    }

    Stamp = BuildStamp();
    NewRev = class'SmurfDB'.static.GetMainSet(idx) + 1;
    if (!class'SmurfDB'.static.ApplyMainChange(idx, MainName, NewRev, ServerID, Stamp))
    {
        Sender.ClientMessage("[SmurfHunter] '" $ MainName $ "' is already the Main for" @ PRI.PlayerName);
        return;
    }
    Log("[SmurfHunter] admin set Main for" @ PRI.PlayerName @ "to '" $ MainName $ "' (rev" @ NewRev $ ")");
    Sender.ClientMessage("[SmurfHunter] Main set for" @ PRI.PlayerName $ ": " $ MainName $ " (rev" @ NewRev $ ")");
    BroadcastMain(class'SmurfDB'.static.GetHash(idx), MainName, NewRev, ServerID, Stamp);
}

// v3.04: random 16-char lowercase hex node ID (64 bits of engine-RNG
// entropy - collision odds across a fleet are negligible; the RNG is
// process-seeded so nodes booting in the same second still diverge).
// Generated ONCE and persisted; stability comes from the ini, not the RNG.
function string GenerateServerID()
{
    local string S;
    local int i, D;

    S = "";
    for (i = 0; i < 16; i++)
    {
        D = Rand(16);
        if (D < 10)
            S = S $ string(D);
        else
            S = S $ Chr(D + 87);   // 'a'..'f'
    }
    return S;
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
    Sender.ClientMessage("[SmurfHunter] mutate smurfmainset <name> <password> - admin: set that player's Main identity (relays fleet-wide)");
    Sender.ClientMessage("[SmurfHunter] mutate smurfhelp - this list");
}

defaultproperties
{
    bCentralHub=False
    CentralHost=""
    CentralPort=9075
    CentralToken=""
    bFederate=False
    MainAdminPassword=""
    ServerID=""
}