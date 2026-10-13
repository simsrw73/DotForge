#Requires -Version 7.2

function Set-DFToolTheme {
    <#
    .SYNOPSIS
        Switches an active tool's theme for the rest of this session.
    .DESCRIPTION
        For a tool whose theme block DotForge applies itself: resolves -Theme
        like the configured one (theme map, theme files, built-in names, with a
        warning and the tool's fallback for a name it doesn't know), re-applies
        the theme's environment variables, and makes the tool's wrapper use it
        from the next call. The choice is explicit, so it replaces a value you
        set outside DotForge.

        It lasts for this session; to keep it, set the tool's theme key (for
        example $DFConfig GlowTheme) in your profile. A tool whose theme is
        applied by its companion names its own command instead, and a theme
        written to a config file once, at setup, can't be switched here.
    .PARAMETER Name
        The tool, e.g. glow. Tab completion lists active tools with a theme.
    .PARAMETER Theme
        A theme name, or the full path to a theme file for tools that read theme files.
    .EXAMPLE
        Set-DFToolTheme glow dracula

        Renders Markdown with glow's dracula style for the rest of the session.
    .EXAMPLE
        Set-DFToolTheme bat 'Monokai Extended'

        Switches bat's BAT_THEME.
    .OUTPUTS
        PSCustomObject: Name, Native, Value (what the tool is given) and Explicit.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            foreach ($toolName in @($script:DFSessionToolDb.Keys | Sort-Object)) {
                if ($toolName -like "$wordToComplete*" -and $script:DFSessionToolDb[$toolName].theme -and (Test-DFToolActive $toolName)) { $toolName }
            }
        })]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Theme
    )
    $tool = if ($script:DFSessionToolDb) { $script:DFSessionToolDb[$Name] }
    if (-not $tool -or -not (Test-DFToolActive $Name)) { Write-Error "DotForge: $Name isn't active in this session."; return }
    if (-not $tool.theme) { Write-Error "DotForge: $Name has no theme to switch."; return }
    if ($tool.theme.command) { Write-Error "DotForge: $Name's theme is applied by its companion; use $($tool.theme.command)."; return }
    if (-not (Test-DFThemeSwitchable -Tool $tool)) {
        Write-Error "DotForge: $Name's theme is written to its config once, at setup, so it can't be switched live; edit its config file."
        return
    }
    $resolved = Resolve-DFToolTheme -Tool $tool -Name $Theme
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    $script:DFSessionThemes[$Name] = $resolved
    Set-DFToolThemeEnv -Tool $tool -Theme $resolved -ExplicitReason "Set-DFToolTheme chose '$Theme'"
    $resolved
}
