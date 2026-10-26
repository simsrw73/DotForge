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
        The variable.
    .PARAMETER Value
        DotForge's value.
    .PARAMETER Current
        The value in the user environment before the command; may be $null.
    .PARAMETER Action
        Set, AlreadySet, Kept, Replaced, Removed or Changed.
    .OUTPUTS
        DotForge.DesktopEnvResult.
    #>
    param([string]$Tool, [string]$Name, [string]$Value, [AllowNull()][string]$Current, [string]$Action)
    [pscustomobject]@{ PSTypeName = 'DotForge.DesktopEnvResult'; Tool = $Tool; Name = $Name; Value = $Value; Current = $Current; Action = $Action }
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
        Records the planned Set, Replaced and AlreadySet variables, then writes the Set and Replaced ones and broadcasts once if any.
    .DESCRIPTION
        A variable already recorded for another tool keeps that owner. When
        the record can't be saved, nothing is written (it throws).
    .PARAMETER Plan
        Get-DFDesktopEnvPlan's results.
    .PARAMETER State
        Read-DFDesktopEnvState's table; updated and saved.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$State)
    foreach ($item in @($Plan | Where-Object Action -in 'Set', 'Replaced', 'AlreadySet')) {
        if ($item.Action -eq 'AlreadySet' -and $State.ContainsKey($item.Name)) { continue }
        $State[$item.Name] = [pscustomobject]@{ tool = $item.Tool; value = $item.Value; since = [DateTime]::UtcNow.ToString('o') }
    }
    # Recorded first: a write that then fails leaves a record removal tolerates, never a write it can't find.
    Save-DFDesktopEnvState -State $State -ErrorAction Stop
    $writes = @($Plan | Where-Object Action -in 'Set', 'Replaced')
    foreach ($item in $writes) { Set-DFDesktopEnvValue -Name $item.Name -Value $item.Value }
    if ($writes) { Send-DFEnvironmentChange }
}
