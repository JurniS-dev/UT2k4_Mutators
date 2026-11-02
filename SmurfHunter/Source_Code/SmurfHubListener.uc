// ===================================================================
// SmurfHunter - SmurfHubListener  (v3)
// The hub's inbound TCP listener. Binds CentralPort, listens, and lets
// TcpLink.AcceptClass spawn one SmurfHubLink per inbound connection
// (fleet spokes AND v3 federation peer hubs - SmurfHubLink tells them
// apart at auth time), keeping the listener open for the next link.
// GainedChild hands each spawned link its MutSmurfHunter reference
// (set before any data can arrive on it).
// ===================================================================

class SmurfHubListener extends TcpLink;

var MutSmurfHunter Hub;

function bool StartListen(int Port, MutSmurfHunter M)
{
    Hub = M;
    LinkMode = MODE_Line;
    AcceptClass = class'SmurfHubLink';

    if (BindPort(Port, false) == 0)
    {
        Log("[SmurfHunter] hub: failed to bind TCP port" @ Port);
        return false;
    }
    if (!Listen())
    {
        Log("[SmurfHunter] hub: Listen() failed on TCP port" @ Port);
        return false;
    }
    Log("[SmurfHunter] hub: listening on TCP" @ Port);
    return true;
}

// Fires when the native accept spawns a SmurfHubLink child.
event GainedChild(Actor C)
{
    if (SmurfHubLink(C) != None)
    {
        SmurfHubLink(C).Hub = Hub;
        SmurfHubLink(C).LinkMode = MODE_Line;   // set before any data arrives
    }
}
