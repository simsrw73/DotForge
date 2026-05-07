# Companion for winget — defines Select-WingetPackage (wins) and Remove-WingetPackage (wrm)
# Dot-sourced by Register-DFTool when winget is registered.

function global:Select-WingetPackage {
    [CmdletBinding()]
    param([string]$Query = '')

    if (-not $Query) { $Query = Read-Host 'Search winget packages' }

    Invoke-DFPicker `
        -List          { winget search $Query 2>$null | Select-Object -Skip 2 | Where-Object { $_ -match '\S' } } `
        -PreviewWindow 'hidden' `
        -Header        'Select package to install  [Enter to winget install]' `
        -Parse         { ($_ -split '\s{2,}')[1] } `
        -Action        {
            param($id)
            if ($id) {
                Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
                winget install --id $id
            }
        }
}
Set-Alias -Name wins -Value Select-WingetPackage -Scope Global -Force

function global:Remove-WingetPackage {
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List          { winget list 2>$null | Select-Object -Skip 3 | Where-Object { $_ -match '\S' } } `
        -PreviewWindow 'hidden' `
        -Header        'Select package to uninstall  [Enter to winget uninstall]' `
        -Parse         { ($_ -split '\s{2,}')[1] } `
        -Action        {
            param($id)
            if ($id) {
                Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
                winget uninstall --id $id
            }
        }
}
Set-Alias -Name wrm -Value Remove-WingetPackage -Scope Global -Force
