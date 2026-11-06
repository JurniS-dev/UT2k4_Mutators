// ===================================================================
// SmurfHunter - SmurfDB  (v3.07)
// Persistent alias registry: one record per unique CD-key hash with a
// comma-joined alias list and first-seen stamp.
//
// v3.06 DURABLE STORAGE CODEC (C1) + AUTO-REPAIR (public v1.4.2):
// The engine's ini reader strips raw backslashes from config string values
// (live-probe verified 2026-11-05: stored escaped values decay ~2s after
// every save, and the file follows on the next write). Backslash names could
// therefore never persist. Codec changes (all inside this class):
//   - ToStorage():   '\' -> %5C  (lax URL-style; nothing else is encoded, so
//     plain names stay byte-identical in the ini).
//   - FromStorage(): exact-case %5C -> '\' decode.
//   - AliasKey():    decodes FIRST, so canonical, stored and legacy plain
//     spellings all compare alike (HasAlias/IsIgnored/FindByAlias/
//     RemoveAliasKey/ScrubDuplicates inherit this).
// The wire format is unchanged (canonical names on every REG/MAIN line) and
// existing plain-form DBs load as-is; only repaired/merged backslash
// entries carry %5C. Lax trade-off (accepted): a name containing the literal
// uppercase sequence "%5C" decodes with a backslash.
// Register()'s no-op branch also auto-repairs a stored spelling whose
// backslashes were lost when the live name still carries them - durable
// under the codec, firing at most once per spelling, relaying as a normal
// DB change.
//
// v3.05 WHOIS MAIN SEARCH (public v1.4.1 - fixes v1.4.0):
// FindByAlias() now also matches against each record's Main, so records
// whose alias list is EMPTY but whose Main is known (curated seed rows,
// Main-only records) still resolve for offline 'mutate whois <name>'.
// Exactly one caller (whois route 2), so capture/dedup/sync semantics are
// untouched. Identity stays in Main, history stays in Aliases - the Main
// spelling is still never copied into the alias list, and the whois
// display still filters the Main out of "Also seen as" as before.
//
// v3.04 MAIN IDENTITY:
// Every record grows a Main (who the player IS) alongside the alias
// history (names they have worn). Merge is deliberately NOT a union:
// Main is a single mutable value that must converge fleet-wide, and the
// fleet spans timezones with untrustworthy wall clocks, so ordering uses
// a Lamport-style revision counter instead of timestamps:
//   - MainSet: per-record revision. 0 = seeded (oldest alias, never
//     admin-set). Each admin change takes (highest seen)+1; adopting any
//     remote revision ratchets the floor, so counters never fork.
//   - MainOrigin: ServerID of the node that made the change. Equal-rev
//     conflicts (true concurrent edits) resolve by the IDENTICAL rule on
//     every node: the lexicographically SMALLER origin wins (case-
//     sensitive compare). Conflicts are logged, never silent.
//   - MainStamp: display-only local-time stamp (shown in whois, NEVER
//     compared - the ordering authority is MainSet/MainOrigin).
// Seeds never travel: only rev >= 1 Mains are relayed or full-synced.
// On admin set the retired Main is pushed into the alias list and the
// new Main's spelling is carved out of it (storage stays canonical);
// whois display also filters the Main's spelling defensively.
// Wire: "MAIN <hash>,<rev>,<origin>,<stamp>,<main>" - main rides LAST so
// it can never reorder fields, and lines are relayed only on change
// (the same loop-breaker REG uses). MAIN for a hash this node lacks is
// ignored: the record arrives via the alias union sync and the Main via
// the next full sync.
//
// v3.03 BACKSLASH-SAFE STORAGE:
// UE2.5 writes config strings to the ini RAW, but its ini text parser
// processes backslash escape sequences on import: "\\" -> "\", and a
// LONE "\X" loses the backslash entirely ("De\\mo`" imports as
// "Demo`"). Any alias containing a backslash therefore never
// survived a config round-trip, so HasAlias() never matched the live
// name again and Register() re-appended the same alias on every capture
// (one production name accumulated 199 copies). Fix, applied at the
// storage boundary so every caller stays simple:
//   - ToStorage():   backslashes doubled before anything enters Records[]
//   - FromStorage(): pairs collapsed back for display + wire (REG lines)
//   - AliasKey():    case-insensitive, backslash-blind compare key used by
//                    HasAlias()/FindByAlias()/IsIgnored(), so both storage
//                    forms (pre-save doubled / post-import single) compare
//                    equal and corrupted legacy entries still dedup
//   - ScrubDuplicates(): startup heal for already-corrupted DBs
// The same boundary applies to Main (v3.04): stored escaped, display
// and wire canonical (single backslash).
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
    var string Main;      // v3.04: canonical identity (STORAGE form - ToStorage-escaped)
    var int    MainSet;   // v3.04: Lamport revision; 0 = seeded, never admin-set
    var string MainOrigin;// v3.04: ServerID of the node that last set Main ("" while rev 0)
    var string MainStamp;// v3.04: display-only stamp ("YYYY-MM-DD hh:mm", never compared)
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

// v3.04: Main accessors. GetMain returns the STORAGE form (escaped) -
// display and wire callers pass it through FromStorage().
static function string GetMain(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].Main;
}

static function int GetMainSet(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return 0;
    return default.Records[i].MainSet;
}

static function string GetMainOrigin(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].MainOrigin;
}

static function string GetMainStamp(int i)
{
    if (i < 0 || i >= default.Records.Length)
        return "";
    return default.Records[i].MainStamp;
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
        if (Ch == "\\")
            Result = Result $ "%5C";   // v3.06 C1 codec: the engine's ini reader strips raw backslashes; %5C survives (live-probe verified 2026-11-05)
        else
            Result = Result $ Ch;
    }
    return Result;
}

static function string FromStorage(string S)
{
    local string Result, Tri;
    local int i;

    for (i = 0; i < Len(S); i++)
    {
        Tri = Mid(S, i, 3);
        if (Tri == "%5C")   // exact case - the encoder always writes uppercase (lax scheme)
        {
            Result = Result $ "\\";
            i += 2;   // consume the full 3-char sequence
        }
        else
            Result = Result $ Mid(S, i, 1);
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
    S = FromStorage(S);   // v3.06: stored values carry %5C - decode so canonical, stored and legacy plain spellings all key alike
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
// v3.04: a NEW record's Main starts as its first alias (seed, rev 0).
static function bool Register(string H, string Name, string Stamp)
{
    local PlayerRecord R;
    local int idx, i, j;
    local array<string> Parts;
    local string Key, NewList;

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
        R.Aliases = ToStorage(Name);   // v3.06: %5C codec at the storage boundary
        R.FirstSeen = Stamp;
        R.Main = R.Aliases;            // v3.04: seed Main = first alias (storage form)
        R.MainSet = 0;                 // v3.04: rev 0 = seeded, never admin-set
        R.MainOrigin = "";
        R.MainStamp = "";
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

    // v3.06: stored-spelling auto-repair. The match above is backslash-blind,
    // so a known player can arrive carrying a spelling whose backslashes were
    // lost from the stored entry (the engine's ini reader strips raw
    // backslashes; stored 'SamSlash`' vs live 'Sam\Slash`). If the live name
    // keeps backslashes the stored spelling lost, rewrite that one stored
    // entry with the faithful live spelling - DURABLE under the C1 codec
    // (stored as %5C), so the repair survives saves, reboots and syncs, and
    // fires at most once per spelling.
    if (InStr(Name, "\\") >= 0)
    {
        Key = AliasKey(Name);
        Parts.Length = 0;
        Split(default.Records[idx].Aliases, ",", Parts);
        for (i = 0; i < Parts.Length; i++)
        {
            if (AliasKey(Parts[i]) == Key && InStr(FromStorage(Parts[i]), "\\") < 0)
            {
                Parts[i] = ToStorage(Name);
                NewList = "";
                for (j = 0; j < Parts.Length; j++)
                {
                    if (NewList != "")
                        NewList = NewList $ ",";
                    NewList = NewList $ Parts[j];
                }
                default.Records[idx].Aliases = NewList;
                if (!default.bBulkSync)
                    StaticSaveConfig();
                return true;
            }
        }
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
                    // prefer the spelling that still carries its backslash (%5C in stored form)
                    if (InStr(Keep[k], "%5C") < 0 && InStr(Parts[j], "%5C") >= 0)
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

// ----------------------- v3.04: Main identity engine -----------------------

// v3.04: rebuild an alias list without every entry whose AliasKey matches
// Key (used to carve the Main's spelling out of the alias history).
static function string RemoveAliasKey(string AliasList, string Key)
{
    local array<string> Parts;
    local string NewList;
    local int i;

    if (AliasList == "" || Key == "")
        return AliasList;
    Parts.Length = 0;
    Split(AliasList, ",", Parts);
    NewList = "";
    for (i = 0; i < Parts.Length; i++)
    {
        if (Parts[i] == "" || AliasKey(Parts[i]) == Key)
            continue;
        if (NewList != "")
            NewList = NewList $ ",";
        NewList = NewList $ Parts[i];
    }
    return NewList;
}

// v3.04: ServerID wire/storage safety - letters, digits and dash only,
// non-empty, max 32 chars (a space or comma would break every CSV wire
// line the ID rides on; this runs on config load AND on every inbound
// MAIN line).
static function bool SafeServerID(string S)
{
    local int i;
    local string C;

    if (S == "" || Len(S) > 32)
        return false;
    for (i = 0; i < Len(S); i++)
    {
        C = Mid(S, i, 1);
        if (!((C >= "A" && C <= "Z") || (C >= "a" && C <= "z") || (C >= "0" && C <= "9") || C == "-"))
            return false;
    }
    return true;
}

// v3.04: core Main mutation, shared by the local admin command (rev =
// current+1, origin = our ServerID, stamp = now) and the wire merge (the
// wire's triple verbatim). NewMain arrives SANITIZED + CANONICAL
// (single-backslash) and is stored through ToStorage.
// Alias surgery runs ONLY when the identity actually changes (keys
// differ): the retired Main is pushed into the alias list and the new
// Main's spelling is carved out of it. A pure respelling (same key, new
// casing) just updates Main - no list churn, history preserved.
// Returns true if anything changed (caller relays + the ini is saved,
// deferred during bulk sync like Register()).
static function bool ApplyMainChange(int idx, string NewMain, int Rev, string Origin, string Stamp)
{
    local string OldMain, OldList, Key, Stored;
    local bool bChanged;

    if (idx < 0 || idx >= default.Records.Length)
        return false;
    NewMain = SanitizeName(NewMain);
    if (NewMain == "" || Len(NewMain) > 64)
        return false;

    Stored = ToStorage(NewMain);
    OldMain = FromStorage(default.Records[idx].Main);
    Key = AliasKey(NewMain);
    OldList = default.Records[idx].Aliases;

    if (Key != AliasKey(OldMain))
    {
        if (OldMain != "" && !HasAlias(OldList, OldMain))
        {
            if (OldList == "")
                OldList = ToStorage(OldMain);
            else
                OldList = OldList $ "," $ ToStorage(OldMain);
        }
        OldList = RemoveAliasKey(OldList, Key);
    }

    if (OldList != default.Records[idx].Aliases)
    {
        default.Records[idx].Aliases = OldList;
        bChanged = true;
    }
    if (default.Records[idx].Main != Stored || default.Records[idx].MainSet != Rev
        || default.Records[idx].MainOrigin != Origin || default.Records[idx].MainStamp != Stamp)
    {
        default.Records[idx].Main = Stored;
        default.Records[idx].MainSet = Rev;
        default.Records[idx].MainOrigin = Origin;
        default.Records[idx].MainStamp = Stamp;
        bChanged = true;
    }

    if (bChanged && !default.bBulkSync)
        StaticSaveConfig();
    return bChanged;
}

// v3.04: wire merge for MAIN lines - last-writer-wins by Lamport revision
// with a deterministic origin tiebreak (see header). Rev 0 never travels,
// so a wire Main is always an admin-set value. Returns true if the DB
// changed (caller relays). MAIN for a hash we do not have yet is ignored:
// the record arrives via the alias union sync, the Main via the next full
// sync (the same reconciliation that heals every other field).
static function bool MergeMain(string H, string NewMain, int Rev, string Origin, string Stamp)
{
    local int idx, CurrRev;
    local string CurrOrigin;

    if (Rev <= 0)
        return false;
    idx = FindHash(H);
    if (idx < 0)
    {
        Log("[SmurfHunter] DB: MAIN for unknown hash" @ Left(H, 8) $ " - ignored (adopted at the next full sync)");
        return false;
    }

    CurrRev = default.Records[idx].MainSet;
    CurrOrigin = default.Records[idx].MainOrigin;

    if (Rev < CurrRev)
        return false;   // we hold newer state; the peer learns from our full sync
    if (Rev == CurrRev)
    {
        if (Origin == CurrOrigin)
            return false;   // exact duplicate of what we already hold
        if (Origin > CurrOrigin)
        {
            Log("[SmurfHunter] DB: MAIN conflict on" @ Left(H, 8) $ ": kept origin '" $ CurrOrigin $ "', dropped '" $ Origin $ "' (equal rev" @ CurrRev $")");
            return false;
        }
        Log("[SmurfHunter] DB: MAIN conflict on" @ Left(H, 8) $ ": adopting origin '" $ Origin $ "' over '" $ CurrOrigin $ "' (equal rev" @ CurrRev $")");
    }
    return ApplyMainChange(idx, NewMain, Rev, Origin, Stamp);
}

// v3.04: startup seed - give every record a Main if it has none yet (a
// fresh v3.04 boot on an older ini). Main = oldest known alias, rev 0 =
// seeded/never-admin-set: seeds are local-only (never relayed, never
// merged), so curated and auto-seeded values can never conflict.
// No alias surgery here on purpose: seeds must not rewrite history; the
// whois display filters the Main's spelling out of the alias list instead.
// Records with an empty alias list stay Main-less until an admin sets one.
static function int SeedMissingMains()
{
    local array<string> Parts;
    local int i, Seeded;

    for (i = 0; i < default.Records.Length; i++)
    {
        if (default.Records[i].Main != "" || default.Records[i].Aliases == "")
            continue;
        Parts.Length = 0;
        Split(default.Records[i].Aliases, ",", Parts);
        if (Parts.Length == 0 || Parts[0] == "")
            continue;
        default.Records[i].Main = Parts[0];   // already in storage form
        default.Records[i].MainSet = 0;
        default.Records[i].MainOrigin = "";
        default.Records[i].MainStamp = "";
        Seeded++;
    }
    if (Seeded > 0)
    {
        StaticSaveConfig();
        Log("[SmurfHunter] DB: seeded Main for" @ Seeded @ "record(s) (oldest alias, rev 0)");
    }
    return Seeded;
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
// 'De\\mo`' and vice versa.
// v3.05: Main is searched too, through the SAME AliasKey pipeline. A
// record whose alias list is empty but whose Main is set (curated seed
// rows) resolves offline; a Main hit alone never touches the alias
// list (identity lives in Main, history in Aliases - no duplication).
// Returns match count, fills Matches with record indices.
static function int FindByAlias(string Name, out array<int> Matches)
{
    local array<string> Parts;
    local int i, j;
    local string Needle, MainKey;

    Matches.Length = 0;
    Needle = AliasKey(Name);
    if (Needle == "")
        return 0;

    for (i = 0; i < default.Records.Length; i++)
    {
        // v3.05: Main is the canonical identity - searchable exactly like
        // an alias. AliasKey strips backslashes, so the storage escaping
        // (ToStorage) is irrelevant on both sides of the compare.
        MainKey = AliasKey(default.Records[i].Main);
        if (MainKey != "" && InStr(MainKey, Needle) >= 0)
        {
            Matches[Matches.Length] = i;
            continue;
        }
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
// and (v3.04) one Main state change per line:
//     MAIN <hash>,<rev>,<origin>,<stamp>,<main>
// These validators run on EVERY inbound line, whether from a spoke or
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

// v3.04: Payload = '<hash>,<rev>,<origin>,<stamp>,<main>' (everything
// after 'MAIN '). The main rides LAST so it can never reorder fields
// (SanitizeName already strips commas today - this is belt and
// suspenders). Rev must be >= 1 (rev 0 = seed, seeds never travel).
// Returns true + fills outputs only if the payload is fully valid.
static function bool ParseMainPayload(string Payload, out string Hash, out int Rev, out string Origin, out string Stamp, out string MainName)
{
    local array<string> F;
    local int i;

    F.Length = 0;
    Split(Payload, ",", F);
    if (F.Length < 5)
        return false;
    if (!ValidHash(F[0]))
        return false;
    Rev = int(F[1]);   // UE2 int() on garbage is 0 -> rejected by the Rev check
    if (Rev <= 0)
        return false;
    if (!SafeServerID(F[2]))
        return false;
    if (F[3] != "" && !SafeStamp(F[3]))
        return false;
    MainName = F[4];
    for (i = 5; i < F.Length; i++)   // defensive: rejoin any stray commas
        MainName = MainName $ "," $ F[i];
    MainName = SanitizeName(MainName);
    if (MainName == "" || Len(MainName) > 64)
        return false;
    Hash = F[0];
    Origin = F[2];
    Stamp = F[3];
    return true;
}