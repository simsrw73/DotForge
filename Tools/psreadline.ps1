# Companion for psreadline — apply settings, theme, and register theme picker (fprl)
#
# Reads: settings in psreadline.json; $DFConfig.PSReadLineEditMode ('Emacs' default,
# or 'Windows'); $DFConfig.PSReadLineTheme, then $DFConfig.Theme, then
# 'catppuccin-mocha'. Theme files: $XDG_CONFIG_HOME\psreadline\themes\<name>.json,
# else bundled Tools\psreadline\.
# Changes: PSReadLine options for this session, including HistorySavePath, which
# moves to $XDG_STATE_HOME\psreadline\history; earlier history in PowerShell's
# default AppData file is not copied over. Binds Ctrl+p / Ctrl+n.
# Do not change EditMode after Register-DFTool: Set-PSReadLineOption -EditMode
# resets the Tab binding installed by the selected tab-completion role.

# 1. Apply settings from tool JSON
$_settings = $DFCurrentTool.settings
if ($_settings) {
    $_settingsMap = @{
        editMode                       = 'EditMode'
        predictionSource               = 'PredictionSource'
        predictionViewStyle            = 'PredictionViewStyle'
        bellStyle                      = 'BellStyle'
        historyNoDuplicates            = 'HistoryNoDuplicates'
        historySaveStyle               = 'HistorySaveStyle'
        historySearchCursorMovesToEnd  = 'HistorySearchCursorMovesToEnd'
        maximumHistoryCount            = 'MaximumHistoryCount'
    }
    $_optionArgs = @{}
    $_settings.PSObject.Properties | ForEach-Object {
        $_param = $_settingsMap[$_.Name]
        if ($_param) {
            $_optionArgs[$_param] = $_.Value
        } else {
            Write-Warning "DotForge: unknown PSReadLine setting '$($_.Name)' — skipping"
        }
    }
    $_editModeSetting = Get-DFConfig PSReadLineEditMode
    if ($null -ne $_editModeSetting) {
        if ($_editModeSetting -ieq 'Windows') {
            $_optionArgs['EditMode'] = 'Windows'
        } elseif ($_editModeSetting -ieq 'Emacs') {
            $_optionArgs['EditMode'] = 'Emacs'
        } else {
            Write-Warning "DotForge: invalid PSReadLineEditMode '$_editModeSetting' — retaining tool setting"
        }
    }

    if ($_optionArgs.Count -gt 0) {
        try {
            Set-PSReadLineOption @_optionArgs
        } catch [System.ArgumentException] {
            # PredictionSource/PredictionViewStyle throw when VT is unavailable
            # (e.g. redirected output in tests).  Apply the remaining options individually.
            foreach ($_k in @($_optionArgs.Keys)) {
                $_single = [hashtable]::new()
                $_single[$_k] = $_optionArgs[$_k]
                try {
                    Set-PSReadLineOption @_single
                } catch [System.ArgumentException] {
                    Write-Warning "DotForge: PSReadLine option '$_k' not supported in this terminal — skipping"
                }
            }
        }
    }
}

# 2. Relocate the history file under $XDG_STATE_HOME (PowerShell otherwise
#    keeps it at its AppData default). xdg.dirs already created the directory.
Set-PSReadLineOption -HistorySavePath (Join-Path (Get-DFXdgPath State) 'psreadline' 'history')

# 3. History-search key handlers: Ctrl+p/Ctrl+n cycle history matching what's
#    already typed (vs. the default Up/Down, which cycle the whole history).
Set-PSReadLineKeyHandler -Key Ctrl+p -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key Ctrl+n -Function HistorySearchForward

# 4. Register Invoke-DFApplyPSReadLineTheme (captures $_bundledDir via closure)
$_bundledDir = Join-Path $PSScriptRoot 'psreadline'
# Private helpers can't be called by name from a function:global: closure, but a
# captured scriptblock keeps its module binding, so capture them here.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_xdgPath = ${function:Get-DFXdgPath}

Set-Item -Path 'function:global:Invoke-DFApplyPSReadLineTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a PSReadLine syntax-color theme to this session.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\psreadline\themes\<Name>.json, then
        DotForge's bundled Tools\psreadline\<Name>.json. The file holds a
        "colors" object mapping PSReadLine color names (Command, Parameter,
        String, Comment, …; see Set-PSReadLineOption -Colors) to #RRGGBB hex
        values, which are converted to 24-bit ANSI colors and applied with
        Set-PSReadLineOption -Colors. Invalid colors are skipped with a
        warning; an unknown theme warns and changes nothing.

        Defined by DotForge's psreadline companion, which calls it at startup
        with $DFConfig.PSReadLineTheme, then $DFConfig.Theme, then
        catppuccin-mocha.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .EXAMPLE
        Invoke-DFApplyPSReadLineTheme -Name catppuccin-mocha

        Applies the bundled Catppuccin Mocha colors to the command line.
    .EXAMPLE
        Invoke-DFApplyPSReadLineTheme -Name "$HOME\dotfiles\prl-theme.json"

        Applies a theme file you wrote, e.g. { "colors": { "Command": "#89b4fa", "String": "#a6e3a1" } }.
    .OUTPUTS
        None. Changes PSReadLine colors for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $path = & $_resolveThemeFile -Tool 'psreadline' -Name $Name -BundledDir $_bundledDir
    if (-not $path) {
        Write-Warning "DotForge: PSReadLine theme '$Name' not found"
        return
    }

    $theme  = Get-Content $path -Raw | ConvertFrom-Json
    $colors = @{}
    $theme.colors.PSObject.Properties | ForEach-Object {
        $hex = $_.Value
        if ($hex -match '^#[0-9A-Fa-f]{6}$') {
            $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
            $g = [Convert]::ToInt32($hex.Substring(3, 2), 16)
            $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
            $colors[$_.Name] = "`e[38;2;${r};${g};${b}m"
        } else {
            Write-Warning "DotForge: invalid color '$hex' for token '$($_.Name)' — skipping"
        }
    }
    if ($colors.Count -gt 0) {
        # Expose applied colors for testing in non-VT environments where
        # Get-PSReadLineOption.Colors returns $null (redirected output).
        $global:DFPSReadLineColors = $colors
        Set-PSReadLineOption -Colors $colors
    }
}.GetNewClosure())

# 5. Apply initial theme: per-tool PSReadLineTheme -> shared Theme -> 'catppuccin-mocha'.
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'catppuccin-mocha'
$_themeSetting = Resolve-DFThemeName -Name $_themeSetting -ThemeMap $DFCurrentTool.themeMap
Invoke-DFApplyPSReadLineTheme -Name $_themeSetting

# 6. Register theme picker
Set-Item -Path 'function:global:Select-PSReadLineTheme' -Value ({
    <#
    .SYNOPSIS
        Fuzzy-picks a PSReadLine color theme and applies it to this session.
    .DESCRIPTION
        Lists your themes in $XDG_CONFIG_HOME\psreadline\themes followed by
        DotForge's bundled ones (a user theme hides a bundled theme of the
        same name) in fzf. Enter applies the selection with
        Invoke-DFApplyPSReadLineTheme for the current session only, and prints
        how to keep it: set $DFConfig['PSReadLineTheme'] in your profile.

        Defined by DotForge's psreadline companion; requires fzf (or
        $Env:Picker).
    .EXAMPLE
        fprl

        Opens the theme picker; Enter applies the highlighted theme.
    .OUTPUTS
        None. Writes a confirmation line to the host.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()

    $themes = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new(
                  [System.StringComparer]::OrdinalIgnoreCase)

    $userDir = Join-Path (& $_xdgPath Config) 'psreadline' 'themes'
    if (Test-Path $userDir) {
        Get-ChildItem $userDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
            if ($seen.Add($_.BaseName)) { $themes.Add($_.BaseName) }
        }
    }
    if (Test-Path $_bundledDir) {
        Get-ChildItem $_bundledDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
            if ($seen.Add($_.BaseName)) { $themes.Add($_.BaseName) }
        }
    }
    if ($themes.Count -eq 0) {
        Write-Warning 'DotForge: no PSReadLine themes found'
        return
    }

    Invoke-DFPicker `
        -List   { $themes }.GetNewClosure() `
        -Header 'Select PSReadLine theme  [Enter to apply for this session]' `
        -Action {
            param($n)
            Invoke-DFApplyPSReadLineTheme -Name $n
            Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['PSReadLineTheme'] = '$n')" -ForegroundColor Green
        }
}.GetNewClosure())
Set-Alias -Name fprl -Value Select-PSReadLineTheme -Scope Global -Force
