using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PowerTools.Core;

public sealed record HistoryEntry(long Id, string Timestamp, string App, string Raw, string Polished, int DurationMs);
public sealed record DictEntry(string Term, string Misheard);
public sealed record LayoutEntry(long Id, string Timestamp, string Name, string Json);
public sealed record ClipEntry(long Id, string Timestamp, string Content, byte[]? Image);

/// <summary>
/// SQLite-backed history + personal dictionary + clips + window layouts.
/// Single connection, serialized via a lock.
///
/// PARITY CONTRACT: schema (tables, columns, trim limits) matches
/// Sources/PowerTools/Store.swift — a grc-whisper.sqlite from the Mac app
/// opens and works here unchanged.
/// </summary>
public sealed class Store : IDisposable
{
    private readonly SqliteConnection? _db;
    private readonly object _gate = new();

    public Store(string? path = null)
    {
        try
        {
            _db = new SqliteConnection($"Data Source={path ?? Paths.DatabaseFile}");
            _db.Open();
        }
        catch (Exception ex)
        {
            Logger.Log($"store: failed to open database: {ex.Message}");
            _db = null;
            return;
        }
        Exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            app TEXT NOT NULL DEFAULT '',
            raw TEXT NOT NULL,
            polished TEXT NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS dictionary(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE,
            misheard TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS clips(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            content TEXT NOT NULL,
            image BLOB
        );
        CREATE TABLE IF NOT EXISTS layouts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            name TEXT NOT NULL,
            json TEXT NOT NULL
        );
        """);
        AddColumnIfMissing("clips", "image", "ALTER TABLE clips ADD COLUMN image BLOB");
    }

    public void Dispose() => _db?.Dispose();

    private static string Now() =>
        DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private void Exec(string sql)
    {
        if (_db is null) return;
        try
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
        catch (Exception ex) { Logger.Log($"store: exec error: {ex.Message}"); }
    }

    private void AddColumnIfMissing(string table, string column, string ddl)
    {
        if (_db is null) return;
        using var cmd = _db.CreateCommand();
        cmd.CommandText = $"PRAGMA table_info({table})";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            if (reader.GetString(1) == column) return;
        reader.Close();
        Exec(ddl);
    }

    private SqliteCommand Cmd(string sql, params (string Name, object Value)[] args)
    {
        var cmd = _db!.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
        return cmd;
    }

    // ---- History ----

    public void AddHistory(string app, string raw, string polished, int durationMs)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("INSERT INTO history(ts, app, raw, polished, duration_ms) VALUES($ts,$app,$raw,$pol,$dur)",
                ("$ts", Now()), ("$app", app), ("$raw", raw), ("$pol", polished), ("$dur", durationMs));
            cmd.ExecuteNonQuery();
        }
    }

    public List<HistoryEntry> RecentHistory(int limit = 10)
    {
        lock (_gate)
        {
            var list = new List<HistoryEntry>();
            if (_db is null) return list;
            using var cmd = Cmd("SELECT id, ts, app, raw, polished, duration_ms FROM history ORDER BY id DESC LIMIT $n", ("$n", limit));
            using var r = cmd.ExecuteReader();
            while (r.Read())
                list.Add(new HistoryEntry(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetInt32(5)));
            return list;
        }
    }

    // ---- Saved window layouts ----

    public void AddLayout(string name, string json)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using (var cmd = Cmd("INSERT INTO layouts(ts, name, json) VALUES($ts,$name,$json)",
                ("$ts", Now()), ("$name", name), ("$json", json)))
                cmd.ExecuteNonQuery();
            Exec("DELETE FROM layouts WHERE id NOT IN (SELECT id FROM layouts ORDER BY id DESC LIMIT 12)");
        }
    }

    public void UpdateLayoutJson(long id, string json)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("UPDATE layouts SET json = $json, ts = $ts WHERE id = $id",
                ("$json", json), ("$ts", Now()), ("$id", id));
            cmd.ExecuteNonQuery();
        }
    }

    public void RenameLayout(long id, string name)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("UPDATE layouts SET name = $name WHERE id = $id", ("$name", name), ("$id", id));
            cmd.ExecuteNonQuery();
        }
    }

    public List<LayoutEntry> Layouts(int limit = 12)
    {
        lock (_gate)
        {
            var list = new List<LayoutEntry>();
            if (_db is null) return list;
            using var cmd = Cmd("SELECT id, ts, name, json FROM layouts ORDER BY id DESC LIMIT $n", ("$n", limit));
            using var r = cmd.ExecuteReader();
            while (r.Read())
                list.Add(new LayoutEntry(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3)));
            return list;
        }
    }

    public void RemoveLayout(long id)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("DELETE FROM layouts WHERE id = $id", ("$id", id));
            cmd.ExecuteNonQuery();
        }
    }

    // ---- Clipboard history ----

    /// <summary>Add (or bump) a text clip; identical text moves to the top. Newest 200 kept.</summary>
    public void AddClip(string content)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using (var del = Cmd("DELETE FROM clips WHERE content = $c AND image IS NULL", ("$c", content)))
                del.ExecuteNonQuery();
            using (var ins = Cmd("INSERT INTO clips(ts, content) VALUES($ts,$c)", ("$ts", Now()), ("$c", content)))
                ins.ExecuteNonQuery();
            Exec("DELETE FROM clips WHERE image IS NULL AND id NOT IN (SELECT id FROM clips WHERE image IS NULL ORDER BY id DESC LIMIT 200)");
        }
    }

    /// <summary>Add (or bump) an image clip (PNG). Newest 25 kept — images are megabytes.</summary>
    public void AddImageClip(byte[] png, string label)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using (var del = Cmd("DELETE FROM clips WHERE image = $img", ("$img", png)))
                del.ExecuteNonQuery();
            using (var ins = Cmd("INSERT INTO clips(ts, content, image) VALUES($ts,$c,$img)",
                ("$ts", Now()), ("$c", label), ("$img", png)))
                ins.ExecuteNonQuery();
            Exec("DELETE FROM clips WHERE image IS NOT NULL AND id NOT IN (SELECT id FROM clips WHERE image IS NOT NULL ORDER BY id DESC LIMIT 25)");
        }
    }

    public List<ClipEntry> RecentClips(int limit = 9)
    {
        lock (_gate)
        {
            var list = new List<ClipEntry>();
            if (_db is null) return list;
            using var cmd = Cmd("SELECT id, ts, content, image FROM clips ORDER BY id DESC LIMIT $n", ("$n", limit));
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                byte[]? image = r.IsDBNull(3) ? null : (byte[])r.GetValue(3);
                list.Add(new ClipEntry(r.GetInt64(0), r.GetString(1), r.GetString(2), image));
            }
            return list;
        }
    }

    public void ClearClips()
    {
        lock (_gate) Exec("DELETE FROM clips");
    }

    // ---- Dictionary ----

    public void AddDictTerm(string term, string misheard = "")
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("""
                INSERT INTO dictionary(term, misheard) VALUES($t,$m)
                ON CONFLICT(term) DO UPDATE SET misheard=excluded.misheard
                """, ("$t", term), ("$m", misheard));
            cmd.ExecuteNonQuery();
        }
    }

    public void RemoveDictTerm(string term)
    {
        lock (_gate)
        {
            if (_db is null) return;
            using var cmd = Cmd("DELETE FROM dictionary WHERE term = $t", ("$t", term));
            cmd.ExecuteNonQuery();
        }
    }

    public List<DictEntry> Dictionary()
    {
        lock (_gate)
        {
            var list = new List<DictEntry>();
            if (_db is null) return list;
            using var cmd = Cmd("SELECT term, misheard FROM dictionary ORDER BY term");
            using var r = cmd.ExecuteReader();
            while (r.Read())
                list.Add(new DictEntry(r.GetString(0), r.GetString(1)));
            return list;
        }
    }
}
