#Requires -Version 7.2

# Each tool's resolved theme this session: tool name -> Resolve-DFToolTheme result.
# Set by registration and Set-DFToolTheme; read by wrappers at call time.

function Resolve-DFToolTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme from its theme block: the name, its native spelling, and the value the tool is given.
    .DESCRIPTION
        Name: -Name, else the tool's per-tool key (theme.key), else the shared
        Theme key, else theme.default (Get-DFConfiguredTheme). Explicit is true
        for -Name and the per-tool key: the user chose this theme for this tool.
        Native: Name translated through theme.map (Resolve-DFThemeName).
        Value: with theme.files, a theme file found by Resolve-DFThemeFile (an
        absolute path, then <XDG config>\<files>\themes, then <tool folder>\<files>);
        otherwise, or when no file matches, Native when theme.valid is empty or
        lists it; otherwise theme.fallback with a warning ($null without one).
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Name
        A theme to use instead of the configured one.
    .EXAMPLE
        Resolve-DFToolTheme -Tool (Get-DFTool -Name bat) -Name nord

        Resolves bat's theme as if the user had chosen nord for it.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit. $null when the tool has no theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [string]$Name)
    $theme = $Tool.theme
    if (-not $theme) { return $null }
    $explicit = [bool]$Name
    if (-not $Name) {
        $explicit = [bool](Get-DFConfig $theme.key)
        $Name = Get-DFConfiguredTheme -ToolKey $theme.key -Default $theme.default
    }
    if (-not $Name) { return [pscustomobject]@{ Name = $null; Native = $null; Value = $null; Explicit = $false } }
    $native = Resolve-DFThemeName -Name $Name -ThemeMap $theme.map
    $value = $null
    if ($theme.files) {
        $bundled = Join-Path (Get-DFToolFolder -Tool $Tool -Default (Join-Path $PSScriptRoot '..' 'Tools')) $theme.files
        $value = Resolve-DFThemeFile -Tool $theme.files -Name $native -BundledDir $bundled
    }
    if (-not $value) {
        if (-not $theme.valid -or $native -in $theme.valid) {
            $value = $native
        } else {
            $value = $theme.fallback
            $instead = if ($value) { "falling back to '$value'" } else { 'leaving it unset' }
            Write-Warning "DotForge: $($Tool.name) theme '$native' not recognized — $instead"
        }
    }
    [pscustomobject]@{ Name = $Name; Native = $native; Value = $value; Explicit = $explicit }
}

function Get-DFToolTheme {
    <#
    .SYNOPSIS
        Returns a tool's theme for this session, resolving it once.
    .DESCRIPTION
        Companions call this instead of resolving the theme themselves; the
        first call (registration) resolves and caches it, later calls reuse it
        (so a rejected name warns once). Set-DFToolTheme replaces it.
    .PARAMETER Tool
        A normalized tool record.
    .EXAMPLE
        Get-DFToolTheme -Tool $DFCurrentTool

        Returns the theme the companion's tool was registered with.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit; $null for a tool without a theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    if (-not $Tool.theme) { return $null }
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    if (-not $script:DFSessionThemes.ContainsKey($Tool.name)) {
        $script:DFSessionThemes[$Tool.name] = Resolve-DFToolTheme -Tool $Tool
    }
    $script:DFSessionThemes[$Tool.name]
}

function Get-DFSessionThemeValue {
    <#
    .SYNOPSIS
        Returns the value of a tool's theme this session, or $null; wrappers call it on every run.
    .DESCRIPTION
        Reads the theme cached by registration or Set-DFToolTheme. It never
        resolves anything, so it is cheap enough for a wrapper to call on
        every run.
    .PARAMETER Name
        The tool name.
    .EXAMPLE
        Get-DFSessionThemeValue -Name bat

        Returns the theme value bat was given this session, or $null.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFSessionThemes -is [hashtable] -and $script:DFSessionThemes.ContainsKey($Name)) {
        $script:DFSessionThemes[$Name].Value
    }
}

function Set-DFSessionTheme {
    <#
    .SYNOPSIS
        Records a tool's theme for the rest of this session; Set-DFToolTheme calls it after resolving a new one.
    .PARAMETER Name
        The tool name.
    .PARAMETER Theme
        A Resolve-DFToolTheme result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscustomobject]$Theme)
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    $script:DFSessionThemes[$Name] = $Theme
}

function Set-DFToolThemeEnv {
    <#
    .SYNOPSIS
        Writes a tool's theme.env variables for a resolved theme, through Set-DFEnv.
    .DESCRIPTION
        Each theme.env template has {theme} replaced by the theme's Value, then
        ${XDG_*} expanded. Nothing is written when the theme has no Value. An
        explicit theme (the per-tool key) overrides a value set outside
        DotForge, naming the key; -ExplicitReason gives another reason.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Theme
        A Resolve-DFToolTheme result.
    .PARAMETER ExplicitReason
        Why the value overrides one set outside DotForge (Set-DFToolTheme passes its own).
    .EXAMPLE
        Set-DFToolThemeEnv -Tool $tool -Theme (Get-DFToolTheme -Tool $tool)

        Writes the tool's theme environment variables for its session theme.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [AllowNull()][pscustomobject]$Theme,
        [string]$ExplicitReason
    )
    if (-not $Theme -or -not $Theme.Value -or -not $Tool.theme.env) { return }
    if (-not $ExplicitReason -and $Theme.Explicit) { $ExplicitReason = "`$DFConfig.$($Tool.theme.key) is '$($Theme.Name)'" }
    foreach ($var in $Tool.theme.env.PSObject.Properties) {
        $value = Expand-DFXdgPath ([string]$var.Value).Replace('{theme}', $Theme.Value)
        Set-DFEnv -Name $var.Name -Value $value -Tool $Tool.name -ExplicitReason $ExplicitReason
    }
}

function Test-DFThemeSwitchable {
    <#
    .SYNOPSIS
        True when DotForge itself applies a tool's theme at run time (theme.env or a wrapper's {theme}), so Set-DFToolTheme can switch it.
    .PARAMETER Tool
        A normalized tool record with a theme block.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $hasEnv = [bool]$Tool.theme.env -and @($Tool.theme.env.PSObject.Properties).Count -gt 0
    $inWrapper = [bool]$Tool.wrapper -and @($Tool.wrapper.args | ForEach-Object { $_.args } | Where-Object { $_.Contains('{theme}') }).Count -gt 0
    $hasEnv -or $inWrapper
}
