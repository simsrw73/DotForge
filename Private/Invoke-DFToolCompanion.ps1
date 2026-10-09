#Requires -Version 7.0

function Invoke-DFToolCompanion {
    <#
    .SYNOPSIS
        Runs a tool's one-time setup step (setup.seed files and
        Tools/<name>.setup.ps1, if not yet recorded and not skipped), then
        dot-sources its companion Tools/<name>.ps1, setting $DFCurrentTool
        around each.
    .DESCRIPTION
        The regular companion runs on every load. The setup step runs first,
        at most once ever per tool -- see
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md --
        and a setup script is responsible for calling Complete-DFToolSetup
        itself on success (a tool with only setup.seed is recorded here); a thrown error here is caught and warned so the next
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
        Tool names (the SkipSetup setting) whose one-time setup step (seeds and
        script) must never run.
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

    # The companion body and its hooks are dot-sourced into this scope, so they
    # can overwrite any local here ($Tool, $companion, ...). Everything this
    # function needs afterwards is captured first under one unlikely name.
    $__dfCall = @{
        Tool      = $Tool
        Name      = $Tool.name
        Companion = Join-Path $ToolsPath "$($Tool.name).ps1"
        Setup     = Join-Path $ToolsPath "$($Tool.name).setup.ps1"
        SkipSetup = @($SkipSetup)
        WonRoles  = @($WonRoles)
    }
    $__dfCall.HasCompanion = Test-Path $__dfCall.Companion -PathType Leaf

    # The one-time setup step runs first, so the companion can rely on what it
    # created: setup.seed files, then Tools/<name>.setup.ps1, which records its
    # own completion. With no script, the seeds are recorded here.
    $__dfCall.HasSetupScript = Test-Path $__dfCall.Setup -PathType Leaf
    $__dfCall.HasSeed = [bool]$__dfCall.Tool.PSObject.Properties['setup']?.Value?.seed
    if (($__dfCall.HasSetupScript -or $__dfCall.HasSeed) -and
        $__dfCall.Name -notin $__dfCall.SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$__dfCall.Name]) {
        try {
            $__dfCall.Seeded = @(Invoke-DFToolSeed -Tool $__dfCall.Tool -ToolsPath $ToolsPath)
            if ($__dfCall.HasSetupScript) {
                $DFCurrentTool = $__dfCall.Tool
                . ($__dfCall.Setup)
            } else {
                Complete-DFToolSetup -Name $__dfCall.Name -Actions $__dfCall.Seeded
            }
        } catch {
            Write-Warning "DotForge: $($__dfCall.Name) one-time setup failed: $($_.Exception.Message)"
        }
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }

    if ($__dfCall.HasCompanion) {
        $DFCurrentTool = $__dfCall.Tool
        . ($__dfCall.Companion)
    }

    # Role hooks: plain functions the companion defined in this scope. Only a
    # definition from this tool's own companion file counts, so a stray global
    # of the same name is never mistaken for the hook. Dot-sourced so init
    # scripts run in the same scope the companion body did.
    foreach ($__dfWon in $__dfCall.WonRoles) {
        $__dfCall.Won = $__dfWon
        $__dfHook = if ($__dfCall.HasCompanion) { Get-Item -LiteralPath "function:$($__dfWon.Hook)" -ErrorAction Ignore }
        if ($__dfHook -and $__dfHook.ScriptBlock.File -and
            [System.IO.Path]::GetFullPath($__dfHook.ScriptBlock.File) -eq [System.IO.Path]::GetFullPath($__dfCall.Companion)) {
            $DFCurrentTool = $__dfCall.Tool
            try {
                . $__dfHook.ScriptBlock -Tool $__dfCall.Tool -Role $__dfCall.Won.Role
            } catch {
                Write-Warning "DotForge: $($__dfCall.Name) failed to activate as the $($__dfCall.Won.Role) tool: $($_.Exception.Message)"
            }
        } elseif ($__dfCall.Won.HookRequired) {
            Write-Warning "DotForge: $($__dfCall.Name) declares the $($__dfCall.Won.Role) role but its companion defines no $($__dfCall.Won.Hook) — role not activated."
        }
    }
    Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
}
