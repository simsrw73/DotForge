#Requires -Version 7.0

function Resolve-DFRequestedTools {
    <#
    .SYNOPSIS
        Turns the Tools and ExcludeTools config lists into the session's request set.
    .DESCRIPTION
        Pure: names in, entries out. No tool record is read.
          1. Tools: +group expands to its members; a tool name stays itself
             (matched case-insensitively, returned in its canonical case).
             Each entry records what requested it ('Tools' or '+group'); a
             direct entry wins over a group. Duplicates collapse, first-seen
             order is kept.
          2. ExcludeTools (tools and +groups) mark matching entries Excluded;
             an exclusion always wins. Excluding something that wasn't
             requested warns.
        Unknown tools and groups warn ("did you mean") and are left out; they
        never stop the session.
    .PARAMETER Tools
        The Tools config list.
    .PARAMETER ExcludeTools
        The ExcludeTools config list.
    .PARAMETER GroupDb
        Get-DFGroupDb output.
    .PARAMETER KnownTools
        Every tool name DotForge has a record for (canonical case).
    .PARAMETER Source
        Where the Tools names came from, for warnings. Default: 'Tools'.
    .OUTPUTS
        pscustomobject: Name, RequestedBy, Excluded.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Tools = @(),
        [AllowEmptyCollection()][string[]]$ExcludeTools = @(),
        [Parameter(Mandatory)][System.Collections.IDictionary]$GroupDb,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownTools,
        [string]$Source = 'Tools'
    )

    $canonical = @{}   # case-insensitive name -> canonical name
    foreach ($t in $KnownTools) { $canonical[$t] = $t }
    $groupNames = [string[]]@($GroupDb.Keys)

    # Expands one list entry to canonical tool names, warning about unknowns.
    $expand = {
        param([string]$Entry, [string]$Where)
        $isGroup = $Entry.StartsWith('+')
        if ($isGroup -and -not $GroupDb.Contains($Entry.Substring(1))) {
            $s = Get-DFFieldSuggestion -Name $Entry.Substring(1) -Known $groupNames
            Write-Warning "DotForge: $Where names unknown group '$Entry'$(if ($s) { " — did you mean '+$s'?" }). Run Get-DFToolGroup to list groups."
            return
        }
        foreach ($name in @(Expand-DFGroupEntry -Entry $Entry -GroupDb $GroupDb)) {
            if ($canonical.ContainsKey($name)) { $canonical[$name] }
            elseif (-not $isGroup) {
                $s = Get-DFFieldSuggestion -Name $Entry -Known $KnownTools
                Write-Warning "DotForge: $Where names unknown tool '$Entry'$(if ($s) { " — did you mean '$s'?" })."
            }
        }
    }

    $entries = [ordered]@{}   # canonical name -> entry
    foreach ($item in $Tools) {
        if (-not $item) { continue }
        $by = $item.StartsWith('+') ? $item : 'Tools'
        foreach ($name in @(& $expand $item $Source)) {
            if (-not $entries.Contains($name)) {
                $entries[$name] = [pscustomobject]@{ Name = $name; RequestedBy = $by; Excluded = $false }
            } elseif ($by -eq 'Tools') {
                $entries[$name].RequestedBy = 'Tools'
            }
        }
    }

    foreach ($item in $ExcludeTools) {
        if (-not $item) { continue }
        foreach ($name in @(& $expand $item 'ExcludeTools')) {
            if ($entries.Contains($name)) {
                $entries[$name].Excluded = $true
            } elseif (-not $item.StartsWith('+')) {
                Write-Warning "DotForge: ExcludeTools names '$name', which is not requested in Tools."
            }
        }
    }

    $entries.Values
}

function Expand-DFGroupEntry {
    <#
    .SYNOPSIS
        Expands one Tools/ExcludeTools entry: '+group' to its member names, a tool name to itself.
    .DESCRIPTION
        The one place a +group entry is expanded. An unknown group expands to
        nothing; names are returned as the group lists them, unchecked.
    .PARAMETER Entry
        A tool name or '+group'.
    .PARAMETER GroupDb
        Get-DFGroupDb output.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$GroupDb
    )
    if (-not $Entry.StartsWith('+')) { return $Entry }
    $group = $Entry.Substring(1)
    if ($GroupDb.Contains($group)) { $GroupDb[$group].Tools }
}
