#Requires -Version 7.0

function script:Get-DFToolSetupState {
    <#
    .SYNOPSIS
        Reads the persisted one-time tool-setup state, keyed by tool name.
    .DESCRIPTION
        Backs Register-DFTool's "has this tool's Tools/<name>.setup.ps1 already
        run?" check and Complete-DFToolSetup's read-modify-write. Never throws:
        a missing file, an unset $Env:XDG_STATE_HOME, or corrupt JSON all
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

    if (-not $Env:XDG_STATE_HOME) {
        return [PSCustomObject]@{}
    }

    $stateFile = Join-Path $Env:XDG_STATE_HOME 'dotforge' 'setup-state.json'
    if (-not (Test-Path $stateFile -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        [PSCustomObject]@{}
    }
}
