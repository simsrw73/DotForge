#Requires -Version 7.0

function Register-DFTool {
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can read it.
    # PSScriptAnalyzer can't see the companion scope, so suppress the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFToolDb')]
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
            $winnerAvailable = if ($winnerType -eq 'module') {
                Get-Module -Name $winnerTool.executable -ListAvailable -ErrorAction Ignore
            } else {
                Get-Command $winnerTool.executable -ErrorAction Ignore
            }
            if (-not $winnerAvailable) { continue }
            $winnerAliasesObj = $winnerTool.PSObject.Properties['aliases']?.Value
            $winnerAliasKeys  = if ($winnerAliasesObj) { @($winnerAliasesObj.PSObject.Properties.Name) } else { @() }
            $activeRoleWinners[$roleName] = @{ WinnerName = $winnerName; AliasKeys = $winnerAliasKeys }
        }
    }

    $registeredTools = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in $tools) {
        # ── Guard: skip if not available ──────────────────────────────────
        $toolType = $tool.PSObject.Properties['type']?.Value ?? 'exe'
        $isAvailable = if ($toolType -eq 'module') {
            Get-Module -Name $tool.executable -ListAvailable -ErrorAction Ignore
        } else {
            Get-Command $tool.executable -ErrorAction Ignore
        }
        if (-not $isAvailable) {
            Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
            continue
        }

        # ── XDG configuration ──────────────────────────────────────────────
        $xdgProp   = $tool.PSObject.Properties['xdg']
        $xdgMethod = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['method']?.Value } else { $null }
        switch ($xdgMethod) {
            'env' {
                $xdg  = $tool.xdg
                $vars = $xdg.PSObject.Properties['vars']?.Value
                if ($vars) {
                    $vars.PSObject.Properties | ForEach-Object {
                        [System.Environment]::SetEnvironmentVariable(
                            $_.Name,
                            (Expand-DFXdgPath $_.Value),
                            'Process'
                        )
                    }
                }
                $dirs = $xdg.PSObject.Properties['dirs']?.Value
                if ($dirs) {
                    @($dirs) | Where-Object { $_ } |
                        ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
                }
            }
            'manual' {
                $instr = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['instructions']?.Value } else { $null }
                Write-Warning "DotForge: $($tool.name) requires manual XDG configuration.$(if ($instr) { " $instr" })"
            }
            'config' {
                $xdg = $tool.xdg
                $rawConfigPath    = $xdg.PSObject.Properties['config_path']?.Value
                $rawConfigContent = $xdg.PSObject.Properties['config_content']?.Value
                if ($rawConfigPath) {
                    $expandedPath = Expand-DFXdgPath $rawConfigPath
                    New-DFDirectory (Split-Path $expandedPath)
                    if (-not (Test-Path $expandedPath) -and $rawConfigContent) {
                        Set-Content -Path $expandedPath -Value $rawConfigContent -Encoding UTF8
                        Write-Verbose "DotForge: Created default config at $expandedPath"
                    }
                }
            }
            'wrapper' {
                Write-Verbose "DotForge: $($tool.name) xdg.method 'wrapper' — handled by companion .ps1"
            }
            'default' { } # tool already follows XDG natively — no env config needed
        }

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

        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $aliases.PSObject.Properties | ForEach-Object {
                $aliasName = $_.Name

                if ($roleWinner -and $roleWinner.WinnerName -ne $tool.name -and $aliasName -in $roleWinner.AliasKeys) {
                    Write-Verbose "DotForge: $($tool.name) alias '$aliasName' suppressed — '$($roleWinner.WinnerName)' won role '$toolRole'"
                    return
                }

                $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
                $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
                $aliasArgs = [object[]]@($rawArgs)

                if (-not $aliasCmd) { return }

                if ($aliasArgs.Count -eq 0) {
                    Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
                } else {
                    # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
                    # function of the same name in command resolution
                    # (Alias > Function), so it would shadow the wrapper
                    # function below. Remove the colliding global alias first.
                    # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
                    if (Test-Path "Alias:\$aliasName") {
                        Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
                    }
                    $capturedCmd  = $aliasCmd
                    $capturedArgs = $aliasArgs
                    Set-Item -Path "function:global:$aliasName" -Value {
                        & $capturedCmd @capturedArgs @args
                    }.GetNewClosure()
                }
            }
        }

        # ── Declarative picker ──────────────────────────────────────────────
        $picker = $tool.PSObject.Properties['picker']?.Value
        if ($picker -and $picker -is [PSCustomObject]) {
            $pAlias    = $picker.PSObject.Properties['alias']?.Value
            $pFunction = $picker.PSObject.Properties['function']?.Value
            $pList     = $picker.PSObject.Properties['list']?.Value
            $pPreview  = $picker.PSObject.Properties['preview']?.Value ?? ''
            $pWindow   = $picker.PSObject.Properties['preview_window']?.Value ?? 'right:60%'
            $pAnsi     = [bool]($picker.PSObject.Properties['ansi']?.Value)
            $pHeader   = $picker.PSObject.Properties['header']?.Value ?? ''
            $pAction   = $picker.PSObject.Properties['action']?.Value
            $pParse    = $picker.PSObject.Properties['parse']?.Value
            $pAccPath  = [bool]($picker.PSObject.Properties['list_accepts_path']?.Value)

            if ($pFunction -and $pList) {
                $capturedList    = $pList
                $capturedPreview = $pPreview
                $capturedWindow  = $pWindow
                $capturedAnsi    = $pAnsi
                $capturedHeader  = $pHeader
                $capturedAction  = if ($pAction -and $pAction -ne 'output') {
                    [scriptblock]::Create("param(`$v) " + $pAction.Replace('{}', '$v'))
                } else { $null }
                $capturedParse   = if ($pParse) {
                    [scriptblock]::Create($pParse)
                } else { $null }

                $fn = if ($pAccPath) {
                    $capturedParts = @($capturedList -split '\s+')
                    {
                        [CmdletBinding()]
                        param([string]$Path = '.')
                        Invoke-DFPicker `
                            -List          { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                } else {
                    {
                        [CmdletBinding()]
                        param()
                        Invoke-DFPicker `
                            -List          ([scriptblock]::Create($capturedList)) `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                }

                Set-Item -Path "function:global:$pFunction" -Value $fn
                if ($pAlias) {
                    Set-Alias -Name $pAlias -Value $pFunction -Scope Global -Force
                }
            }
        }

        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            $DFCurrentTool = $tool
            . ($companion)
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }

        # ── One-time setup ──────────────────────────────────────────────────
        # Tools/<name>.setup.ps1 runs at most once ever per tool: it is
        # responsible for calling Complete-DFToolSetup itself, as its own
        # last line, only once its work has actually succeeded. If it throws
        # first, nothing gets recorded, so the next Register-DFTool call
        # retries from the top -- see
        # docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
        $setupCompanion = Join-Path $resolvedToolsPath "$($tool.name).setup.ps1"
        if ((Test-Path $setupCompanion -PathType Leaf) -and
            $tool.name -notin $skipSetup -and
            -not (Get-DFToolSetupState).PSObject.Properties[$tool.name]) {
            $DFCurrentTool = $tool
            try {
                . ($setupCompanion)
            } catch {
                Write-Warning "DotForge: $($tool.name) one-time setup failed: $($_.Exception.Message)"
            }
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }

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
