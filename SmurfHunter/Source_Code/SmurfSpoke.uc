// ===================================================================
// SmurfHunter - SmurfSpoke  (v3)
// Outbound TcpLink client. Two roles:
//   - ordinary spoke: connects to OUR fleet's central hub (v2 behavior)
//   - federation mode (v3): connects to a PEER hub; auth carries
//     "LINKTYPE HUB" so the peer applies peer policy. A REG from the
//     peer that CHANGES the DB is relayed through the local hub's links
//     and our OTHER federation links (relay-on-change = the loop-breaker:
//     a record cycling back to a node that already has it dies instantly,
//     because Register() returns false and no relay fires).
// Spokes only ever make OUTBOUND connections - no inbound ports needed on
// hosted boxes (works on locked-down shared hosting like PingPerfect).
// The local DB is the durable state; remote nodes are convergence services.
// A spoke with NO SmurfDB.ini self-seeds: it connects empty, merges the
// hub's full DB (bulk mode = one ini write for the whole block), and its
// local file exists from that moment on.
// ===================================================================

class SmurfSpoke extends TcpLink;

var MutSmurfHunter Mut;
var bool bResolving;
var bool bFederation;   // v3: this link goes to a PEER HUB, not our own fleet hub
var string MyHost;      // v3: per-instance destination (a mutator may run many fed links)
var int MyPort;
var string MyToken;
var IpAddr HubAddr;

function bool ConnectTo(MutSmurfHunter M, string Host, int Port, string Token, optional bool bFed)
{
    Mut = M;
    bFederation = bFed;
    MyHost = Host;
    MyPort = Port;
    MyToken = Token;
    LinkMode = MODE_Line;

    // UE2 TcpLink client pattern: bind a local ephemeral port before Open()
    if (BindPort(0, true) == 0)
    {
        Log("[SmurfHunter]" @ RoleName() $ ": BindPort() failed - will retry");
        if (Mut != None)
            Mut.SpokeFailed(Self);
        return false;
    }

    if (StringToIpAddr(Host, HubAddr))   // dotted IP - instant
    {
        HubAddr.Port = Port;
        Log("[SmurfHunter]" @ RoleName() $ ": connecting to" @ Host $ ":" $ string(Port) $ "...");
        AttemptOpen();
        return true;
    }

    Log("[SmurfHunter]" @ RoleName() $ ": resolving address" @ Host $ "...");
    bResolving = true;
    Resolve(Host);                       // DNS name - async -> Resolved()/ResolveFailed()
    return true;
}

function string RoleName()
{
    if (bFederation)
        return "fed";
    return "spoke";
}

function AttemptOpen()
{
    if (!Open(HubAddr))
    {
        Log("[SmurfHunter]" @ RoleName() $ ": Open() failed - will retry");
        if (Mut != None)
            Mut.SpokeFailed(Self);
    }
}

event Resolved(IpAddr Addr)
{
    if (!bResolving)
        return;
    bResolving = false;
    HubAddr = Addr;
    HubAddr.Port = MyPort;
    Log("[SmurfHunter]" @ RoleName() $ ": resolved address, connecting to" @ MyHost $ ":" $ string(MyPort) $ "...");
    AttemptOpen();
}

event ResolveFailed()
{
    if (!bResolving)
        return;
    bResolving = false;
    Log("[SmurfHunter]" @ RoleName() $ ": could not resolve" @ MyHost $ " - will retry");
    if (Mut != None)
        Mut.SpokeFailed(Self);
}

event Opened()
{
    class'SmurfDB'.static.EndBulkSync();   // clear any stale bulk flag + flush
    if (bFederation)
    {
        Log("[SmurfHunter] fed: connected to peer hub" @ MyHost $ ":" $ string(MyPort) $ ", authenticating...");
        SendText("AUTH " $ MyToken $ " LINKTYPE HUB");   // v3 peer handshake
    }
    else
    {
        Log("[SmurfHunter] spoke: connected to hub" @ MyHost $ ":" $ string(MyPort) $ ", authenticating...");
        SendText("AUTH " $ MyToken);
    }
    SendText("SYNC");   // request the hub's full DB (hub requests ours via PUSH)
}

event ReceivedLine(string Line)
{
    local string Hash, Alias, Stamp, Payload;

    if (Left(Line, 4) ~= "REG ")
    {
        Payload = Mid(Line, 4);
        if (class'SmurfDB'.static.ParseRegPayload(Payload, Hash, Alias, Stamp))
        {
            if (class'SmurfDB'.static.Register(Hash, Alias, Stamp))
            {
                if (bFederation)
                {
                    // v3: a peer's record changed our DB -> relay to local hub
                    // links + our OTHER federation links. Already-known records
                    // never reach here, so mesh cycles die at the first hop.
                    Log("[SmurfHunter] fed: new record from peer hub:" @ Alias $ " - relaying");
                    if (Mut != None)
                        Mut.RelayFederated("REG " $ Hash $ "," $ Alias $ "," $ Stamp, Self);
                }
                else
                    Log("[SmurfHunter] spoke: merged record from hub:" @ Alias);
            }
        }
        else
            Log("[SmurfHunter]" @ RoleName() $ ": rejected malformed record: " $ Left(Payload, 80));
    }
    else if (Left(Line, 6) ~= "BEGIN ")
    {
        class'SmurfDB'.static.BeginBulkSync();   // one ini write for the whole block
    }
    else if (Line ~= "END")
    {
        class'SmurfDB'.static.EndBulkSync();
        Log("[SmurfHunter]" @ RoleName() $ ": sync block complete, DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    }
    else if (Line ~= "PUSH")
    {
        SendLocalRecords();
    }
}

event Closed()
{
    class'SmurfDB'.static.EndBulkSync();   // safety flush if the link died mid-block
    Log("[SmurfHunter]" @ RoleName() $ ": connection lost - will retry in 30s");
    if (Mut != None)
        Mut.SpokeFailed(Self);
}

// Send the complete local DB (hub asked for it via PUSH). Merge on the
// hub side is the same idempotent union, so duplicates/ordering are fine.
function SendLocalRecords()
{
    local int i, j;
    local array<string> Parts;

    SendText("BEGIN " $ string(class'SmurfDB'.static.NumRecords()));
    for (i = 0; i < class'SmurfDB'.static.NumRecords(); i++)
    {
        Parts.Length = 0;
        Split(class'SmurfDB'.static.GetAliases(i), ",", Parts);
        for (j = 0; j < Parts.Length; j++)
            SendText("REG " $ class'SmurfDB'.static.GetHash(i) $ "," $ Parts[j] $ "," $ class'SmurfDB'.static.GetFirstSeen(i));
    }
    SendText("END");
    Log("[SmurfHunter]" @ RoleName() $ ": pushed" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
}

// Delta push for a locally-recorded change (fire-and-forget; if the link
// is down the record still lives safely in the local DB = the outbox,
// and reconciliation on reconnect delivers it).
function SendRecord(string Hash, string Alias, string Stamp)
{
    SendText("REG " $ Hash $ "," $ Alias $ "," $ Stamp);
}
