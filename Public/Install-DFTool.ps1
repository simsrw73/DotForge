#Requires -Version 7.0

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs one or more known CLI tools via the first available package manager
        that has a package entry for each tool.
    .PARAMETER Name
        One or more tool names to install (must exist in the tool registry).
    .PARAMETER PackageManager
        Override the package manager for this call (scoop | winget | choco | psresource).
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    .DESCRIPTION
        Looks up each tool in the JSON registry, determines which package managers
        are available, and installs via the first compatible one. Package manager
        preference order uses -PackageManager override, then $DFConfig['PackageManagerOrder'],
        then auto-detected order. Supports -WhatIf.
    .EXAMPLE
        Install-DFTool -Name ripgrep
        Installs ripgrep via scoop, winget, or choco — whichever is available first.
    .EXAMPLE
        Install-DFTool -Name ripgrep, bat, eza
        Installs multiple tools in one call.
    .EXAMPLE
        Install-DFTool -Name ripgrep -PackageManager winget
        Forces installation via winget regardless of preference order.
    .EXAMPLE
        Install-DFTool -Name ripgrep -WhatIf
        Shows what would be installed without executing.
    .OUTPUTS
        None
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [string]$PackageManager,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    # Test the value, not the variable's existence: `$DFConfig = $null` leaves the
    # variable defined, and indexing into it throws "Cannot index into a null array".
    $pmOrder = if ($PackageManager) {
        @($PackageManager)
    } elseif ($null -ne $Global:DFConfig -and $Global:DFConfig['PackageManagerOrder']) {
        @($Global:DFConfig['PackageManagerOrder'])
    } else {
        Resolve-DFPackageManager
    }

    foreach ($toolName in $Name) {
        if (-not $db.ContainsKey($toolName)) {
            Write-Warning "DotForge: Unknown tool '$toolName'"
            continue
        }

        $tool     = $db[$toolName]
        $packages = $tool.PSObject.Properties['packages']?.Value
        $installedVia = $null

        # cargo is not in the auto-detect priority; append it as a last resort when
        # this tool declares a cargo package (skipped when -PackageManager pins one).
        $toolPmOrder = @($pmOrder)
        if (-not $PackageManager -and
            $null -ne $packages -and
            $packages.PSObject.Properties['cargo'] -and
            $toolPmOrder -notcontains 'cargo') {
            $toolPmOrder += 'cargo'
        }

        foreach ($pm in $toolPmOrder) {
            $pmAvailable = if ($pm -eq 'psresource') {
                Get-Command Install-PSResource -ErrorAction Ignore
            } else {
                Get-Command $pm -ErrorAction Ignore
            }
            if (-not $pmAvailable) { continue }

            $pkgProp = if ($null -ne $packages) { $packages.PSObject.Properties[$pm] } else { $null }
            $pkgId   = if ($null -ne $pkgProp) { $pkgProp.Value } else { $null }
            if (-not $pkgId) { continue }

            if ($PSCmdlet.ShouldProcess("$toolName via $pm ($pkgId)", 'Install')) {
                Write-Host "  Installing $toolName via $pm ($pkgId)…" `
                    -ForegroundColor DarkGray -NoNewline

                $null = switch ($pm) {
                    'scoop'      { scoop  install $pkgId 2>&1 }
                    'winget'     { winget install --id $pkgId --silent `
                                       --accept-source-agreements `
                                       --accept-package-agreements 2>&1 }
                    'choco'      { choco  install $pkgId -y 2>&1 }
                    'cargo'      { cargo install $pkgId 2>&1 }
                    'psresource' {
                        try {
                            Install-PSResource -Name $pkgId -Scope CurrentUser -ErrorAction Stop | Out-Null
                            $global:LASTEXITCODE = 0
                        } catch {
                            $global:LASTEXITCODE = 1
                        }
                    }
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Host ' ✓' -ForegroundColor Green
                    $installedVia = $pm
                    break
                } else {
                    Write-Host ' failed' -ForegroundColor Red
                }
            } else {
                $installedVia = $pm
                break
            }
        }

        if (-not $installedVia) {
            Write-Warning "DotForge: Could not install '$toolName'. No compatible package manager from: $($pmOrder -join ', ')"
        }
    }
}
