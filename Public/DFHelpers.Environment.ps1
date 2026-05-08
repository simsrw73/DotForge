#Requires -Version 7.0

function Get-DFPath {
    [CmdletBinding()]
    param()
    $Env:PATH -split [IO.Path]::PathSeparator
}
Set-Alias -Name path -Value Get-DFPath -Scope Global -Force

function Select-DFEnvVar {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List      { Get-ChildItem Env: | Sort-Object Name |
                     ForEach-Object { "$($_.Name)`t$($_.Value)" } } `
        -Delimiter "`t" `
        -Header    'Select env var  [Enter to output value]' `
        -Parse     { ($_ -split "`t", 2)[1] }
}
Set-Alias -Name fenv -Value Select-DFEnvVar -Scope Global -Force

function Edit-DFProfile {
    [CmdletBinding()]
    param()
    if (-not $Env:EDITOR) {
        Write-Warning 'DotForge: $Env:EDITOR is not set'
        return
    }
    & $Env:EDITOR $PROFILE
}
Set-Alias -Name ep -Value Edit-DFProfile -Scope Global -Force

function Invoke-DFProfileReload {
    [CmdletBinding()]
    param()
    if (Test-Path $PROFILE) {
        . $PROFILE
    } else {
        Write-Warning "DotForge: `$PROFILE not found at $PROFILE"
    }
}
Set-Alias -Name reload -Value Invoke-DFProfileReload -Scope Global -Force
