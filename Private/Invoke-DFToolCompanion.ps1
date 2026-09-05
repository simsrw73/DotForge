#Requires -Version 7.0

function Invoke-DFToolCompanion {
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can
    # read it. PSScriptAnalyzer can't see the companion scope, so suppress
    # the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    <#
    .SYNOPSIS
        Dot-sources a tool's companion Tools/<name>.ps1 (if present) and its
        one-time Tools/<name>.setup.ps1 (if present, not yet run, and not
        skipped), setting $DFCurrentTool around each.
    .DESCRIPTION
        The regular companion runs every Register-DFTool call. The setup
        companion runs at most once ever per tool -- see
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md --
        and is responsible for calling Complete-DFToolSetup itself on
        success; a thrown error here is caught and warned so the next
        Register-DFTool call retries it. Dot-sourcing runs the companion
        directly in this function's own scope (not a child scope), so
        $DFCurrentTool set here immediately before each dot-source is what
        the companion sees -- the sidecar contract only requires "set
        immediately before, cleared immediately after," not that it happen
        inside Register-DFTool specifically. Extracted verbatim from
        Register-DFTool's per-tool loop -- no behavior change from the prior
        inline version.
    .PARAMETER Tool
        The tool record whose companion(s) to run.
    .PARAMETER ToolsPath
        The resolved Tools/ directory to look for companions in.
    .PARAMETER SkipSetup
        Tool names ($DFConfig['SkipSetup']) whose one-time setup companion
        must never run.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [Parameter(Mandatory)]
        [string]$ToolsPath,

        [string[]]$SkipSetup = @()
    )

    $companion = Join-Path $ToolsPath "$($Tool.name).ps1"
    if (Test-Path $companion -PathType Leaf) {
        $DFCurrentTool = $Tool
        . ($companion)
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }

    $setupCompanion = Join-Path $ToolsPath "$($Tool.name).setup.ps1"
    if ((Test-Path $setupCompanion -PathType Leaf) -and
        $Tool.name -notin $SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$Tool.name]) {
        $DFCurrentTool = $Tool
        try {
            . ($setupCompanion)
        } catch {
            Write-Warning "DotForge: $($Tool.name) one-time setup failed: $($_.Exception.Message)"
        }
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }
}
