// ===================================================================
// SmurfHunter - SmurfSayHandler  (v3.01)
// Chat-command front end: lets players type 'whois <partial name>',
// 'whoare' and 'smurfstats' as PLAIN CHAT TEXT - no 'mutate' prefix.
//
// Registered by MutSmurfHunter.PostBeginPlay into the engine's broadcast
// handler chain (Level.Game.BroadcastHandler.RegisterBroadcastHandler).
// The engine calls AcceptBroadcastText once per chat line per receiver;
// our verdict is identical for every receiver, but the command executes
// exactly ONCE - when the broadcast loop reaches the sender's own client
// (the sender is always among the receivers of their own message).
//
// Behavior:
//   - a line that parses as one of our commands: swallowed for EVERYONE
//     (return false - it never reaches other players' chat), and the
//     reply goes privately to the sender via ClientMessage;
//   - anything else: returned true untouched - normal chat is completely
//     unaffected;
//   - no Boss (mutator not yet spawned / removed): pure pass-through.
//
// Both say and team-say ride the same BroadcastText -> AcceptBroadcastText
// chain (verified against this engine build), so team-chat commands work
// identically.
//
// Cost: one string-prefix parse per chat line per receiver - nanoseconds,
// chat-triggered only. No per-tick work, no replication, no lag.
// ===================================================================

class SmurfSayHandler extends BroadcastHandler;

var MutSmurfHunter Boss;

function bool AcceptBroadcastText( PlayerController Receiver, PlayerReplicationInfo SenderPRI, out string Msg, optional name Type )
{
    local PlayerController SenderPC;
    local string Cmd, Arg;

    // not ours to manage: mutator gone, system broadcast, or no sender PRI
    if (Boss == None || Receiver == None || SenderPRI == None)
        return true;

    // engine-side broadcasts can carry a PRI whose Owner is not a
    // PlayerController - only real player chat can be a command
    SenderPC = PlayerController(SenderPRI.Owner);
    if (SenderPC == None)
        return true;

    if (!Boss.ParseChatCommand(Msg, Cmd, Arg))
        return true;

    // our command: swallow for every receiver, execute exactly once
    if (Receiver == SenderPC)
        Boss.RunCommand(SenderPC, Cmd, Arg);
    return false;
}

defaultproperties
{
}
