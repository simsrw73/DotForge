#Requires -Version 7.0

function Register-DFTool {
    <#
    .SYNOPSIS
        Configures one or more known CLI tools in the current session.
        Applies XDG env vars, registers argument completers, sets aliases,
        creates declarative fzf pickers, and dot-sources companion .ps1 files.
    .PARAMETER Name
        One or more tool names to configure.
    .PARAMETER All
        Configure every known tool that is installed on PATH.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    .DESCRIPTION
        For each named tool that is present on the system, Register-DFTool:
        applies XDG env vars, creates required directories, sets aliases and
        wrapper functions, builds declarative fzf pickers, and dot-sources the
        companion Tools/<name>.ps1 if one exists. Tools are registered in
        dependency order (honoring dependsOn declarations). Skips tools in
        $DFConfig['SkipTools'] when -All is used.
    .EXAMPLE
        Register-DFTool -All
        Configures every installed tool in one call. Typical profile usage.
    .EXAMPLE
        Register-DFTool -Name psreadline, PSFzf
        Configures only psreadline and PSFzf (in dependency order).
    .EXAMPLE
        Register-DFTool -All -Verbose
        Configures all tools and prints which ones were registered.
    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFToolDb')]
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName')]
        [string[]]$Name,
        [Parameter(ParameterSetName = 'All')]
        [switch]$All,
        [string]$ToolsPath
    )

    if (-not $Name -and -not $All) {
        Write-Error 'Specify -Name <tool> or -All.' -ErrorAction Stop
        return
    }

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $resolvedToolsPath = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath }
                                            else            { Join-Path $PSScriptRoot '../Tools' })

    # Test the value, not just the variable's existence: `$DFConfig = $null` leaves
    # the variable defined, and indexing into it throws "Cannot index into a null array".
    $skipTools = @(if ($null -ne $Global:DFConfig) {
        $Global:DFConfig['SkipTools']
    })
    $skipSetup = @(if ($null -ne $Global:DFConfig) {
        $Global:DFConfig['SkipSetup']
    })

    $tools = if ($All) {
        $db.Values | Where-Object { $_.name -notin $skipTools }
    } else {
        $resolved = [System.Collections.Generic.List[object]]::new()
        foreach ($n in $Name) {
            if ($db.ContainsKey($n)) { $resolved.Add($db[$n]) }
            else { Write-Warning "DotForge: Unknown tool '$n'" }
        }
        $resolved
    }

    # Topological sort respects dependsOn declarations
    $tools = Invoke-DFTopoSort -Tools @($tools)

    # ── Default-tool role resolution (§10) ─────────────────────────────────
    # For each role named in $DFConfig.Defaults, resolve whether the declared
    # winner is role-valid AND actually registering this call; if so, record
    # its own declared alias keys. A role LOSER (same 'role', different name)
    # then has ONLY those specific alias keys suppressed below -- everything
    # else about it (XDG, picker, companion, non-overlapping aliases) still
    # applies. Degrades silently on every invalid/absent case -- never throws.
    $defaults = @(if ($null -ne $Global:DFConfig) { $Global:DFConfig['Defaults'] })[0]
    $activeRoleWinners = @{}
    if ($defaults) {
        foreach ($roleName in $defaults.Keys) {
            $winnerName = $defaults[$roleName]
            if (-not $db.ContainsKey($winnerName)) {
                Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names unknown tool '$winnerName' — ignoring."
                continue
            }
            $winnerTool = $db[$winnerName]
            $winnerRole = $winnerTool.PSObject.Properties['role']?.Value
            if ($winnerRole -ne $roleName) {
                Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names '$winnerName', which declares role '$winnerRole' (expected '$roleName') — ignoring."
                continue
            }
            if (-not ($tools | Where-Object { $_.name -eq $winnerName })) { continue }
            $winnerType = $winnerTool.PSObject.Properties['type']?.Value ?? 'exe'
            if (-not (Test-DFToolAvailable -Executable $winnerTool.executable -Type $winnerType)) { continue }
            $winnerAliasesObj = $winnerTool.PSObject.Properties['aliases']?.Value
            $winnerAliasKeys  = if ($winnerAliasesObj) { @($winnerAliasesObj.PSObject.Properties.Name) } else { @() }
            $activeRoleWinners[$roleName] = @{ WinnerName = $winnerName; AliasKeys = $winnerAliasKeys }
        }
    }

    $registeredTools = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in $tools) {
        # ── Guard: skip if not available ──────────────────────────────────
        $toolType = $tool.PSObject.Properties['type']?.Value ?? 'exe'
        if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $toolType)) {
            Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
            continue
        }

        # ── XDG configuration ──────────────────────────────────────────────
        Set-DFToolXdgConfig -Tool $tool

        # ── Non-XDG environment settings ───────────────────────────────────
        # Applied unconditionally (env vars are not tied to xdg.method). Values
        # go through Expand-DFXdgPath so ${XDG_*} still expands while flag
        # strings pass through byte-for-byte.
        $envBlock = $tool.PSObject.Properties['env']?.Value
        if ($envBlock) {
            $envBlock.PSObject.Properties | ForEach-Object {
                [System.Environment]::SetEnvironmentVariable(
                    $_.Name,
                    (Expand-DFXdgPath $_.Value),
                    'Process'
                )
            }
        }

        # ── Aliases ─────────────────────────────────────────────────────────
        $toolRole   = $tool.PSObject.Properties['role']?.Value
        $roleWinner = if ($toolRole) { $activeRoleWinners[$toolRole] } else { $null }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner

        # ── Declarative picker ──────────────────────────────────────────────
        New-DFToolPickerFunction -Tool $tool

        # ── Companion .ps1 + one-time setup ─────────────────────────────────
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $resolvedToolsPath -SkipSetup $skipSetup

        Write-Verbose "DotForge: $($tool.name) registered"
        $registeredTools.Add($tool.name)
    }

    Initialize-DFCompletionStack -RegisteredTools $registeredTools.ToArray()
    # ── Shadowed-command notice ─────────────────────────────────────────────────
    # One consolidated warning rather than one per tool. Costs nothing when coreutils
    # is absent (Get-DFCoreutilsShadowSet returns early), and self-extinguishes once
    # the conflict is resolved, so it is not a standing nag. Resolving it needs
    # elevation and is a policy choice, so DotForge only ever prints the command.
    if (-not ($Global:DFConfig -and $Global:DFConfig['SkipConflictCheck'])) {
        $conflicts = @(Get-DFCommandConflict -ToolsPath $resolvedToolsPath -ErrorAction Ignore)
        if ($conflicts) {
            $names = ($conflicts.Command | Sort-Object) -join ' '
            # DisableWith, not Command: 'la' is not a coreutils utility and the manager
            # rejects it — disabling 'ls' is what removes it.
            $disable = ($conflicts.DisableWith | Sort-Object -Unique) -join ' '
            Write-Warning @"
DotForge: coreutils shadows $($conflicts.Count) DotForge command(s) before PowerShell resolves them: $names
  These will not reach DotForge's version at the prompt, even though Get-Command reports otherwise.
  Keep DotForge's:  coreutils-manager disable $disable   (run elevated, once)
  Keep coreutils':  `$DFConfig.IgnoreConflicts = @($(($conflicts.Command | Sort-Object | ForEach-Object { "'$_'" }) -join ', '))
  Silence entirely: `$DFConfig.SkipConflictCheck = `$true
"@
        }
    }
}
