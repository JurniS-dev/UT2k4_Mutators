// ===================================================================
// SmurfHunter - SmurfDB  (v3.03)
// Persistent alias registry: one record per unique CD-key hash with a
// comma-joined alias list and first-seen stamp.
//
// v3.03 BACKSLASH-SAFE STORAGE:
// UE2.5 writes config strings to the ini RAW, but its ini text parser
// processes backslash escape sequences on import: "\\" -> "\", and a
// LONE "\X" loses the backslash entirely ("De\mo`" imports as
// "Demo`"). Any alias containing a backslash therefore never
// survived a config round-trip, so HasAlias() never matched the live
// name again and Register() re-appended the same alias on every capture
// (one production name accumulated 199 copies). Fix, applied at the storage
// boundary so every caller stays simple:
//   - ToStorage():   backslashes doubled before anything enters Records[]
//   - FromStorage(): pairs collapsed back for display + wire (REG lines)
//   - AliasKey():    case-insensitive, backslash-blind compare key used by
//                    HasAlias()/FindByAlias()/IsIgnored(), so both storage
//                    forms (pre-save doubled / post-import single) compare
//                    equal and corrupted legacy entries still dedup
//   - ScrubDuplicates(): startup heal for already-corrupted DBs
// Storage: <user dir>/System/SmurfDB.ini  (config system = the only
// read+write file API in UnrealScript). Whole-file rewrite happens ONLY
// on change. Merge semantics are an idempotent set-union keyed on the
// hash, which is what makes hub sync + v3 federation conflict-free and
// self-healing (reconnect = full reconciliation).
//
// v2.02 ignore lists (same ini, this section):
//   IgnoredHashes=...  records with these hashes are never stored
//   IgnoredNames=...  records carrying these aliases are never stored
// Register() is the SINGLE choke point - local capture, spoke inbound,
// hub inbound and federation relay ALL pass through it, so an ignored
// identity can never enter (or re-enter) from ANY source. A startup
// scrub (ScrubIgnored) removes records already on disk, so a remote
// node still holding the record cannot resurrect it through union merge.
// ===================================================================

class SmurfDB extends Object config(SmurfDB);

struct PlayerRecord
{
    var string Hash;      // PlayerController.GetPlayerIDHash() - stable CD-key GUID hash
    var string Aliases;   // comma-joined unique names (sanitized), oldest first
    var string FirstSeen; // YYYY-MM-DD hh:mm (server local time) or a seed label
};

var config array<PlayerRecord> Records;

// v2.02 ignore lists: validated identically against local captures and
// every inbound record, whatever its source (own spoke, peer hub, relay).
var config array<string> IgnoredHashes;
var config array<string> IgnoredNames;

var bool bBulkSync;      // true while a BEGIN..END full-DB block is merging
var int IgnoredDuringBulk;  // ignored records counted during a sync block

// ------------------------- name sanitization -------------------------

// Normalize a player name for storage AND search (applied identically at
// both ends so matching is symmetric):
//   - commas become spaces      (comma is the alias-list delimiter)
//   - quotes + control chars    (incl. color-code ESC) are dropped so the
//                                ini line can never be corrupted by symbols
//   - outer spaces trimmed
// All matching on top of this is case-INSENSITIVE everywhere (~= / Caps()),
// so 'mutate WHOIS bob', 'mutate whois BOB' etc. are all equivalent.
// ALSO: commas never survive, so a REG sync line's comma-separated fields
// can never be corrupted by name symbols (sync safety depends on this).
static function string SanitizeName(string S)
{
    local string Result, Ch;
    local int i;

    for (i = 0; i < Len(S); i++)
    {
        Ch = Mid(S, i, 1);
        if (Ch == ",")
            Result = Result $ " ";
        else if (Asc(Ch) >= 32 && Asc(Ch) != 34)
            Result = Result $ Ch;
    }
    while (Left(Result, 1) == " " && Result != "")
        Result = Mid(Result, 1);
    while (Right(Result, 1) == " " && Result != "")
        Result = Left(Result, Len(Result) - 1);
    return Result;
}

// --------------------------- record access ----------------------------

static function int NumRecords()
{
    return default.Records.Length;
}

static function string GetHash(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].Hash;
}

static function string GetAliases(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].Aliases;
}

static function string GetFirstSeen(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].FirstSeen;
}

static function int FindHash(string H)
{
    local int i;
    if (H == "")
        return -1;
    for (i = 0; i < default.Records.Length; i++)
        if (default.Records[i].Hash ~= H)
            return i;
    return -1;
}

// v3.03: storage-boundary escapes (see header note). Everything going
// INTO Records[] passes ToStorage(); everything coming OUT for display
// or wire passes FromStorage(); every comparison uses AliasKey().
static function string ToStorage(string S)
{
    local string Result, Ch;
    local int i;

    for (i = 0; i < Len(S); i++)
    {
        Ch = Mid(S, i, 1);
        Result = Result $ Ch;
        if (Ch == "\\")
            Result = Result $ "\\";   // double it so the ini parser round-trips it
    }
    return Result;
}

static function string FromStorage(string S)
{
    local string Result, Ch;
    local int i;

    for (i = 0; i < Len(S); i++)
    {
        Ch = Mid(S, i, 1);
        if (Ch == "\\")
        {
            Result = Result $ "\\";
            if (i + 1 < Len(S) && Mid(S, i + 1, 1) == "\\")
                i++;   // collapse the pair; a lone backslash is kept as-is
        }
        else
            Result = Result $ Ch;
    }
    return Result;
}

// Canonical compare key: sanitized, backslashes stripped, case-folded.
// Backslash-blind by design - names differing only by backslashes are
// the same identity for smurf-hunting purposes, and this keeps dedup
// correct for both in-memory forms (pre-save doubled, post-import single)
// and for legacy entries whose backslash the parser already ate.
static function string AliasKey(string S)
{
    local string Result, Ch;
    local int i;

    S = SanitizeName(S);
    for (i = 0; i < Len(S); i++)
    {
        Ch = Mid(S, i, 1);
        if (Ch != "\\")
            Result = Result $ Ch;
    }
    return Caps(Result);
}

static function bool HasAlias(string AliasList, string Name)
{
    local array<string> Parts;
    local string Key;
    local int i;
    if (AliasList == "" || Name == "")
        return false;
    Key = AliasKey(Name);
    if (Key == "")
        return false;
    Parts.Length = 0;
    Split(AliasList, ",", Parts);
    for (i = 0; i < Parts.Length; i++)
        if (AliasKey(Parts[i]) == Key)
            return true;
    return false;
}

// v2.02: does this hash / any of these aliases sit on an ignore list?
// Hash comparison is exact-fold; names are sanitized both sides so the
// ignore list behaves identically against live captures and wire records.
static function bool IsIgnored(string H, string AliasList)
{
    local int i, j;
    local array<string> Parts;

    if (H != "")
    {
        for (i = 0; i < default.IgnoredHashes.Length; i++)
            if (default.IgnoredHashes[i] != "" && default.IgnoredHashes[i] ~= H)
                return true;
    }
    if (AliasList != "" && default.IgnoredNames.Length > 0)
    {
        Parts.Length = 0;
        Split(AliasList, ",", Parts);
        for (i = 0; i < Parts.Length; i++)
        {
            for (j = 0; j < default.IgnoredNames.Length; j++)
                if (default.IgnoredNames[j] != "" && AliasKey(default.IgnoredNames[j]) == AliasKey(Parts[i]))
                    return true;
        }
    }
    return false;
}

// Returns true if the DB changed. New hash = new record; known hash with a
// new name = alias appended. No change = no write, no disk touch.
// FirstSeen is NEVER overwritten for an existing record (first writer wins).
// During bulk-sync blocks the ini write is deferred (one flush per block).
// Ignore-listed identities are rejected here - the single choke point.
static function bool Register(string H, string Name, string Stamp)
{
    local PlayerRecord R;
    local int idx;

    if (H == "")
        return false;
    Name = SanitizeName(Name);
    if (Name == "")
        return false;

    // v2.02: filter every source identically (local capture, spoke inbound,
    // hub inbound, federation relay). Rejected records never touch the DB,
    // so they are never relayed either (relay fires only on DB change).
    if (IsIgnored(H, Name))
    {
        if (default.bBulkSync)
            default.IgnoredDuringBulk++;
        else
            Log("[SmurfHunter] DB: rejected record on the ignore list (alias:" @ Name $")");
        return false;
    }

    idx = FindHash(H);
    if (idx < 0)
    {
        R.Hash = H;
        R.Aliases = ToStorage(Name);   // v3.03: escape at the storage boundary
        R.FirstSeen = Stamp;
        default.Records[default.Records.Length] = R;
        if (!default.bBulkSync)
            StaticSaveConfig();
        return true;
    }
    if (!HasAlias(default.Records[idx].Aliases, Name))
    {
        if (default.Records[idx].Aliases == "")
            default.Records[idx].Aliases = ToStorage(Name);
        else
            default.Records[idx].Aliases = default.Records[idx].Aliases $ "," $ ToStorage(Name);
        if (!default.bBulkSync)
            StaticSaveConfig();
        return true;
    }
    return false;
}

// v2.02: startup scrub - removes already-stored records matching the
// ignore lists. Without this, union-merge with a remote node still
// holding the record would resurrect it; with it, Register() blocks
// re-entry at the choke point. Match = hash on IgnoredHashes OR ANY
// stored alias on IgnoredNames (a name match removes the whole record:
// ignore lists are for junk identities, not for pruning one alias).
// Called once from MutSmurfHunter.PostBeginPlay, before any sync runs.
static function int ScrubIgnored()
{
    local int i, Removed;

    for (i = default.Records.Length - 1; i >= 0; i--)
    {
        if (IsIgnored(default.Records[i].Hash, default.Records[i].Aliases))
        {
            default.Records.Remove(i, 1);
            Removed++;
        }
    }
    if (Removed > 0)
    {
        StaticSaveConfig();
        Log("[SmurfHunter] DB scrub: removed" @ Removed @ "record(s) matching the ignore lists");
    }
    return Removed;
}

// v3.03: startup heal for DBs corrupted by the backslash round-trip bug
// (dup aliases accumulated per capture). Each record's alias list is
// deduped through AliasKey(); per duplicate group the most faithful
// spelling is kept (the one still carrying its backslash); survivors are
// re-stored through the escaping boundary. One ini write if anything
// changed. Called once from MutSmurfHunter.PostBeginPlay, after
// ScrubIgnored(), before any sync runs.
static function int ScrubDuplicates()
{
    local array<string> Parts, Keep, KeepKeys;
    local string Part, Key, NewList;
    local int i, j, k, Healed;
    local bool bFound;

    for (i = 0; i < default.Records.Length; i++)
    {
        Parts.Length = 0;
        Split(default.Records[i].Aliases, ",", Parts);
        Keep.Length = 0;
        KeepKeys.Length = 0;

        for (j = 0; j < Parts.Length; j++)
        {
            if (Parts[j] == "")
                continue;
            Key = AliasKey(Parts[j]);
            if (Key == "")
                continue;
            bFound = false;
            for (k = 0; k < KeepKeys.Length; k++)
            {
                if (KeepKeys[k] == Key)
                {
                    bFound = true;
                    // prefer the spelling that still carries its backslash
                    if (InStr(Keep[k], "\\") < 0 && InStr(Parts[j], "\\") >= 0)
                        Keep[k] = Parts[j];
                    break;
                }
            }
            if (!bFound)
            {
                Keep[Keep.Length] = Parts[j];
                KeepKeys[KeepKeys.Length] = Key;
            }
        }

        NewList = "";
        for (j = 0; j < Keep.Length; j++)
        {
            Part = ToStorage(FromStorage(Keep[j]));   // idempotent re-escape
            if (Part == "")
                continue;
            if (NewList != "")
                NewList = NewList $ ",";
            NewList = NewList $ Part;
        }

        if (NewList != default.Records[i].Aliases)
        {
            default.Records[i].Aliases = NewList;
            Healed++;
        }
    }

    if (Healed > 0)
    {
        StaticSaveConfig();
        Log("[SmurfHunter] DB scrub: healed" @ Healed @ "record(s) with duplicate or escape-unsafe aliases");
    }
    return Healed;
}

// Enter/leave bulk mode around a BEGIN..END block. EndBulkSync flushes the
// single ini write for everything merged during the block (also used as a
// safety flush if a link dies mid-block).
static function BeginBulkSync()
{
    default.bBulkSync = true;
}

static function EndBulkSync()
{
    if (default.bBulkSync)
    {
        default.bBulkSync = false;
        StaticSaveConfig();   // one write for the whole block
        if (default.IgnoredDuringBulk > 0)
        {
            Log("[SmurfHunter] DB: rejected" @ default.IgnoredDuringBulk @ "ignored record(s) during the sync block");
            default.IgnoredDuringBulk = 0;
        }
    }
}

// Case-insensitive partial match over every stored alias. v3.03: both
// sides go through AliasKey() (backslash-blind) so 'whois Demo' finds
// 'De\mo`' and vice versa.
// Returns match count, fills Matches with record indices.
static function int FindByAlias(string Name, out array<int> Matches)
{
    local array<string> Parts;
    local int i, j;
    local string Needle;

    Matches.Length = 0;
    Needle = AliasKey(Name);
    if (Needle == "")
        return 0;

    for (i = 0; i < default.Records.Length; i++)
    {
        Parts.Length = 0;
        Split(default.Records[i].Aliases, ",", Parts);
        for (j = 0; j < Parts.Length; j++)
            if (InStr(AliasKey(Parts[j]), Needle) >= 0)
            {
                Matches[Matches.Length] = i;
                break;
            }
    }
    return Matches.Length;
}

// --------------------- sync: line parsing + input validation -------
// The wire format is one alias per line:
//     REG <hash>,<alias>,<stamp>
// These validators run on EVERY inbound record, whether from a spoke or
// a peer hub (never trust the socket, even authenticated peers). A rejected
// line never touches the DB. Validation is layer 3 of the security model
// (1 = hub firewall allowlist, 2 = tokens, 3 = this).

static function bool IsHexDigit(string C)
{
    return (C >= "0" && C <= "9") || (C >= "a" && C <= "f") || (C >= "A" && C <= "F");
}

static function bool ValidHash(string H)
{
    local int i;
    if (Len(H) != 32)
        return false;
    for (i = 0; i < 32; i++)
        if (!IsHexDigit(Mid(H, i, 1)))
            return false;
    return true;
}

// Stamp must be ini-safe AND line-safe: no control chars, no quotes, no
// commas. Freeform text allowed otherwise (seed labels like 'pre-seeded'
// pass). Length capped.
static function bool SafeStamp(string S)
{
    local int i;
    local string C;

    if (S == "" || Len(S) > 32)
        return false;
    for (i = 0; i < Len(S); i++)
    {
        C = Mid(S, i, 1);
        if (Asc(C) < 32 || Asc(C) == 34 || C == ",")
            return false;
    }
    return true;
}

// Payload = '<hash>,<alias>,<stamp>' (everything after 'REG ').
// Returns true + fills outputs only if the payload is fully valid.
static function bool ParseRegPayload(string Payload, out string Hash, out string Alias, out string Stamp)
{
    local array<string> F;

    F.Length = 0;
    Split(Payload, ",", F);
    if (F.Length != 3)
        return false;
    if (!ValidHash(F[0]))
        return false;
    Alias = SanitizeName(F[1]);
    if (Alias == "" || Len(Alias) > 64)
        return false;
    if (!SafeStamp(F[2]))
        return false;
    Hash = F[0];
    Stamp = F[2];
    return true;
}
