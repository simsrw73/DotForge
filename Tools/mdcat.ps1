# Companion for mdcat — refine the theme from $DFConfig and register completions.
#
# mdcat is XDG-native and its MDCAT_THEME env var works from any shell (verified
# against mdcat 2.13.0). Tools/mdcat.json sets a static catppuccin-mocha default;
# this sidecar overrides it only when $DFConfig asks for a different theme, then
# registers mdcat's own PowerShell completions.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# 1. Theme: override the JSON default only when $DFConfig specifies one.
$_name = Get-DFConfiguredTheme -ToolKey 'MdcatTheme'
if ($_name) {
    # Family alias: bare 'catppuccin' -> mdcat's default flavour.
    if ($_name -eq 'catppuccin') { $_name = 'catppuccin-mocha' }

    $_builtin = @(
        'auto', 'dark', 'light',
        'catppuccin-mocha', 'catppuccin-latte',
        'gruvbox-dark', 'gruvbox-light',
        'dracula', 'nord',
        'solarized-dark', 'solarized-light'
    )
    if ($_name -notin $_builtin) {
        Write-Warning "DotForge: mdcat theme '$_name' not recognized — falling back to 'auto'"
        $_name = 'auto'
    }
    [System.Environment]::SetEnvironmentVariable('MDCAT_THEME', $_name, 'Process')
}

# 2. Native completions. mdcat emits a single Register-ArgumentCompleter -Native
#    call; carapace ships no mdcat spec, so there is no conflict, and it composes
#    with PSFzf's Tab (which routes through TabExpansion2). Invoke-Expression is
#    mdcat's documented init pattern. See docs/external-dependencies.md.
$_completions = mdcat --completions powershell | Out-String
if ($_completions) { Invoke-Expression $_completions }
