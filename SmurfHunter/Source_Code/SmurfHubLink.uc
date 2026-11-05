// ===================================================================
// SmurfHunter - SmurfHubLink  (v3.04)
// One instance per inbound connection, spawned by SmurfHubListener
// (TcpLink.AcceptClass). Handles authentication, input validation,
// merging, and relaying.
//
// Two authenticated link kinds:
//   - fleet spoke: "AUTH <CentralToken>" (exact match, case-sensitive)
//   - federation peer hub (v3): "AUTH <peerToken> LINKTYPE HUB" - the
//     token must match one of OUR FederationPeers[] entries (pairwise
//     secret) AND the source IP must match that entry's Host when Host
//     is a dotted IP. A DNS hostname falls back to token-only auth with
//     a logged warning. Wrong token or IP mismatch = immediate close.
//
// A REG that changes the DB is relayed to every OTHER link (spokes AND
// other peers) via RelayFederated - the sender already has it, spokes
// never relay, and relay fires only on change, so echo/mesh loops are
// structurally impossible.
//
// v3.04: a MAIN that changes the DB (MergeMain = revision-ordered
// last-writer-wins with a deterministic origin tiebreak, see SmurfDB)
// gets the identical treatment: merge locally, relay to every other
// link, rebuilt from the validated fields. An unapplied MAIN is never
// relayed - the same relay-on-change loop-breaker REG uses. MAIN lines
// ride AFTER the REG lines inside a full-sync block, so a node that
// lacks a record entirely has it by the time the record's MAIN arrives.
// ===================================================================

class SmurfHubLink extends TcpLink;

var MutSmurfHunter Hub;
var bool bAuthed;
var bool bPeerLink;     // v3: authenticated as a federation PEER HUB
var float ConnectTime;

function string RemoteIP()
{
    return IpAddrToString(RemoteAddr);
}

event Accepted()
{
    local MutSmurfHunter M;

    LinkMode = MODE_Line;   // cannot be set in defaultproperties

    if (Hub == None)        // fallback if the listener missed GainedChild
    {
        foreach DynamicActors(class'MutSmurfHunter', M)
        {
            Hub = M;
            break;
        }
    }
    if (Hub == None)
    {
        Log("[SmurfHunter] hub: accepted link but no MutSmurfHunter found - closing");
        Close();
        return;
    }
    ConnectTime = Level.TimeSeconds;
    Hub.RegisterLink(Self);
    Log("[SmurfHunter] hub: connection from" @ RemoteIP());
}

// v3: does the connection source match the configured peer address?
// Dotted IPs enforce the check (belt-and-suspenders beyond the firewall:
// a stolen token alone cannot connect from a foreign machine); a DNS
// hostname cannot be checked synchronously in UE2, so it degrades to
// token-only auth with a logged warning.
function bool PeerIPMatches(int PeerIdx)
{
    local IpAddr Expected;

    if (StringToIpAddr(Hub.FederationPeers[PeerIdx].Host, Expected))
        return (Expected.Addr == RemoteAddr.Addr);
    Log("[SmurfHunter] hub: peer Host '" $ Hub.FederationPeers[PeerIdx].Host $ "' is not a dotted IP - source-IP check skipped (token-only auth)");
    return true;
}

event ReceivedLine(string Line)
{
    local string Hash, Alias, Stamp, Payload, Rest, Token;
    local string Origin, MainName;
    local int Idx, PeerIdx, Rev;

    if (Hub == None)
        return;

    // ---- pre-auth: only AUTH allowed, everything else closes the link ----
    if (!bAuthed)
    {
        if (Left(Line, 5) == "AUTH ")
        {
            Rest = Mid(Line, 5);
            Idx = InStr(Caps(Rest), " LINKTYPE HUB");

            if (Idx >= 0)
            {
                // ---- v3 federation peer handshake ----
                Token = Left(Rest, Idx);
                PeerIdx = Hub.FindPeerByToken(Token);
                if (!Hub.bFederate || PeerIdx < 0)
                {
                    Log("[SmurfHunter] hub: unknown federation peer from" @ RemoteIP() $ " - closing");
                    Close();
                    return;
                }
                if (!PeerIPMatches(PeerIdx))
                {
                    Log("[SmurfHunter] hub: peer token valid but source IP mismatch from" @ RemoteIP() $ " - closing");
                    Close();
                    return;
                }
                bAuthed = true;
                bPeerLink = true;
                Log("[SmurfHunter] hub: PEER HUB authenticated from" @ RemoteIP());
                SendText("PUSH");   // request the peer's full DB (reconciliation)
                return;
            }

            if (Hub.CentralToken != "" && Rest == Hub.CentralToken)   // exact match, case-sensitive
            {
                bAuthed = true;
                Log("[SmurfHunter] hub: link authenticated from" @ RemoteIP());
                SendText("PUSH");   // request the spoke's full DB (reconciliation)
                return;
            }
        }
        Log("[SmurfHunter] hub: unauthorized traffic from" @ RemoteIP() $ " - closing");
        Close();
        return;
    }

    // ---- post-auth commands ----
    if (Left(Line, 4) ~= "REG ")
    {
        Payload = Mid(Line, 4);
        if (class'SmurfDB'.static.ParseRegPayload(Payload, Hash, Alias, Stamp))
        {
            if (class'SmurfDB'.static.Register(Hash, Alias, Stamp))
            {
                if (bPeerLink)
                    Log("[SmurfHunter] hub: new record from peer hub" @ RemoteIP() $ ":" @ Alias $ " - relaying");
                else
                    Log("[SmurfHunter] hub: new record from" @ RemoteIP() $ ":" @ Alias);
                Hub.RelayFederated("REG " $ Hash $ "," $ Alias $ "," $ Stamp, Self);
            }
        }
        else
            Log("[SmurfHunter] hub: rejected malformed REG from" @ RemoteIP() $ ": " $ Left(Payload, 80));
    }
    else if (Left(Line, 5) ~= "MAIN ")
    {
        Payload = Mid(Line, 5);
        if (class'SmurfDB'.static.ParseMainPayload(Payload, Hash, Rev, Origin, Stamp, MainName))
        {
            if (class'SmurfDB'.static.MergeMain(Hash, MainName, Rev, Origin, Stamp))
            {
                if (bPeerLink)
                    Log("[SmurfHunter] hub: Main change from peer hub" @ RemoteIP() $ ":" @ MainName $ " (rev" @ Rev $") - relaying");
                else
                    Log("[SmurfHunter] hub: Main change from" @ RemoteIP() $ ":" @ MainName $ " (rev" @ Rev $") - relaying");
                Hub.RelayFederated("MAIN " $ Hash $ "," $ Rev $ "," $ Origin $ "," $ Stamp $ "," $ MainName, Self);
            }
        }
        else
            Log("[SmurfHunter] hub: rejected malformed MAIN from" @ RemoteIP() $ ": " $ Left(Payload, 80));
    }
    else if (Line ~= "SYNC")
    {
        Hub.SendAllRecordsTo(Self);
    }
    else if (Left(Line, 6) ~= "BEGIN ")
    {
        class'SmurfDB'.static.BeginBulkSync();   // spoke's full DB follows as ordinary REG lines - one ini write for the whole block
    }
    else if (Line ~= "END")
    {
        class'SmurfDB'.static.EndBulkSync();
        Log("[SmurfHunter] hub: sync block complete from" @ RemoteIP() $ ", DB has" @ class'SmurfDB'.static.NumRecords() @ "record(s)");
    }
    // anything else: silently ignored
}

event Closed()
{
    class'SmurfDB'.static.EndBulkSync();   // safety flush if the link died mid-block
    if (Hub != None)
        Hub.UnregisterLink(Self);
    if (bAuthed && bPeerLink)
        Log("[SmurfHunter] hub: authenticated peer hub closed from" @ RemoteIP());
    else if (bAuthed)
        Log("[SmurfHunter] hub: authenticated link closed from" @ RemoteIP());
    else
        Log("[SmurfHunter] hub: unauthenticated link closed from" @ RemoteIP());
}

function Destroyed()
{
    if (Hub != None)
        Hub.UnregisterLink(Self);
}