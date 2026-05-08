#Requires -Version 7.0

function Get-DFPath {
    <#
    .SYNOPSIS
        Lists each directory in the PATH environment variable as a separate string.
    .EXAMPLE
        Get-DFPath
    .EXAMPLE
        path
    #>
    [CmdletBinding()]
    param()
    $Env:PATH -split [IO.Path]::PathSeparator
}
Set-Alias -Name path -Value Get-DFPath -Scope Global -Force

function Select-DFEnvVar {
    <#
    .SYNOPSIS
        Fuzzy-searches environment variables and returns the value of the selected one.
    .EXAMPLE
        Select-DFEnvVar
    .EXAMPLE
        fenv
    #>
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
    <#
    .SYNOPSIS
        Opens the current PowerShell profile in the editor defined by $Env:EDITOR.
    .EXAMPLE
        Edit-DFProfile
    .EXAMPLE
        ep
    #>
    [CmdletBinding()]
    param()
    if (-not $Env:EDITOR) {
        Write-Warning 'DotForge: $Env:EDITOR is not set'
        return
    }
    & $Env:EDITOR $PROFILE
}
Set-Alias -Name ep -Value Edit-DFProfile -Scope Global -Force

function Get-DFEnv {
    <#
    .SYNOPSIS
        Lists environment variables in KEY=VALUE format.
    .PARAMETER Pattern
        Wildcard filter on variable name. Defaults to * (all).
    .EXAMPLE
        Get-DFEnv
    .EXAMPLE
        env
    .EXAMPLE
        Get-DFEnv PATH*
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Pattern = '*'
    )
    Get-ChildItem Env: |
        Where-Object Name -like $Pattern |
        Sort-Object Name |
        ForEach-Object { "$($_.Name)=$($_.Value)" }
}
Set-Alias -Name env -Value Get-DFEnv -Scope Global -Force

function Invoke-DFProfileReload {
    <#
    .SYNOPSIS
        Re-dot-sources the current PowerShell profile to apply changes without restarting.
    .EXAMPLE
        Invoke-DFProfileReload
    .EXAMPLE
        reload
    #>
    [CmdletBinding()]
    param()
    if (Test-Path $PROFILE) {
        . $PROFILE
    } else {
        Write-Warning "DotForge: `$PROFILE not found at $PROFILE"
    }
}
Set-Alias -Name reload -Value Invoke-DFProfileReload -Scope Global -Force
