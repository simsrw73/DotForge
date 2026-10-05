#Requires -Version 7.0

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        a seeded config file, or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars that aren't already set and creates xdg.dirs; 'config' seeds a default
        config file only when absent (never overwrites a user's edits);
        'manual' warns with any instructions; 'wrapper' and 'default' are
        no-ops here (handled by a companion .ps1, or not needed at all).
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

    $xdg = $Tool.xdg
    if (-not $xdg) { return }
    switch ($xdg.method) {
        'env' {
            $vars = $xdg.vars
            if ($vars) {
                # A tool's vars are defaults: a variable the user already set (in
                # their profile, or system-wide) is never overwritten.
                $vars.PSObject.Properties | ForEach-Object {
                    $current = [System.Environment]::GetEnvironmentVariable($_.Name, 'Process')
                    if ($current) {
                        Write-Verbose "DotForge: $($Tool.name) keeps $($_.Name) as already set ($current)"
                        return
                    }
                    [System.Environment]::SetEnvironmentVariable(
                        $_.Name,
                        (Expand-DFXdgPath $_.Value),
                        'Process'
                    )
                }
            }
            $xdg.dirs | Where-Object { $_ } |
                ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
        }
        'manual' {
            Write-Warning "DotForge: $($Tool.name) requires manual XDG configuration.$(if ($xdg.instructions) { " $($xdg.instructions)" })"
        }
        'config' {
            if ($xdg.config_path) {
                $expandedPath = Expand-DFXdgPath $xdg.config_path
                New-DFDirectory (Split-Path $expandedPath)
                if (-not (Test-Path $expandedPath) -and $xdg.config_content) {
                    Set-Content -Path $expandedPath -Value $xdg.config_content -Encoding UTF8
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
