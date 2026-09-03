# Companion for psreadline — apply settings, theme, and register theme picker (fprl)

# 1. Apply settings from tool JSON
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
if ($_settings) {
    $_settingsMap = @{
        editMode            = 'EditMode'
        predictionSource    = 'PredictionSource'
        predictionViewStyle = 'PredictionViewStyle'
        bellStyle           = 'BellStyle'
        historyNoDuplicates = 'HistoryNoDuplicates'
        historySaveStyle    = 'HistorySaveStyle'
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
    $_editModeSetting = $null
    # Test the value, not the variable's existence: `$DFConfig = $null` leaves the
    # variable defined, and indexing into it throws "Cannot index into a null array".
    if ($null -ne $Global:DFConfig) {
        $_editModeSetting = $Global:DFConfig['PSReadLineEditMode']
    }
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

# 2. Apply key handlers from tool JSON
$_keyHandlers = $DFCurrentTool.PSObject.Properties['keyHandlers']?.Value
if ($_keyHandlers) {
    foreach ($_kh in $_keyHandlers) {
        $_chord    = $_kh.PSObject.Properties['chord']?.Value
        $_function = $_kh.PSObject.Properties['function']?.Value
        if (-not $_chord -or -not $_function) {
            Write-Warning "DotForge: psreadline keyHandlers entry missing 'chord' or 'function' — skipping"
            continue
        }
        try {
            Set-PSReadLineKeyHandler -Chord $_chord -Function $_function -ErrorAction Stop
        } catch {
            Write-Warning "DotForge: PSReadLine key handler '$_chord' -> '$_function' failed — $($_.Exception.Message)"
        }
    }
}

# 3. Register Invoke-DFApplyPSReadLineTheme (captures $_bundledDir via closure)
$_bundledDir = Join-Path $PSScriptRoot 'psreadline'

Set-Item -Path 'function:global:Invoke-DFApplyPSReadLineTheme' -Value ({
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Resolve path: absolute path passthrough, XDG user dir, then bundled
    $path = $null
    if ([System.IO.Path]::IsPathRooted($Name)) {
        $path = $Name
    } else {
        if ($Env:XDG_CONFIG_HOME) {
            $p = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes' "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
        if (-not $path) {
            $p = Join-Path $_bundledDir "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
    }
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

# 4. Apply initial theme: per-tool PSReadLineTheme -> shared Theme -> 'dark'.
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'dark'
$_themeSetting = Resolve-DFThemeName -Name $_themeSetting -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
Invoke-DFApplyPSReadLineTheme -Name $_themeSetting

# 5. Register theme picker
Set-Item -Path 'function:global:Select-PSReadLineTheme' -Value ({
    [CmdletBinding()]
    param()

    $themes = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new(
                  [System.StringComparer]::OrdinalIgnoreCase)

    if ($Env:XDG_CONFIG_HOME) {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        if (Test-Path $userDir) {
            Get-ChildItem $userDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
                if ($seen.Add($_.BaseName)) { $themes.Add($_.BaseName) }
            }
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
