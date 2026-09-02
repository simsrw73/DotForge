# Companion for oh-my-posh — prompt engine init + theme picker (fpot)
# Dot-sourced by Register-DFTool when oh-my-posh is registered.
# Invoke-Expression is required by oh-my-posh's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# 1. posh-git integration — must run before oh-my-posh init so OMP sees POSH_GIT_ENABLED
if (Get-Module -ListAvailable posh-git -ErrorAction Ignore) {
    Import-Module posh-git -ErrorAction Ignore
    $Env:POSH_GIT_ENABLED = $true
}

# 2. Resolve config path: $Env:POSH_THEME → XDG discovery → warn
$ompConfig = $null
if ($Env:POSH_THEME -and (Test-Path $Env:POSH_THEME)) {
    $ompConfig = $Env:POSH_THEME
} elseif ($Env:XDG_CONFIG_HOME) {
    $ompDir = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh'
    $candidates = @(Get-ChildItem $ompDir -Filter '*.omp.*' -ErrorAction Ignore | Sort-Object Name)
    if ($candidates.Count -eq 0) {
        Write-Warning 'DotForge: no oh-my-posh config found. Set $Env:POSH_THEME or place *.omp.* in $XDG_CONFIG_HOME/oh-my-posh/.'
    } elseif ($candidates.Count -eq 1) {
        $ompConfig = $candidates[0].FullName
    } else {
        $ompConfig = $candidates[0].FullName
        Write-Warning "DotForge: multiple oh-my-posh configs found; using '$($candidates[0].Name)'. Set `$Env:POSH_THEME to be explicit."
    }
} else {
    Write-Warning 'DotForge: $XDG_CONFIG_HOME not set — cannot locate oh-my-posh config.'
}

# 3. Initialize prompt engine
if ($ompConfig) {
    oh-my-posh init pwsh --config $ompConfig | Invoke-Expression
}

# --- Theme picker (fpot) ---
function global:Select-PoshTheme {
    [CmdletBinding()]
    param()

    $themesPath = $Env:POSH_THEMES_PATH
    if (-not $themesPath -or -not (Test-Path $themesPath)) {
        Write-Warning 'DotForge: POSH_THEMES_PATH not set or directory not found'
        return
    }

    Invoke-DFPicker `
        -List          { Get-ChildItem $themesPath -Filter '*.omp.json' | Select-Object -ExpandProperty Name } `
        -Preview       "Start-Sleep -Milliseconds 1000; oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
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
