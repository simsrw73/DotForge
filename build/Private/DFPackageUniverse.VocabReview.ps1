#Requires -Version 7.0

# Phase D vocab-gap review helpers. Aggregates the recurring `suggested_terms`
# a `nothing_fits` classification leaves behind, tracks human promote/reject
# decisions durably (so a term never resurfaces once decided), surgically
# grows the closed vocabulary files, and clears cached classifications a
# promoted term affects so they get re-classified on the next Phase D run.
# See docs/package-universe-review-guide.md.

function Get-DFPackageUniverseVocabGapCandidates {
    <#
    .SYNOPSIS
        Aggregates suggested_terms across every done, nothing_fits=1
        classification, grouped case-insensitively, sorted by frequency
        (then alphabetically), excluding already-decided terms.
    .PARAMETER Connection
        An open PSSQLite connection to the categorize database.
    .PARAMETER DecidedTerms
        Terms (any casing) to exclude -- normally every term already present
        in the decisions log (Get-DFPackageUniverseVocabDecisions).
    .OUTPUTS
        [pscustomobject[]] with Term (lowercased) and Count properties.
        Empty array (never $null) when there is nothing to review.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [AllowEmptyCollection()][string[]]$DecidedTerms = @()
    )
    $decided = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $DecidedTerms) { [void]$decided.Add($t) }

    $rows = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT suggested_terms_json FROM tool_classifications WHERE nothing_fits = 1 AND status = 'done' AND suggested_terms_json IS NOT NULL AND suggested_terms_json != '[]'")
    $counts = @{}
    foreach ($r in $rows) {
        $terms = $null
        try { $terms = $r.suggested_terms_json | ConvertFrom-Json } catch { $terms = $null }
        foreach ($t in @($terms)) {
            $term = ([string]$t).Trim().ToLowerInvariant()
            if (-not $term -or $decided.Contains($term)) { continue }
            $counts[$term] = if ($counts.ContainsKey($term)) { $counts[$term] + 1 } else { 1 }
        }
    }
    @($counts.GetEnumerator() | Sort-Object @{e={-$_.Value}}, @{e={$_.Key}} | ForEach-Object {
        [pscustomobject]@{ Term = $_.Key; Count = $_.Value }
    })
}

function Get-DFPackageUniverseVocabDecisions {
    <#
    .SYNOPSIS
        Loads the durable vocab-gap decision log. Returns an empty array
        (never $null) when the file doesn't exist yet -- a fresh review
        session with no prior decisions is a normal, valid state.
    .PARAMETER Path
        The decisions jsonc file.
    .OUTPUTS
        [pscustomobject[]] with term, verdict ('promoted'|'rejected'), axis,
        value, and decidedAt properties.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $doc = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $prop = $doc.PSObject.Properties['decisions']
    @(if ($prop) { $prop.Value } else { @() })
}

function Save-DFPackageUniverseVocabDecision {
    <#
    .SYNOPSIS
        Records a promote/reject verdict for a vocab-gap term, replacing any
        prior decision for the same term (case-insensitive) rather than
        duplicating it. Creates the file (with schemaVersion 1) if absent.
    .PARAMETER Path
        The decisions jsonc file.
    .PARAMETER Term
        The candidate term being decided (as it appeared in suggested_terms).
    .PARAMETER Verdict
        'promoted' or 'rejected'.
    .PARAMETER Axis
        For a 'promoted' verdict: which vocabulary axis it was added to
        (domain|function|worksWith).
    .PARAMETER Value
        For a 'promoted' verdict: the exact string added to the vocabulary
        (may differ from Term -- e.g. normalized to kebab-case).
    .PARAMETER DecidedAt
        ISO-8601 timestamp. Defaults to now; overridable for deterministic
        tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Term,
        [Parameter(Mandatory)][ValidateSet('promoted', 'rejected')][string]$Verdict,
        [string]$Axis,
        [string]$Value,
        [string]$DecidedAt = ([datetime]::UtcNow.ToString('o'))
    )
    $existing = @(Get-DFPackageUniverseVocabDecisions -Path $Path | Where-Object { $_.term -ne $Term -and ([string]$_.term).ToLowerInvariant() -ne $Term.ToLowerInvariant() })
    $new = [pscustomobject]@{ term = $Term; verdict = $Verdict; axis = $Axis; value = $Value; decidedAt = $DecidedAt }
    $all = @($existing) + $new
    [pscustomobject]@{ schemaVersion = 1; decisions = $all } | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding utf8
}

function Add-DFPackageUniverseVocabValue {
    <#
    .SYNOPSIS
        Surgically inserts a new value into a closed-vocabulary JSONC file's
        flat string array, touching only the bytes between that array's own
        [ and ] -- every comment and every other value is preserved
        byte-for-byte. Idempotent: adding an already-present value is a no-op.
    .DESCRIPTION
        Only safe for a genuinely flat array of quoted strings with no
        nested brackets and no comments *inside* the array span (true of
        build/categories/domains.jsonc and taxonomy.jsonc as of this
        writing -- verified by reading both files before writing this
        function). Re-verify that assumption if either file's shape changes.
    .PARAMETER Axis
        The JSON key whose array to grow: domain, function, or worksWith.
    .PARAMETER Value
        The value to insert.
    .PARAMETER Path
        The vocabulary JSONC file (domains.jsonc for domain; taxonomy.jsonc
        for function/worksWith).
    .OUTPUTS
        [bool] $true if inserted, $false if Value was already present.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('domain', 'function', 'worksWith')][string]$Axis,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $raw = Get-Content -Raw -Path $Path
    $pattern = "(?s)(`"$Axis`"\s*:\s*\[)(.*?)(\])"
    $m = [regex]::Match($raw, $pattern)
    if (-not $m.Success) { throw "Add-DFPackageUniverseVocabValue: could not find a `"$Axis`" array in '$Path'." }
    $arrayContent = $m.Groups[2].Value
    if ($arrayContent -match "`"$([regex]::Escape($Value))`"") { return $false }

    $trimmed = $arrayContent.TrimEnd() -replace ',\s*$', ''
    $insertion = "$trimmed,`n    `"$Value`"`n  "
    $newRaw = $raw.Substring(0, $m.Groups[2].Index) + $insertion + $raw.Substring($m.Groups[2].Index + $m.Groups[2].Length)
    Set-Content -Path $Path -Value $newRaw -Encoding utf8 -NoNewline
    $true
}

function Remove-DFPackageUniverseVocabGapClassifications {
    <#
    .SYNOPSIS
        Deletes every cached classification whose suggested_terms exactly
        contains the given term (case-insensitive) -- so a promoted term's
        affected tools have no cached row and get picked up automatically on
        the next Phase D run. Matches by parsed array membership, not a raw
        LIKE substring, so e.g. promoting "font" never accidentally clears
        "font-manager" too.
    .PARAMETER Connection
        An open PSSQLite connection to the categorize database.
    .PARAMETER Term
        The exact suggested term (any casing) to clear.
    .OUTPUTS
        [int] the number of rows deleted.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Term)

    $rows = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT cache_key, suggested_terms_json FROM tool_classifications WHERE nothing_fits = 1 AND status = 'done'")
    $affected = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $terms = $null
        try { $terms = $r.suggested_terms_json | ConvertFrom-Json } catch { $terms = $null }
        $hit = @($terms | Where-Object { $_ -and ([string]$_).Trim().ToLowerInvariant() -eq $Term.ToLowerInvariant() })
        if ($hit.Count -gt 0) { $affected.Add([string]$r.cache_key) }
    }
    foreach ($key in $affected) {
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'DELETE FROM tool_classifications WHERE cache_key = @k' -SqlParameters @{ k = $key }
    }
    $affected.Count
}

function Remove-DFPackageUniverseVocabGapClassificationsBulk {
    <#
    .SYNOPSIS
        Bulk variant of Remove-DFPackageUniverseVocabGapClassifications: clears
        every cached classification whose suggested_terms contains ANY of the
        given terms (case-insensitive), in a single scan of the nothing_fits
        rows rather than one full scan per term. Intended for promoting one
        canonical category that absorbs many raw synonym phrasings at once
        (e.g. applying a vocab-clustering pass's output), where calling the
        single-term version once per variant would rescan the whole table
        dozens or hundreds of times.
    .DESCRIPTION
        Same exact-array-membership matching as the single-term version (never
        a LIKE substring match), and a row that matches more than one of the
        given terms is still only counted/deleted once.
    .PARAMETER Connection
        An open PSSQLite connection to the categorize database.
    .PARAMETER Terms
        The exact suggested terms (any casing) to clear. An empty array is a
        safe no-op.
    .OUTPUTS
        [int] the number of distinct rows deleted.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Connection, [AllowEmptyCollection()][string[]]$Terms = @())

    if ($Terms.Count -eq 0) { return 0 }
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Terms) { [void]$wanted.Add($t) }

    $rows = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT cache_key, suggested_terms_json FROM tool_classifications WHERE nothing_fits = 1 AND status = 'done'")
    $affected = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $terms = $null
        try { $terms = $r.suggested_terms_json | ConvertFrom-Json } catch { $terms = $null }
        $hit = @($terms | Where-Object { $_ -and $wanted.Contains(([string]$_).Trim()) })
        if ($hit.Count -gt 0) { $affected.Add([string]$r.cache_key) }
    }
    foreach ($key in $affected) {
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'DELETE FROM tool_classifications WHERE cache_key = @k' -SqlParameters @{ k = $key }
    }
    $affected.Count
}
