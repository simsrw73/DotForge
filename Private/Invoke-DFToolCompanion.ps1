#Requires -Version 7.0

function Invoke-DFToolCompanion {
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
        inside Register-DFTool specifically.
    .PARAMETER Tool
        The tool record whose companion(s) to run.
    .PARAMETER ToolsPath
        The resolved Tools/ directory to look for companions in.
    .PARAMETER SkipSetup
        Tool names ($DFConfig['SkipSetup']) whose one-time setup companion
        must never run.
    .PARAMETER WonRoles
        Roles this tool won: { Role; Hook; HookRequired }. After the companion
        runs, each role's hook function, if the companion itself defined it,
        is dot-sourced with -Tool and -Role. A throwing hook warns; a missing
        hook warns when HookRequired. Roles the tool lost are never passed, so
        their hooks never run.
    .OUTPUTS
        None
    #>
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can
    # read it. PSScriptAnalyzer can't see the companion scope, so suppress
    # the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [Parameter(Mandatory)]
        [string]$ToolsPath,

        [string[]]$SkipSetup = @(),

        [AllowEmptyCollection()]
        [object[]]$WonRoles = @()
    )

    $companion = Join-Path $ToolsPath "$($Tool.name).ps1"
    $hasCompanion = Test-Path $companion -PathType Leaf
    if ($hasCompanion) {
        $DFCurrentTool = $Tool
        . ($companion)
    }

    # Role hooks: plain functions the companion defined in this scope. Only a
    # definition from this tool's own companion file counts, so a stray global
    # of the same name is never mistaken for the hook. Dot-sourced so init
    # scripts run in the same scope the companion body did.
    foreach ($won in $WonRoles) {
        $hook = if ($hasCompanion) { Get-Item -LiteralPath "function:$($won.Hook)" -ErrorAction Ignore }
        if ($hook -and $hook.ScriptBlock.File -and
            [System.IO.Path]::GetFullPath($hook.ScriptBlock.File) -eq [System.IO.Path]::GetFullPath($companion)) {
            $DFCurrentTool = $Tool
            try {
                . $hook.ScriptBlock -Tool $Tool -Role $won.Role
            } catch {
                Write-Warning "DotForge: $($Tool.name) failed to activate as the $($won.Role) tool: $($_.Exception.Message)"
            }
        } elseif ($won.HookRequired) {
            Write-Warning "DotForge: $($Tool.name) declares the $($won.Role) role but its companion defines no $($won.Hook) — role not activated."
        }
    }
    Remove-Variable -Name DFCurrentTool -ErrorAction Ignore

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
