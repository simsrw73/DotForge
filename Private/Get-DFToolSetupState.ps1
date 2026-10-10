#Requires -Version 7.2

function Get-DFToolSetupStatePath {
    <#
    .SYNOPSIS
        Returns the persisted tool-setup state file path.
    .DESCRIPTION
        Centralizes the XDG state location shared by Get-DFToolSetupState and
        Complete-DFToolSetup.
    .OUTPUTS
        System.String — $XDG_STATE_HOME\dotforge\setup-state.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path (Get-DFXdgPath State) 'dotforge' 'setup-state.json'
}

function Get-DFToolSetupState {
    <#
    .SYNOPSIS
        Reads the persisted one-time tool-setup state, keyed by tool name.
    .DESCRIPTION
        Backs Register-DFTool's "has this tool's Tools/<name>.setup.ps1 already
        run?" check and Complete-DFToolSetup's read-modify-write. Never throws:
        a missing file or corrupt JSON both
        return an empty object, treated the same as "no tool has ever run
        setup" -- see docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .OUTPUTS
        [PSCustomObject] keyed by tool name; each value has .ranAt (string)
        and .actions (object[]). Empty object ([PSCustomObject]@{}) if no
        state has ever been recorded.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $stateFile = Get-DFToolSetupStatePath
    if (-not (Test-Path $stateFile -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        [PSCustomObject]@{}
    }
}

function Clear-DFToolSetupState {
    <#
    .SYNOPSIS
        Forgets that one tool's one-time setup ran, so it runs again on its next activation.
    .PARAMETER Name
        The tool.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-DFToolSetupState
    if (-not $state.PSObject.Properties[$Name]) { return }
    $state.PSObject.Properties.Remove($Name)
    Write-DFFileAtomic -Path (Get-DFToolSetupStatePath) -Value ($state | ConvertTo-Json -Depth 10)
}
