# Companion for vivid — resolve the configured theme, generate (or reuse a
# cached) LS_COLORS value, and apply it to the session. Caching mirrors
# Private/Get-DFHelpTopicList.ps1's file-plus-fingerprint pattern: the
# fingerprint is just the resolved theme name, so a theme change invalidates
# the cache and a stable theme reuses it without spawning vivid again
# (~42ms measured locally — worth avoiding on every shell startup).

Set-Item -Path 'function:global:Invoke-DFApplyLSColorsTheme' -Value ({
    <#
    .SYNOPSIS
        Resolves and applies an LS_COLORS value for the named vivid theme.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (-not $Env:XDG_CACHE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_CACHE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
    $cacheFile = Join-Path $cacheDir 'ls-colors.txt'
    $keyFile   = Join-Path $cacheDir 'ls-colors.key'

    $cacheValid = (Test-Path $cacheFile) -and (Test-Path $keyFile) -and
                  ((Get-Content $keyFile -Raw).Trim() -eq $Name)

    if ($cacheValid) {
        $value = (Get-Content $cacheFile -Raw).Trim()
    } else {
        $raw = & vivid generate $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DotForge: vivid theme '$Name' failed — $($raw.Trim())"
            return
        }
        $value = $raw.Trim()

        New-DFDirectory $cacheDir
        Set-Content -Path $keyFile   -Value $Name  -Encoding UTF8
        Set-Content -Path $cacheFile -Value $value -Encoding UTF8
    }

    [System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')
}.GetNewClosure())

# Resolve: per-tool VividTheme -> shared Theme -> tool JSON default.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'VividTheme' -Default $_default
$_theme    = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)

Invoke-DFApplyLSColorsTheme -Name $_theme

# Live picker: list vivid's own themes, preview each via `vivid preview`,
# apply the chosen one immediately (same cache/apply path as registration).
Set-Item -Path 'function:global:Select-LSColorsTheme' -Value ({
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List    { vivid themes } `
        -Header  'Select LS_COLORS theme  [Enter to apply for this session]' `
        -Preview 'vivid preview {}' `
        -Ansi `
        -Action  {
            param($n)
            Invoke-DFApplyLSColorsTheme -Name $n
            Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['VividTheme'] = '$n')" -ForegroundColor Green
        }
}.GetNewClosure())
Set-Alias -Name fls -Value Select-LSColorsTheme -Scope Global -Force
