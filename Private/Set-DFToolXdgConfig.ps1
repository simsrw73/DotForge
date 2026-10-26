#Requires -Version 7.2

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars through Set-DFEnv (a value set outside DotForge is kept) and creates xdg.dirs;
        'manual' warns with any instructions; 'wrapper' and 'default' are
        no-ops here (handled by a companion .ps1, or not needed at all). A
        default config file is seeded once by the setup step (setup.seed,
        Invoke-DFToolSetup), never here on every load.
    .PARAMETER Tool
        The tool record (from the tool JSON database) to configure.
    .PARAMETER Skip
        Variables to leave unset: they point at the user's existing data, which the XDG location links to.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,
        [AllowEmptyCollection()][string[]]$Skip = @()
    )

    $xdg = $Tool.xdg
    if (-not $xdg) { return }
    switch ($xdg.method) {
        'env' {
            # A tool's vars are defaults: a variable the user set outside DotForge
            # (profile, system) is kept, one DotForge wrote is updated (Set-DFEnv).
            foreach ($var in @($xdg.vars?.PSObject.Properties)) {
                if ($var -and $var.Name -notin $Skip) { Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Tool $Tool.name }
            }
            # Never inside a linked folder: that is the user's existing data.
            foreach ($dir in @($xdg.dirs | Where-Object { $_ })) {
                $path = ConvertTo-DFPath (Expand-DFXdgPath $dir)
                if (-not (Test-DFInLinkedPath -Name $Tool.name -Path $path)) { New-DFDirectory $path }
            }
        }
        'manual' {
            Write-Warning "DotForge: $($Tool.name) requires manual XDG configuration.$(if ($xdg.instructions) { " $($xdg.instructions)" })"
        }
        'wrapper' {
            Write-Verbose "DotForge: $($Tool.name) xdg.method 'wrapper' — handled by companion .ps1"
        }
        'default' { } # tool already follows XDG natively — no env config needed
    }
}
