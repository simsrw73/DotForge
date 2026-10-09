#Requires -Version 7.0

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs one or more known CLI tools via the first available package manager
        that has a package entry for each tool.
    .DESCRIPTION
        Looks up each tool in the JSON registry (Tools/<name>.json) and walks a
        package-manager preference list, installing through the first manager
        that is on PATH and has a package id in the tool's "packages" map.

        The preference list is, in order of precedence: -PackageManager, then
        $DFConfig['PackageManagerOrder'], then the auto-detected order
        (scoop, winget, choco). cargo is appended as a last resort for any tool
        that declares packages.cargo, unless -PackageManager pins a manager.

        Commands run, per manager:
            scoop       scoop install <id>; for a tool that declares scoopBucket,
                        scoop bucket add <name> <url> (when missing), then
                        scoop install <name>/<id>
            winget      winget install --id <id> --silent --accept-source-agreements --accept-package-agreements
            choco       choco install <id> -y        (needs an elevated shell)
            cargo       cargo install <id>
            psresource  Install-PSResource -Name <id> -Scope CurrentUser

        The package manager's own output is discarded; each attempt prints one
        progress line ("Installing <tool> via <pm> (<id>)… ✓" or "failed"). A
        failure moves on to the next manager. An unknown tool name, or a tool no
        available manager can install, writes a warning and continues with the
        next name. Supports -WhatIf and -Confirm.

        Installing does not configure the tool. Run Register-DFTool -Name <tool>
        (or start a new session) afterwards.
    .PARAMETER Name
        One or more tool names to install. Each must match a Tools/<name>.json
        record; list them with Get-DFTool.
    .PARAMETER PackageManager
        Use only this package manager for the call: scoop, winget, choco,
        psresource, or cargo. Default: the preference list described above.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
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
        None. Writes progress to the host and installs software through the
        chosen package manager.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
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

    $pmOrder = if ($PackageManager) {
        @($PackageManager)
    } elseif (Get-DFConfig PackageManagerOrder) {
        @(Get-DFConfig PackageManagerOrder)
    } else {
        Resolve-DFPackageManager
    }

    foreach ($toolName in $Name) {
        if (-not $db.ContainsKey($toolName)) {
            Write-Warning "DotForge: Unknown tool '$toolName'"
            continue
        }

        $tool     = $db[$toolName]
        $packages = $tool.packages
        $installedVia = $null

        # cargo is not in the auto-detect priority; append it as a last resort when
        # this tool declares a cargo package (skipped when -PackageManager pins one).
        $toolPmOrder = @($pmOrder)
        if (-not $PackageManager -and
            $null -ne $packages -and
            $packages.PSObject.Properties['crates'] -and
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

            # Packages are keyed by source; two managers install from a differently named one.
            # (Temporary: slice 3 replaces this loop with manager plugins.)
            $srcKey  = @{ cargo = 'crates'; psresource = 'psgallery' }[$pm] ?? $pm
            $pkgProp = if ($null -ne $packages) { $packages.PSObject.Properties[$srcKey] } else { $null }
            $ref     = if ($null -ne $pkgProp) { Get-DFPackageRef $pkgProp.Value } else { $null }
            $pkgId   = ${ref}?.Id
            if (-not $pkgId) { continue }

            if ($PSCmdlet.ShouldProcess("$toolName via $pm ($pkgId)", 'Install')) {
                # A third-party bucket is added first, so its message (or warning)
                # gets its own line rather than splitting the progress line below.
                $installId = $pkgId
                if ($pm -eq 'scoop' -and $ref.Feed) {
                    if (-not (Add-DFScoopBucket -Bucket $ref.Feed)) { continue }
                    $installId = "$($ref.Feed.name)/$pkgId"
                }
                Write-Host "  Installing $toolName via $pm ($installId)…" `
                    -ForegroundColor DarkGray -NoNewline

                $null = switch ($pm) {
                    'scoop'      { scoop  install $installId 2>&1 }
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
                    $null = Test-DFToolAvailable -Executable $tool.executable -Type $tool.type -Force
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
