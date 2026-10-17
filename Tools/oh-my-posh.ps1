# Companion for oh-my-posh — prompt engine init + theme picker (fpot)
# Dot-sourced by Register-DFTool when oh-my-posh is registered.
# Invoke-Expression is required by oh-my-posh's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# DotForge's bundled catppuccin themes (oh-my-posh's own, MIT): Tools\oh-my-posh\<native>.omp.json.
$_ompBundled = Join-Path $PSScriptRoot 'oh-my-posh'

function Resolve-DFOhMyPoshConfig {
    # The config oh-my-posh starts with, first match wins: your POSH_THEME (not one pointing at a
    # bundled theme, which a nested shell inherited), your one *.omp.* in $XDG_CONFIG_HOME\oh-my-posh
    # (several: the first, with a warning), then the theme's file -Native in POSH_THEMES_PATH, then
    # the bundled one. Nothing when none exists.
    param([string]$Native, [Parameter(Mandatory)][string]$Bundled)
    $own = $Env:POSH_THEME -and $Env:POSH_THEME.StartsWith($Bundled, [System.StringComparison]::OrdinalIgnoreCase)
    if ($Env:POSH_THEME -and -not $own -and (Test-Path -LiteralPath $Env:POSH_THEME)) { return $Env:POSH_THEME }
    $ompDir = Join-Path (Get-DFXdgPath Config) 'oh-my-posh'
    $candidates = @(Get-ChildItem -LiteralPath $ompDir -Filter '*.omp.*' -ErrorAction Ignore | Sort-Object Name)
    if ($candidates.Count -gt 1) {
        Write-Warning "DotForge: multiple oh-my-posh configs found; using '$($candidates[0].Name)'. Set `$Env:POSH_THEME to be explicit."
    }
    if ($candidates.Count) { return $candidates[0].FullName }
    Resolve-DFOhMyPoshThemeFile -Native $Native -Bundled $Bundled
}

function Resolve-DFOhMyPoshThemeFile {
    # The theme's file: <POSH_THEMES_PATH>\<Native>.omp.json, else the bundled one; nothing when neither exists.
    param([string]$Native, [Parameter(Mandatory)][string]$Bundled)
    if (-not $Native) { return }
    foreach ($dir in @($Env:POSH_THEMES_PATH, $Bundled)) {
        if (-not $dir) { continue }
        $file = Join-Path $dir "$Native.omp.json"
        if (Test-Path -LiteralPath $file -PathType Leaf) { return $file }
    }
}

function Initialize-DFRolePrompt {
    # Called by DotForge only when oh-my-posh wins the prompt role. Everything
    # here is prompt behavior: posh-git, init, and the fpot theme picker.
    param([PSCustomObject]$Tool, [string]$Role)
    # 1. posh-git integration — must run before oh-my-posh init so OMP sees POSH_GIT_ENABLED
    if (Get-Module -ListAvailable posh-git -ErrorAction Ignore) {
        Import-Module posh-git -ErrorAction Ignore
        $Env:POSH_GIT_ENABLED = $true
    }

    # 2. Resolve config path: your POSH_THEME → your XDG config → the theme's file (Theme, OhMyPoshTheme).
    $theme = Get-DFToolTheme -Tool $Tool
    $ompConfig = Resolve-DFOhMyPoshConfig -Native $theme.Value -Bundled $_ompBundled
    if (-not $ompConfig) {
        Write-Warning 'DotForge: no oh-my-posh config found. Set $Env:POSH_THEME or place *.omp.* in $XDG_CONFIG_HOME/oh-my-posh/.'
    }

    # 3. Initialize prompt engine
    if ($ompConfig) {
        oh-my-posh init pwsh --config $ompConfig | Invoke-Expression
    }

    # --- Theme picker (fpot) ---
    function global:Select-PoshTheme {
        <#
        .SYNOPSIS
            Fuzzy-picks an oh-my-posh theme with a live prompt preview and applies it to this session.
        .DESCRIPTION
            Lists the *.omp.json themes in $Env:POSH_THEMES_PATH in fzf, previewing
            each one's rendered prompt. DotForge sets POSH_THEMES_PATH to
            $XDG_DATA_HOME\oh-my-posh\themes, so copy the themes you want to browse
            there.
            Enter re-initializes oh-my-posh with that theme for the current session
            only. To keep it, point $Env:POSH_THEME at the theme file, or copy it to
            $XDG_CONFIG_HOME\oh-my-posh\, before DotForge loads. Warns and does
            nothing when POSH_THEMES_PATH is missing.

            Re-initializing replaces the prompt function, so zoxide's directory
            tracking stops until the next session (a known limitation).

            Defined by DotForge's oh-my-posh companion; requires fzf (or
            $Env:Picker).
        .EXAMPLE
            fpot

            Opens the theme picker; Enter applies the highlighted theme.
        .OUTPUTS
            None. Writes a confirmation line to the host.
        .LINK
            https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
        #>
        [CmdletBinding()]
        param()

        $themesPath = $Env:POSH_THEMES_PATH
        if (-not $themesPath -or -not (Test-Path $themesPath)) {
            Write-Warning 'DotForge: POSH_THEMES_PATH not set or directory not found'
            return
        }

        Invoke-DFPicker `
            -List          { Get-ChildItem $themesPath -Filter '*.omp.json' | Select-Object -ExpandProperty Name } `
            -Preview       "oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
            -PreviewWindow 'bottom:5' `
            -Ansi `
            -Header        'Select oh-my-posh theme  [Enter to apply for this session]' `
            -Action        {
                param($theme)
                oh-my-posh init pwsh --config "$themesPath\$theme" | Invoke-Expression
                Write-Host "Theme applied: $theme  (to persist: update oh-my-posh config path)" -ForegroundColor Green
            }
    }
    Set-Alias -Name fpot -Value Select-PoshTheme -Scope Global -Force

    # --- Theme switching (Set-DFToolTheme oh-my-posh <flavor>) ---
    $themeFile = ${function:Resolve-DFOhMyPoshThemeFile}
    $bundled = $_ompBundled
    Set-Item -Path 'function:global:Invoke-DFApplyOhMyPoshTheme' -Value ({
        <#
        .SYNOPSIS
            Switches the oh-my-posh prompt to a theme for this session.
        .DESCRIPTION
            Re-initializes oh-my-posh with <Name>.omp.json from POSH_THEMES_PATH,
            else DotForge's bundled catppuccin themes. It is an explicit choice, so
            it replaces your own config for the rest of the session. Like fpot,
            re-initializing replaces the prompt function, so zoxide's directory
            tracking stops until the next session (a known limitation).

            Defined by DotForge's oh-my-posh companion when oh-my-posh is your
            prompt; Set-DFToolTheme oh-my-posh <flavor> calls it.
        .PARAMETER Name
            The oh-my-posh theme name, e.g. catppuccin_latte.
        .EXAMPLE
            Set-DFToolTheme oh-my-posh catppuccin-latte

            Switches the prompt to catppuccin latte.
        .OUTPUTS
            None.
        .LINK
            https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
        #>
        param([Parameter(Mandatory)][string]$Name)
        $file = & $themeFile -Native $Name -Bundled $bundled
        if (-not $file) { Write-Warning "DotForge: no oh-my-posh theme file for '$Name'"; return }
        oh-my-posh init pwsh --config $file | Invoke-Expression
    }.GetNewClosure())
}
