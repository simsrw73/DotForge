#Requires -Version 7.0

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs one or more known CLI tools via the first available package manager
        that has a package entry for each tool.
    .PARAMETER Name
        One or more tool names to install (must exist in the tool registry).
    .PARAMETER PackageManager
        Override the package manager for this call (scoop | winget | choco).
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
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

    $dfConfigVar = Get-Variable -Name DFConfig -Scope Global -ErrorAction Ignore
    $pmOrder = if ($PackageManager) {
        @($PackageManager)
    } elseif ($null -ne $dfConfigVar -and $dfConfigVar.Value['PackageManagerOrder']) {
        @($dfConfigVar.Value['PackageManagerOrder'])
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

        foreach ($pm in $pmOrder) {
            if (-not (Get-Command $pm -ErrorAction Ignore)) { continue }

            $pkgProp = if ($null -ne $packages) { $packages.PSObject.Properties[$pm] } else { $null }
            $pkgId   = if ($null -ne $pkgProp) { $pkgProp.Value } else { $null }
            if (-not $pkgId) { continue }

            if ($PSCmdlet.ShouldProcess("$toolName via $pm ($pkgId)", 'Install')) {
                Write-Host "  Installing $toolName via $pm ($pkgId)..." `
                    -ForegroundColor DarkGray -NoNewline

                $null = switch ($pm) {
                    'scoop'  { scoop  install $pkgId 2>&1 }
                    'winget' { winget install --id $pkgId --silent `
                                   --accept-source-agreements `
                                   --accept-package-agreements 2>&1 }
                    'choco'  { choco  install $pkgId -y 2>&1 }
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Host ' done' -ForegroundColor Green
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
