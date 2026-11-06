#Requires -Version 7.2

# The Path-entry steps of Set-DFDesktopEnv: planning each declared folder against the user Path,
# asking when another copy of a command is found, and the host lines that follow. See
# docs/superpowers/specs/2026-11-03-desktop-path-design.md.

function Get-DFDesktopPathPlan {
    <#
    .SYNOPSIS
        Classifies each desktop Path entry against the user Path: Set, AlreadySet or Skipped (asking when it may).
    .DESCRIPTION
        An entry already on the user Path, however written, is AlreadySet and
        stays the user's. One that isn't a full path once expanded, or whose
        variable has another value in effect, is Skipped, and said so. A missing one is Set (appended), unless another
        copy of its commands is found and the user, asked, chooses before or
        skip. A folder an earlier tool in the run planned is AlreadySet for
        later ones.
    .PARAMETER Tools
        The tool records.
    .PARAMETER Ask
        Whether another copy may be asked about; otherwise the folder is appended.
    .PARAMETER VarPlan
        Get-DFDesktopEnvPlan's results for the same run: the desktop values the guard sees.
    .OUTPUTS
        DotForge.DesktopEnvResult (Kind Path) per entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tools,
        [bool]$Ask,
        [AllowEmptyCollection()][object[]]$VarPlan = @()
    )
    $desktopValue = Get-DFDesktopPathPlannedValue -VarPlan $VarPlan
    $userPath = Get-DFUserPathValue
    $planned = @{}
    foreach ($tool in $Tools) {
        foreach ($entry in @(Get-DFDesktopPathExpected -Tool $tool)) {
            if ($planned.ContainsKey($entry.Path)) {
                New-DFDesktopEnvResult -Kind Path -Tool $tool.name -Name Path -Value $entry.Path -Current $entry.Path -Action AlreadySet
                continue
            }
            $result = Get-DFDesktopPathEntryPlan -ToolName $tool.name -Entry $entry -UserPath $userPath -DesktopValue $desktopValue -Ask $Ask
            if ($result.Action -eq 'Set') { $planned[$entry.Path] = $true }
            $result
        }
    }
}

function Get-DFDesktopPathPlannedValue {
    <#
    .SYNOPSIS
        The desktop value of each variable planned in this run: DotForge's when it is Set or Replaced, else the user's.
    .PARAMETER VarPlan
        Get-DFDesktopEnvPlan's results.
    .OUTPUTS
        System.Collections.Hashtable: variable name -> value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]]$VarPlan = @())
    $values = @{}
    foreach ($item in $VarPlan) {
        # The first tool's result stands for a variable two tools declare, as in Get-DFDesktopEnvPlan.
        if ($values.ContainsKey($item.Name)) { continue }
        $values[$item.Name] = if ($item.Action -in 'Set', 'Replaced') { $item.Value } else { $item.Current }
    }
    $values
}

function Get-DFDesktopPathEntryPlan {
    <#
    .SYNOPSIS
        Plans one desktop Path entry: AlreadySet, Skipped (not a full path, by the guard or by the user), or Set (with the folder to go before, if any).
    .PARAMETER ToolName
        The tool.
    .PARAMETER Entry
        One Get-DFDesktopPathExpected result.
    .PARAMETER UserPath
        The user Path value, as stored.
    .PARAMETER DesktopValue
        Get-DFDesktopPathPlannedValue's table.
    .PARAMETER Ask
        Whether another copy may be asked about.
    .OUTPUTS
        DotForge.DesktopEnvResult (Kind Path).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console lines that are the point of the command, as in Set-DFDesktopEnv.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][AllowEmptyString()][string]$UserPath,
        [hashtable]$DesktopValue,
        [bool]$Ask
    )
    $result = @{ Kind = 'Path'; Tool = $ToolName; Name = 'Path'; Value = $Entry.Path }
    if (-not [IO.Path]::IsPathFullyQualified($Entry.Path)) {
        # The schema rejects such a record; one written anyway would be appended and never found again.
        Write-Host "Skipped ${ToolName}'s Path entry $($Entry.Path): it isn't a full path."
        return New-DFDesktopEnvResult @result -Action Skipped
    }
    $index = Find-DFDesktopPathSegment -Value $UserPath -Folder $Entry.Path
    if ($index -ge 0) { return New-DFDesktopEnvResult @result -Current ($UserPath -split ';')[$index] -Action AlreadySet }
    $guard = Test-DFDesktopPathGuard -Entry $Entry -DesktopValue $DesktopValue
    if ($guard) {
        Write-Host ("Skipped ${ToolName}'s Path entry: $($guard.Name) is $($guard.Current) $($guard.Where), so ${ToolName}'s folder " +
            "isn't under $($Entry.UnderValue). Add $($guard.Suggested) yourself, or let DotForge set $($guard.Name).")
        return New-DFDesktopEnvResult @result -Action Skipped
    }
    $shadowed = @(if ($Entry.Commands.Count) { Find-DFDesktopPathOtherCopy -Command $Entry.Commands -Folder $Entry.Path })
    $choice = if ($shadowed -and $Ask) { Read-DFDesktopPathChoice -Tool $ToolName -Other $shadowed } else { 'A' }
    if ($choice -eq 'S') { return New-DFDesktopEnvResult @result -Shadowed $shadowed -Action Skipped }
    $before = if ($choice -eq 'B') { ($shadowed | Where-Object Scope -eq 'User' | Sort-Object Index | Select-Object -First 1).Path }
    New-DFDesktopEnvResult @result -Shadowed $shadowed -Before $before -Action Set
}

function Read-DFDesktopPathChoice {
    <#
    .SYNOPSIS
        Asks where to put a tool's folder when other copies of its commands are on the desktop Path; returns B, A or S.
    .DESCRIPTION
        Prints one line per other folder, then one question. A copy on the
        system Path is found first whatever the user Path order, so then
        before isn't offered (an answer starting with B counts as A).
    .PARAMETER Tool
        The tool, as named in the question.
    .PARAMETER Other
        Find-DFDesktopPathOtherCopy's results.
    .OUTPUTS
        System.String: B (before), A (after, or add; also for Enter) or S (skip).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console lines that are the point of the command, as in Set-DFDesktopEnv.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][object[]]$Other)
    foreach ($folder in @($Other | Group-Object Path)) {
        $commands = @($folder.Group.Command | Select-Object -Unique)
        $verb = if ($commands.Count -gt 1) { 'are' } else { 'is' }
        $line = if ($folder.Group[0].Scope -eq 'System') {
            "  $($commands -join ', ') $verb also at $($folder.Name) (system Path), which desktop apps find first whatever the user Path order."
        } else { "  $($commands -join ', ') $verb also at $($folder.Name) (user Path)." }
        Write-Host $line
    }
    if (@($Other | Where-Object Scope -eq 'System')) {
        $answer = Read-Host "  [A]dd $Tool's folder anyway or [S]kip (Enter: Add)"
        return $(if ("$answer".Trim() -match '^[Ss]') { 'S' } else { 'A' })
    }
    $answer = "$(Read-Host "  Put $Tool's folder [B]efore it, [A]fter it or [S]kip (Enter: After)")".Trim()
    if ($answer -match '^[Bb]') { 'B' } elseif ($answer -match '^[Ss]') { 'S' } else { 'A' }
}

function Write-DFDesktopPathShadowNote {
    <#
    .SYNOPSIS
        Says, for each folder appended while another copy of its commands comes first, which copy that is.
    .PARAMETER Plan
        Set-DFDesktopEnv's plan, after it was written.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console lines that are the point of the command, as in Set-DFDesktopEnv.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan)
    foreach ($item in @($Plan | Where-Object { $_.Kind -eq 'Path' -and $_.Action -eq 'Set' -and -not $_.Before -and $_.Shadowed.Count })) {
        $copies = @($item.Shadowed | ForEach-Object { "$($_.Command) at $($_.Path)" })
        $verb = if ($copies.Count -gt 1) { 'come' } else { 'comes' }
        Write-Host "Added $($item.Value) at the end of the user Path; $($copies -join ', ') $verb first."
    }
}
