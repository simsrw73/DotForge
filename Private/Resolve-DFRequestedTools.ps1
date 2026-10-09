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
        if ($Entry.StartsWith('+')) {
            $g = $Entry.Substring(1)
            if (-not $GroupDb.Contains($g)) {
                $s = Get-DFFieldSuggestion -Name $g -Known $groupNames
                Write-Warning "DotForge: $Where names unknown group '$Entry'$(if ($s) { " — did you mean '+$s'?" }). Run Get-DFToolGroup to list groups."
                return
            }
            foreach ($m in $GroupDb[$g].Tools) { if ($canonical.ContainsKey($m)) { $canonical[$m] } }
            return
        }
        if ($canonical.ContainsKey($Entry)) { return $canonical[$Entry] }
        $s = Get-DFFieldSuggestion -Name $Entry -Known $KnownTools
        Write-Warning "DotForge: $Where names unknown tool '$Entry'$(if ($s) { " — did you mean '$s'?" })."
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
