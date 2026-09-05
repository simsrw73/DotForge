#Requires -Version 7.0

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        a seeded config file, or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars and creates xdg.dirs; 'config' seeds a default
        config file only when absent (never overwrites a user's edits);
        'manual' warns with any instructions; 'wrapper' and 'default' are
        no-ops here (handled by a companion .ps1, or not needed at all).
        Extracted verbatim from Register-DFTool's per-tool loop -- no
        behavior change from the prior inline version.
    .PARAMETER Tool
        The tool record (from the tool JSON database) to configure.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $xdgProp   = $Tool.PSObject.Properties['xdg']
    $xdgMethod = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['method']?.Value } else { $null }
    switch ($xdgMethod) {
        'env' {
            $xdg  = $Tool.xdg
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
            Write-Warning "DotForge: $($Tool.name) requires manual XDG configuration.$(if ($instr) { " $instr" })"
        }
        'config' {
            $xdg = $Tool.xdg
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
            Write-Verbose "DotForge: $($Tool.name) xdg.method 'wrapper' — handled by companion .ps1"
        }
        'default' { } # tool already follows XDG natively — no env config needed
    }
}
