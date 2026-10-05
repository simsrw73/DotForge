#Requires -Version 7.0

function Register-DFTool {
    <#
    .SYNOPSIS
        Configures one or more known CLI tools in the current session.
    .DESCRIPTION
        For each requested tool that is installed (its executable is on PATH,
        or for a "type": "module" tool, the module is available), Register-DFTool:

          1. Applies its XDG configuration: sets the env vars in xdg.vars and
             creates the directories in xdg.dirs.
          2. Sets the non-XDG env vars in its "env" block (e.g. FZF_DEFAULT_OPTS,
             GIT_PAGER) for the current process.
          3. Defines its aliases and wrapper functions.
          4. Builds its declarative fzf picker function, if it declares one.
          5. Dot-sources its companion Tools/<name>.ps1, if one exists, and runs
             Tools/<name>.setup.ps1 once ever per machine (tracked in
             $XDG_STATE_HOME\dotforge\setup-state.json).

        Tools that aren't installed are skipped silently (use -Verbose to see
        them). Tools are registered in dependency order, honoring "dependsOn".

        After the loop it installs the completion stack (Carapace, PSFzf or
        inshellisense Tab handling) once, and warns once if Coreutils for
        Windows shadows any DotForge command (see Get-DFCommandConflict).

        $DFConfig keys read:
            SkipTools          tool names excluded from -All
            SkipSetup          tool names whose one-time setup script never runs
            Defaults           role -> winning tool, e.g. @{ listing = 'eza' };
                               the loser's overlapping aliases are not defined
            CompletionMode     'Native' (default) or 'Inshellisense'
            SkipConflictCheck  $true disables the coreutils shadowing warning
            IgnoreConflicts    command names left out of that warning
        Tool companions also read their own keys (Theme, <Tool>Theme,
        PSReadLineEditMode, ShimsPath, …).

        Side effects: changes are scoped to the current session (env vars,
        functions, aliases, key bindings), except what a companion or setup
        script writes to disk: deployed config and theme files under
        $XDG_CONFIG_HOME, caches under $XDG_CACHE_HOME, the setup-state file,
        and for delta, one include.path line in your global git config. Some
        tools relocate their data to XDG paths, so a tool that already had files
        in its old default location stops seeing them.
    .PARAMETER Name
        One or more tool names to configure. An unknown name writes a warning
        and is skipped. $DFConfig['SkipTools'] is not applied to names you list
        explicitly.
    .PARAMETER All
        Configure every known tool that is installed, except those in
        $DFConfig['SkipTools'].
    .PARAMETER ToolsPath
        Read tool records and companions from this directory instead of the
        module's Tools folder. Intended for tests.
    .EXAMPLE
        Register-DFTool -All

        Configures every installed tool in one call. Typical profile usage.
    .EXAMPLE
        Register-DFTool -Name psreadline, PSFzf

        Configures only psreadline and PSFzf (in dependency order).
    .EXAMPLE
        $DFConfig = @{ SkipTools = @('lsd'); Defaults = @{ listing = 'eza' } }
        Import-Module DotForge
        Register-DFTool -All -Verbose

        Configures all tools except lsd, gives ls/ll/la/tree to eza, and prints
        which tools were registered or skipped.
    .OUTPUTS
        None. Changes the current session and may write the files listed above.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/safety.md
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

    # ── Module prewarm (perf) ───────────────────────────────────────────────
    # Fire a background job that imports each type:module tool's module in its
    # own throwaway runspace, purely to warm OS/CLR-level caches before this
    # loop reaches that tool's own (unchanged) Import-Module call below --
    # measured ~77% reduction on a representative module (Get-DFCachedCommandOutput's
    # sibling optimization for exe-type tools; see
    # docs/superpowers/specs/2026-09-05-startup-perf-audit.md Part 2 for this one).
    # Automatic for every type:module tool actually being registered this call
    # (not a new declarative opt-in) -- see Start-DFModulePrewarm's own doc
    # comment for the one assumption this relies on.
    # A tool opts out of prewarming with a top-level "prewarm": false (e.g.
    # Tools/psreadline.json -- its sidecar never re-imports PSReadLine, so
    # prewarming it has no benefit, and PSReadLine's process-global static
    # key-handler dispatch table makes it the module most exposed to
    # Start-ThreadJob's shared-process CLR statics; see Start-DFModulePrewarm's
    # own doc comment). Absent/true means eligible.
    #
    # Everything from the prewarm job's creation through the end of this
    # function runs inside a try/finally so the job is always cleaned up
    # (Remove-Job below), even if a tool's companion .ps1 throws, the caller
    # inherited $ErrorActionPreference = 'Stop', or registration is
    # interrupted (e.g. Ctrl-C) -- otherwise the job leaks into the user's
    # Get-Job table for the rest of the session.
    $prewarmJob = $null
    try {
        $prewarmModules = @(
            foreach ($t in $tools) {
                $tType = $t.PSObject.Properties['type']?.Value ?? 'exe'
                $tPrewarm = $t.PSObject.Properties['prewarm']?.Value ?? $true
                if ($tType -eq 'module' -and $tPrewarm -and (Test-DFToolAvailable -Executable $t.executable -Type 'module')) {
                    $t.executable
                }
            }
        )
        # Skip the call entirely when there's nothing to prewarm rather than relying
        # on Start-DFModulePrewarm's own empty-input $null return -- avoids spinning
        # up (and then force-removing) a background job that would do no work.
        $prewarmJob = if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules } else { $null }

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
    } finally {
        # Fire-and-forget cleanup: remove the prewarm job whether or not it
        # finished, and whether or not the per-tool loop above completed
        # normally. Nothing downstream depends on its result (see
        # Start-DFModulePrewarm's own doc comment) -- if it's still running,
        # force-removing it is safe, since the only work it did was read/JIT
        # already-shared OS/CLR state that persists regardless of how the job
        # itself ends. Using `finally` (rather than plain trailing code) means
        # this still runs if a tool's companion .ps1 throws, the caller
        # inherited $ErrorActionPreference = 'Stop', or registration is
        # interrupted -- otherwise the job leaks into the user's Get-Job
        # table for the rest of the session.
        if ($prewarmJob) {
            $prewarmJob | Remove-Job -Force -ErrorAction Ignore
        }
    }
}
