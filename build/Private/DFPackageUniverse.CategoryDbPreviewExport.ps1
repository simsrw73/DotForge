#Requires -Version 7.0

# Builds a trifle-schema-conformant category db document from the LIVE
# package-universe classifications, for local preview via Get-DFCategoryDb's
# existing $XDG_DATA_HOME/dotforge/tool-categories.json refresh mechanism --
# never touches the real shipped data/tool-categories.json. See
# build/Export-DFPackageUniversePreviewCategoryDb.ps1 and
# docs/package-universe-review-guide.md.

function ConvertTo-DFPackageUniverseCategoryDbPreview {
    <#
    .SYNOPSIS
        Builds a schema-valid category-db document (Test-DFCategoryDbSchema)
        from every classified tool in the package-universe database.
    .DESCRIPTION
        For each tools row, resolves its durable key (Get-DFPackageUniverseDurableKey)
        and looks up the 'done' classification cached under it, mirroring
        Update-DFPackageUniverseToolCategories' own resolution. A tool is
        included only when its classification has a non-empty function array
        and a schema-valid interface (cli|tui|gui) -- both are hard-required
        by Test-DFCategoryDbSchema, and even one row failing either check
        would otherwise fail validation for the WHOLE document, silently
        losing every other tool too (Get-DFCategoryDb falls back to the
        shipped db on any schema failure). Excluded tools are simply
        omitted, not an error -- ~2% of the universe (unclassifiable inputs,
        rare model output artifacts) is an expected, acceptable loss for a
        preview export.

        Real-world tool names collide (~1,500 distinct lowercased names
        shared by multiple genuinely different tools across winget/choco/
        scoop, e.g. "signal", "nginx", "git") -- the shipped schema keys
        `tools` by bare name, so a naive export would silently overwrite
        colliding entries. Every tool sharing a colliding name (case-
        insensitive) is disambiguated with a " (tool_id)" suffix; tools with
        no collision keep their bare name unchanged (the common case).
    .PARAMETER Connection
        An open PSSQLite connection to the package-universe database.
    .PARAMETER Vocab
        { Function; WorksWith } as returned by Import-DFPackageUniverseVocab
        (Domain is ignored -- the shipped category-db schema has no domain
        axis).
    .PARAMETER Now
        The document's `updated` timestamp. Defaults to the current UTC time
        as a full ISO-8601 timestamp (not a bare date) so it reliably
        compares newer than the shipped db's date-only `updated` field in
        Get-DFCategoryDb's refresh-precedence check. Overridable for
        deterministic tests.
    .OUTPUTS
        [pscustomobject] { schemaVersion; updated; taxonomy; tools }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)]$Vocab,
        [string]$Now = [datetime]::UtcNow.ToString('o')
    )

    $De = { param($v) if ($v -is [DBNull]) { $null } else { $v } }
    $tools = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, name, source_count FROM tools')
    $members = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, source, package_id, homepage, extra FROM tool_packages')
    $byTool = @{}
    foreach ($m in $members) {
        $id = [int]$m.tool_id
        if (-not $byTool.ContainsKey($id)) { $byTool[$id] = [System.Collections.Generic.List[object]]::new() }
        $byTool[$id].Add([pscustomobject]@{ source = $m.source; package_id = $m.package_id; homepage = (& $De $m.homepage); extra = (& $De $m.extra) })
    }

    # Defensive JSON-array read: a $null or unparseable column (should not
    # happen via the real write path, which always uses -InputObject @(...),
    # but never trust a raw DB read blindly) degrades to an empty array
    # rather than throwing and aborting the whole export. Declared once
    # outside the per-tool loop below (~25k iterations in production).
    $readJsonArray = {
        param([string]$Json)
        if (-not $Json) { return @() }
        try { @(ConvertFrom-Json -InputObject $Json) } catch { @() }
    }

    $validInterfaces = @('cli', 'tui', 'gui')
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $tools) {
        $id = [int]$t.tool_id
        if (-not $byTool.ContainsKey($id)) { continue }
        $mm = @($byTool[$id])
        $key = Get-DFPackageUniverseDurableKey -Members $mm -Name ([string]$t.name)
        $c = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT domain, function_json, works_with_json, interface, alternative_to_json FROM tool_classifications WHERE cache_key=@k AND status='done'" -SqlParameters @{ k = $key })
        if ($c.Count -eq 0) { continue }
        $row = $c[0]
        $interface = & $De $row.interface
        if ($interface -notin $validInterfaces) { continue }
        # @(...) around each call: PowerShell auto-unwraps a 1-element array
        # returned from a scriptblock's output stream back into a bare
        # scalar, so .Count/iteration on the result must re-force array
        # semantics at the call site every time.
        $function = @(& $readJsonArray (& $De $row.function_json))
        if (-not $function -or $function.Count -eq 0) { continue }
        $worksWith = @(& $readJsonArray (& $De $row.works_with_json))
        $alternativeTo = @(& $readJsonArray (& $De $row.alternative_to_json))

        $ids = [ordered]@{}
        foreach ($m in $mm) { if (-not $ids.Contains($m.source)) { $ids[$m.source] = $m.package_id } }

        $popularity = [Math]::Min(3, [Math]::Max(0, [int]$t.source_count))

        $entries.Add([pscustomobject]@{
            ToolId = $id; Name = [string]$t.name
            Function = $function; WorksWith = $worksWith; Interface = $interface
            AlternativeTo = $alternativeTo; Ids = [pscustomobject]$ids; Popularity = $popularity
        })
    }

    # Disambiguate colliding names (case-insensitive) -- see .DESCRIPTION.
    $nameCounts = @{}
    foreach ($e in $entries) {
        $k = $e.Name.ToLowerInvariant()
        $nameCounts[$k] = if ($nameCounts.ContainsKey($k)) { $nameCounts[$k] + 1 } else { 1 }
    }

    $toolsDict = [ordered]@{}
    foreach ($e in $entries) {
        $exportKey = if ($nameCounts[$e.Name.ToLowerInvariant()] -gt 1) { "$($e.Name) ($($e.ToolId))" } else { $e.Name }
        $toolsDict[$exportKey] = [pscustomobject]@{
            function = $e.Function; worksWith = $e.WorksWith; interface = $e.Interface
            alternativeTo = $e.AlternativeTo; ids = $e.Ids; popularity = $e.Popularity
        }
    }

    [pscustomobject]@{
        schemaVersion = 1
        updated       = $Now
        taxonomy      = [pscustomobject]@{ function = @($Vocab.Function); worksWith = @($Vocab.WorksWith) }
        tools         = [pscustomobject]$toolsDict
    }
}
