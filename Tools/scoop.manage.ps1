#Requires -Version 7.2

function Get-DFScoopRows {
    <#
    .SYNOPSIS
        Parses a table scoop prints (scoop list, scoop status) by the columns its dashes line marks.
    .DESCRIPTION
        Scoop returns objects that PowerShell formats as a table, so column
        names can hold spaces ("Installed Version") and so can values (the
        Updated date). Each run of dashes under the header marks a column.
        Outdated rows are the ones with a Latest Version; a row with only an
        Info note (a held package) is skipped.
    .PARAMETER Result
        Invoke-DFManagerCommand's result.
    .PARAMETER Outdated
        Parse scoop status: Installed Version and Latest Version.
    .OUTPUTS
        PSCustomObject: Id, Installed, Available.
    #>
    param([pscustomobject]$Result, [switch]$Outdated)
    if ($Result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Result.Output)) { return }
    $lines = @($Result.Output -split "`r?`n")
    $dashAt = [Array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match '^-+( +-+)*\s*$' })
    if ($dashAt -lt 1) { return }
    $spans = @([regex]::Matches($lines[$dashAt], '-+'))
    $cell = {
        param($line, $n)
        $start = $spans[$n].Index
        if ($line.Length -le $start) { return '' }
        $end = if ($n + 1 -lt $spans.Count) { [Math]::Min($spans[$n + 1].Index, $line.Length) } else { $line.Length }
        $line.Substring($start, $end - $start).Trim()
    }
    $names = @(for ($n = 0; $n -lt $spans.Count; $n++) { & $cell $lines[$dashAt - 1] $n })
    $column = { param($name) [Array]::IndexOf([string[]]$names, $name) }
    $nameAt = & $column 'Name'
    $installedAt = if ($Outdated) { & $column 'Installed Version' } else { & $column 'Version' }
    $latestAt = & $column 'Latest Version'
    if ($nameAt -lt 0 -or $installedAt -lt 0 -or ($Outdated -and $latestAt -lt 0)) { return }
    foreach ($line in $lines | Select-Object -Skip ($dashAt + 1)) {
        $id = & $cell $line $nameAt
        if (-not $id) { continue }
        $available = if ($Outdated) { & $cell $line $latestAt } else { $null }
        if ($Outdated -and -not $available) { continue }
        [pscustomobject]@{ Id = $id; Installed = (& $cell $line $installedAt); Available = $available }
    }
}

function Get-DFScoopInstalled {
    <#
    .SYNOPSIS
        Lists packages installed by Scoop.
    .DESCRIPTION
        Runs Scoop through DotForge's manager command seam and parses its table output.
    .PARAMETER Manager
        The Scoop manager tool record.
    .EXAMPLE
        Get-DFScoopInstalled -Manager $manager

        Returns Scoop package ids and installed versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    Get-DFScoopRows (Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('scoop', 'list'))
}

function Get-DFScoopOutdated {
    <#
    .SYNOPSIS
        Lists Scoop packages with available updates.
    .DESCRIPTION
        Runs Scoop status through DotForge's manager command seam and parses update rows.
    .PARAMETER Manager
        The Scoop manager tool record.
    .EXAMPLE
        Get-DFScoopOutdated -Manager $manager

        Returns Scoop package ids with installed and available versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    Get-DFScoopRows (Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('scoop', 'status')) -Outdated
}
