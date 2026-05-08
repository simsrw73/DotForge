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

    $resolvedToolsPath = if ($ToolsPath) { $ToolsPath }
                         else            { Join-Path $PSScriptRoot '../Tools' }

    $skipTools = @(if ($null -ne (Get-Variable -Name DFConfig -Scope Global -ErrorAction Ignore)) {
        $Global:DFConfig['SkipTools']
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

        # ── Argument completions ────────────────────────────────────────────
        $completionsProp = $tool.PSObject.Properties['completions']
        $completionsType = if ($completionsProp) { $completionsProp.Value.PSObject.Properties['type']?.Value } else { $null }
        $exeBase = [IO.Path]::GetFileNameWithoutExtension($tool.executable)

        if ($completionsType -eq 'static') {
            $flags = $tool.completions.PSObject.Properties['flags']?.Value
            if ($flags) {
                $capturedFlags = @($flags)
                Register-ArgumentCompleter -Native -CommandName $exeBase -ScriptBlock {
                    param($wordToComplete, $commandAst, $cursorPosition)
                    $capturedFlags | Where-Object { $_ -like "$wordToComplete*" } |
                        ForEach-Object {
                            [System.Management.Automation.CompletionResult]::new(
                                $_, $_, 'ParameterValue', $_)
                        }
                }.GetNewClosure()
            }
        } elseif ($completionsType -eq 'dynamic') {
            $genCmd = $tool.completions.PSObject.Properties['command']?.Value
            if ($genCmd) {
                $exePath     = (Get-Command $tool.executable -ErrorAction Ignore).Path
                $capturedCmd = $genCmd
                Get-DFCachedCompletion -CacheKey $tool.name -ExePath $exePath -Generate {
                    & ([scriptblock]::Create($capturedCmd))
                }.GetNewClosure()
            }
        }

        # ── Aliases ─────────────────────────────────────────────────────────
        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $aliases.PSObject.Properties | ForEach-Object {
                $aliasName = $_.Name
                $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
                $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
                $aliasArgs = [object[]]@($rawArgs)

                if (-not $aliasCmd) { return }

                if ($aliasArgs.Count -eq 0) {
                    Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
                } else {
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
            . ($companion)
        }

        Write-Verbose "DotForge: $($tool.name) registered"
    }
}
