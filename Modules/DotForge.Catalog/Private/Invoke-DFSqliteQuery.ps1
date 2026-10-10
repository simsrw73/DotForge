#Requires -Version 7.0

function Invoke-DFSqliteQuery {
    <#
    .SYNOPSIS
        Runs a read-only query against a SQLite database via winsqlite3.dll
        (ships in System32 on Windows 10+ — zero external dependencies).
    .DESCRIPTION
        Compiles a small P/Invoke shim once per session. Rows come back as
        PSCustomObjects with the query's column names; every value is
        marshalled as text. Any native failure (missing dll, unreadable file,
        bad SQL) returns $null with a verbose message — callers use that to
        drive fallback chains rather than handling exceptions.
    .PARAMETER Database
        Path to the SQLite database file.
    .PARAMETER Query
        The SQL to execute. Use plain `?` placeholders for any value that
        comes from outside the module (a user's search term, etc.) and pass
        the values via -Parameters, in the same left-to-right order the `?`
        placeholders appear -- the same value may be repeated in -Parameters
        to bind it at more than one `?`. A literal value that never varies
        (a column name, a fixed clause) is fine to embed directly in -Query.
    .PARAMETER Parameters
        Values to bind to -Query's `?` placeholders, in order. Always bound
        as SQLite TEXT. Omit when -Query has no placeholders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$Query,

        [string[]]$Parameters
    )

    if (-not (Test-Path $Database)) {
        Write-Verbose "DotForge: SQLite database not found: $Database"
        return $null
    }

    if (-not ('DotForge.Sqlite' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DotForge {
    public static class Sqlite {
        public const int SQLITE_OPEN_READONLY = 1;
        public const int SQLITE_ROW = 100;
        // Tells sqlite3_bind_text to copy the bytes immediately rather than
        // hold the pointer: the managed byte[] we pass isn't pinned and could
        // be moved or collected before the statement is stepped.
        public static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nBytes, out IntPtr stmt, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_bind_text(IntPtr stmt, int index, byte[] value, int nBytes, IntPtr destructor);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_step(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_close_v2(IntPtr db);
    }
}
'@
        } catch {
            Write-Verbose "DotForge: failed to compile the winsqlite3 shim: $_"
            return $null
        }
    }

    $db = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    try {
        $pathUtf8 = [System.Text.Encoding]::UTF8.GetBytes($Database + [char]0)
        if ([DotForge.Sqlite]::sqlite3_open_v2($pathUtf8, [ref]$db, [DotForge.Sqlite]::SQLITE_OPEN_READONLY, [IntPtr]::Zero) -ne 0) {
            Write-Verbose "DotForge: sqlite3_open_v2 failed for $Database"
            return $null
        }

        $sqlUtf8 = [System.Text.Encoding]::UTF8.GetBytes($Query + [char]0)
        if ([DotForge.Sqlite]::sqlite3_prepare_v2($db, $sqlUtf8, -1, [ref]$stmt, [IntPtr]::Zero) -ne 0) {
            Write-Verbose "DotForge: sqlite3_prepare_v2 failed for: $Query"
            return $null
        }

        # Guard on truthiness, not @($Parameters).Count: @($null) is a
        # one-element array (Count 1), so that check would try to bind a
        # parameter index a plain, placeholder-less -Query doesn't have --
        # sqlite3_bind_* returns SQLITE_RANGE for an out-of-range index.
        if ($Parameters) {
            for ($p = 0; $p -lt $Parameters.Count; $p++) {
                $paramUtf8 = [System.Text.Encoding]::UTF8.GetBytes([string]$Parameters[$p])
                # 1-based: sqlite3_bind_* indexes parameters starting at 1, not 0.
                if ([DotForge.Sqlite]::sqlite3_bind_text($stmt, $p + 1, $paramUtf8, $paramUtf8.Length, [DotForge.Sqlite]::SQLITE_TRANSIENT) -ne 0) {
                    Write-Verbose "DotForge: sqlite3_bind_text failed for parameter $($p + 1)"
                    return $null
                }
            }
        }

        $columnCount = [DotForge.Sqlite]::sqlite3_column_count($stmt)
        # Column-name pointers are only stable AFTER the first sqlite3_step —
        # step may auto-reprepare the statement, dangling any pointer fetched
        # earlier (observed: 'value' truncating to 'v'). Read them lazily.
        $names = $null

        while ([DotForge.Sqlite]::sqlite3_step($stmt) -eq [DotForge.Sqlite]::SQLITE_ROW) {
            if (-not $names) {
                # @() guard: a single-column result would otherwise unroll to a
                # scalar string and $names[0] would index its first CHARACTER.
                $names = @(for ($i = 0; $i -lt $columnCount; $i++) {
                    [System.Runtime.InteropServices.Marshal]::PtrToStringUTF8([DotForge.Sqlite]::sqlite3_column_name($stmt, $i))
                })
            }
            $row = [ordered]@{}
            for ($i = 0; $i -lt $columnCount; $i++) {
                $row[$names[$i]] = [System.Runtime.InteropServices.Marshal]::PtrToStringUTF8([DotForge.Sqlite]::sqlite3_column_text($stmt, $i))
            }
            [pscustomobject]$row
        }
    } catch {
        Write-Verbose "DotForge: SQLite query failed: $_"
        return $null
    } finally {
        if ($stmt -ne [IntPtr]::Zero) { $null = [DotForge.Sqlite]::sqlite3_finalize($stmt) }
        if ($db -ne [IntPtr]::Zero) { $null = [DotForge.Sqlite]::sqlite3_close_v2($db) }
    }
}
