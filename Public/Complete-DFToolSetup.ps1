#Requires -Version 7.0

function Complete-DFToolSetup {
    <#
    .SYNOPSIS
        Records that a tool's one-time setup has completed successfully.
    .DESCRIPTION
        Call this from a Tools/<name>.setup.ps1 companion as its own last
        line, only once the script's work has actually succeeded. Merges an
        entry for -Name into the persisted state file at
        $XDG_STATE_HOME/dotforge/setup-state.json, recording the UTC time it
        ran and an opaque -Actions record whose shape the calling tool
        defines -- DotForge core never interprets it.

        Register-DFTool checks this state before dot-sourcing a tool's
        Tools/<name>.setup.ps1 again, so once an entry exists for a tool, its
        setup script is skipped on every future Register-DFTool call --
        forever, until the state file is deleted or the entry is removed. See
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .PARAMETER Name
        The tool name this setup record belongs to (matches the "name" field
        in the tool's Tools/<name>.json).
    .PARAMETER Actions
        Free-form objects describing what the setup did, e.g.
        @{ type = 'gitConfigInclude'; path = '...' }. Opaque to DotForge
        core -- recorded verbatim for a future teardown command to read
        back. Defaults to an empty array.
    .EXAMPLE
        Complete-DFToolSetup -Name 'delta' -Actions @(
            @{ type = 'gitConfigInclude'; path = $resolvedIncludePath }
        )
        Records that delta's setup ran, and what it changed.
    .EXAMPLE
        Complete-DFToolSetup -Name 'mdv'
        Records that mdv's setup ran, with no actions to report.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Actions = @()
    )

    if (-not $Env:XDG_STATE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_STATE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $state = Get-DFToolSetupState
    $entry = [PSCustomObject]@{
        ranAt   = (Get-Date).ToUniversalTime().ToString('o')
        actions = @($Actions)
    }
    $state | Add-Member -MemberType NoteProperty -Name $Name -Value $entry -Force

    $stateDir  = Join-Path $Env:XDG_STATE_HOME 'dotforge'
    $stateFile = Join-Path $stateDir 'setup-state.json'
    New-DFDirectory $stateDir

    $tmp = "$stateFile.tmp.$PID"
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $stateFile -Force
}
