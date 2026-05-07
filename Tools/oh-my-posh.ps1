# Companion for oh-my-posh — theme picker (fpot)
# Dot-sourced by Register-DFTool when oh-my-posh is registered.

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
        -Preview       "oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
        -PreviewWindow 'bottom:3' `
        -Header        'Select oh-my-posh theme  [Enter to apply for this session]' `
        -Action        {
            param($theme)
            oh-my-posh init pwsh --config "$themesPath\$theme" | Invoke-Expression
            Write-Host "Theme applied: $theme  (to persist: update oh-my-posh config path)" -ForegroundColor Green
        }
}
Set-Alias -Name fpot -Value Select-PoshTheme -Scope Global -Force
