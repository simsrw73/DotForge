#Requires -Version 7.2

# The steps of Set-DFDesktopEnv and Remove-DFDesktopEnv. See
# docs/superpowers/specs/2026-10-26-desktop-variables-design.md.

function Get-DFDesktopEnvTool {
    <#
    .SYNOPSIS
        The records Set-DFDesktopEnv works on: the named ones, else the session's requested tools.
    .DESCRIPTION
        Without names, the session's request set is what Get-DFToolStatus
        lists, minus excluded tools. A name with no record, or no session when
        no name is given, is an error.
    .PARAMETER Name
        Tool names, or none.
    .OUTPUTS
        pscustomobject per tool record.
    #>
    [CmdletBinding()]
    param([string[]]$Name)
    if (-not $Name) {
        $Name = @(Get-DFToolStatus 3>$null | Where-Object State -ne 'Excluded' | ForEach-Object Name)
        if (-not $Name) { throw 'DotForge: no session has requested tools here; name them with -Name.' }
    }
    $db = Import-DFToolDb -Name $Name
    foreach ($toolName in $Name) {
        if (-not $db[$toolName]) { throw "DotForge: no tool record named '$toolName'." }
        $db[$toolName]
    }
}

function New-DFDesktopEnvResult {
    <#
    .SYNOPSIS
        One Set-DFDesktopEnv / Remove-DFDesktopEnv result.
    .PARAMETER Tool
        The tool.
    .PARAMETER Name
        The variable; Path for a Path entry.
    .PARAMETER Value
        DotForge's value; the folder for a Path entry.
    .PARAMETER Current
        The value in the user environment before the command, or for a Path entry the matching segment as written; may be $null.
    .PARAMETER Action
        Set, AlreadySet, Kept, Replaced, Removed, Changed or Failed; for a Path entry Set, AlreadySet, Skipped, Removed or Failed.
    .PARAMETER Kind
        Variable or Path.
    .PARAMETER Shadowed
        A Path entry's other copies (Find-DFDesktopPathOtherCopy's results).
    .PARAMETER Before
        A Path entry's folder to insert before (another copy's folder); $null appends.
    .OUTPUTS
        DotForge.DesktopEnvResult.
    #>
    param(
        [string]$Tool, [string]$Name, [string]$Value, [AllowNull()][string]$Current, [string]$Action,
        [ValidateSet('Variable', 'Path')][string]$Kind = 'Variable',
        [AllowEmptyCollection()][object[]]$Shadowed = @(),
        [AllowNull()][string]$Before = $null
    )
    # A [string] parameter turns $null into ''; the result keeps $null for "none".
    [pscustomobject]@{
        PSTypeName = 'DotForge.DesktopEnvResult'; Kind = $Kind; Tool = $Tool; Name = $Name; Value = $Value
        Current = if ($Current) { $Current } else { $null }; Action = $Action
        Shadowed = $Shadowed; Before = if ($Before) { $Before } else { $null }
    }
}

function Read-DFDesktopEnvChoice {
    <#
    .SYNOPSIS
        Asks whether to keep the user's value of a desktop variable or replace it; returns K or R.
    .PARAMETER Name
        The variable.
    .PARAMETER Current
        The user's value.
    .PARAMETER Value
        DotForge's value.
    .OUTPUTS
        System.String: K (keep, also for Enter) or R.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Current, [Parameter(Mandatory)][string]$Value)
    $answer = Read-Host "  $Name is $Current; DotForge would set $Value. [K]eep yours or [R]eplace (Enter: Keep)"
    if ("$answer".Trim() -match '^[Rr]') { 'R' } else { 'K' }
}

function Test-DFDesktopEnvShouldProcess {
    <#
    .SYNOPSIS
        The one ShouldProcess call of a desktop-variable command (a seam tests mock).
    .PARAMETER Cmdlet
        The command's $PSCmdlet.
    .PARAMETER Target
        What is changed.
    .PARAMETER Action
        How.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Cmdlet, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Action)
    $Cmdlet.ShouldProcess($Target, $Action)
}

function Get-DFDesktopEnvPlan {
    <#
    .SYNOPSIS
        Classifies each suggested desktop variable against the user environment: Set, AlreadySet or Kept/Replaced (asking when it may).
    .PARAMETER Tools
        The tool records.
    .PARAMETER Ask
        Whether a differing value may be asked about; otherwise it is kept.
    .OUTPUTS
        DotForge.DesktopEnvResult per variable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Tools, [bool]$Ask)
    # A variable two tools declare is planned once: the first tool's value stands for the rest.
    $planned = @{}
    foreach ($tool in $Tools) {
        foreach ($want in @(Get-DFDesktopEnvExpected -Tool $tool)) {
            if ($planned.ContainsKey($want.Name)) {
                $first = $planned[$want.Name]
                $action = if (Test-DFDesktopEnvMatch -Current $first -Value $want.Value) { 'AlreadySet' } else { 'Kept' }
                New-DFDesktopEnvResult -Tool $tool.name -Name $want.Name -Value $want.Value -Current $first -Action $action
                continue
            }
            $current = Get-DFDesktopEnvValue -Name $want.Name
            $action = if (-not $current) { 'Set' }
                      elseif (Test-DFDesktopEnvMatch -Current $current -Value $want.Value) { 'AlreadySet' }
                      elseif ($Ask -and (Read-DFDesktopEnvChoice -Name $want.Name -Current $current -Value $want.Value) -eq 'R') { 'Replaced' }
                      else { 'Kept' }
            $planned[$want.Name] = if ($action -in 'Set', 'Replaced') { $want.Value } else { $current }
            New-DFDesktopEnvResult -Tool $tool.name -Name $want.Name -Value $want.Value -Current $current -Action $action
        }
    }
}

function Write-DFDesktopEnvPlan {
    <#
    .SYNOPSIS
        Records the planned Set and Replaced variables and Set Path entries, then writes them and broadcasts once if any.
    .DESCRIPTION
        An AlreadySet variable or Path entry is the user's and is never
        recorded. When the record can't be saved, nothing is written (it
        throws). The user Path is read and written once, each folder appended
        or inserted before its Before folder, in plan order. A write that
        fails turns its plan items to Failed, puts back the record DotForge
        had before (or none), and writes a non-terminating error; the other
        writes still happen.
    .PARAMETER Plan
        Get-DFDesktopEnvPlan's and Get-DFDesktopPathPlan's results; a failed item's Action becomes Failed.
    .PARAMETER State
        Read-DFDesktopEnvState's object; its Vars and Path are updated and saved.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][pscustomobject]$State)
    $writes = @($Plan | Where-Object { ($_.Kind -eq 'Variable' -and $_.Action -in 'Set', 'Replaced') -or ($_.Kind -eq 'Path' -and $_.Action -eq 'Set') })
    if (-not $writes) { return }
    $previous = Add-DFDesktopEnvPlanRecord -Writes $writes -State $State
    # Recorded first: a write never happens unrecorded, so removal can always find it.
    Save-DFDesktopEnvState -State $State -ErrorAction Stop
    $failures = @(Invoke-DFDesktopEnvPlanWrite -Writes $writes)
    $failedItems = @($failures | ForEach-Object Items)
    if ($failedItems.Count -lt $writes.Count) { Send-DFEnvironmentChange }
    if (-not $failures) { return }
    foreach ($item in $failedItems) {
        $section = if ($item.Kind -eq 'Path') { $State.Path } else { $State.Vars }
        $key = if ($item.Kind -eq 'Path') { $item.Value } else { $item.Name }
        $old = $previous["$($item.Kind)|$key"]
        if ($old) { $section[$key] = $old } else { $section.Remove($key) }
        $item.Action = 'Failed'
    }
    try { Save-DFDesktopEnvState -State $State -ErrorAction Stop }
    catch { Write-Warning "DotForge: $(Get-DFDesktopEnvStatePath) still records what couldn't be written ($($_.Exception.Message)); Remove-DFDesktopEnv drops it." }
    foreach ($failure in $failures) { Write-Error "DotForge: $($failure.Message)" }
}

function Add-DFDesktopEnvPlanRecord {
    <#
    .SYNOPSIS
        Records each planned write in the state (not saved) and returns the records they replaced.
    .PARAMETER Writes
        The plan items to write: Set or Replaced variables, Set Path entries.
    .PARAMETER State
        Read-DFDesktopEnvState's object; its Vars and Path are updated.
    .OUTPUTS
        System.Collections.Hashtable: '<Kind>|<variable or folder>' -> the record it replaced, for each that had one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object[]]$Writes, [Parameter(Mandatory)][pscustomobject]$State)
    $since = [DateTime]::UtcNow.ToString('o')
    $previous = @{}
    foreach ($item in $Writes) {
        $isPath = $item.Kind -eq 'Path'
        $section = if ($isPath) { $State.Path } else { $State.Vars }
        $key = if ($isPath) { $item.Value } else { $item.Name }
        if ($section.ContainsKey($key)) { $previous["$($item.Kind)|$key"] = $section[$key] }
        $section[$key] = if ($isPath) { [pscustomobject]@{ tool = $item.Tool; since = $since } }
                         else { [pscustomobject]@{ tool = $item.Tool; value = $item.Value; since = $since } }
    }
    $previous
}

function Invoke-DFDesktopEnvPlanWrite {
    <#
    .SYNOPSIS
        Writes the planned variables, then the user Path once; returns what failed instead of stopping.
    .PARAMETER Writes
        The plan items to write: Set or Replaced variables, Set Path entries.
    .OUTPUTS
        pscustomobject per failed write: Items (the plan items it covered) and Message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Writes)
    foreach ($item in @($Writes | Where-Object Kind -eq 'Variable')) {
        try { Set-DFDesktopEnvValue -Name $item.Name -Value $item.Value }
        catch { [pscustomobject]@{ Items = @($item); Message = "couldn't set $($item.Name) ($($_.Exception.Message)), so it isn't recorded." } }
    }
    $pathWrites = @($Writes | Where-Object Kind -eq 'Path')
    if (-not $pathWrites) { return }
    try {
        $userPath = Get-DFUserPathValue
        foreach ($item in $pathWrites) {
            $beforeIndex = if ($item.Before) { Find-DFDesktopPathSegment -Value $userPath -Folder $item.Before } else { -1 }
            $userPath = Add-DFDesktopPathSegment -Value $userPath -Segment $item.Value -BeforeIndex $beforeIndex
        }
        Set-DFUserPathValue -Value $userPath
    } catch {
        $folders = @($pathWrites.Value) -join ', '
        [pscustomobject]@{ Items = $pathWrites; Message = "couldn't write the user Path ($($_.Exception.Message)), so $folders isn't on it or recorded." }
    }
}
