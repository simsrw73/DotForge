#Requires -Version 7.0

function Get-DFPath {
    <#
    .SYNOPSIS
        Lists each directory in the PATH environment variable as a separate string.
    .DESCRIPTION
        Splits $Env:PATH on the platform path separator and emits one entry per
        line, making it easy to pipe into Where-Object, Select-String, or fzf
        for inspection and debugging.
    .EXAMPLE
        Get-DFPath
        Lists all directories in PATH, one per line.
    .EXAMPLE
        path | Where-Object { $_ -like '*python*' }
        Filters PATH entries that contain 'python' using the path alias.
    .OUTPUTS
        System.String — each PATH directory as a separate string.
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
    .DESCRIPTION
        Displays all environment variables as NAME<tab>VALUE pairs in fzf showing
        only the name column; the selected variable's value is returned so it can
        be captured or piped to further commands.
    .EXAMPLE
        Select-DFEnvVar
        Opens fzf to search env vars; outputs the value of the selected variable.
    .EXAMPLE
        $val = fenv
        Captures the selected environment variable's value into $val.
    .OUTPUTS
        System.String — the value of the selected environment variable.
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
    .DESCRIPTION
        Launches $Env:EDITOR with $PROFILE as the argument. Emits a warning if
        $Env:EDITOR is not set rather than silently failing or falling back to an
        unexpected editor.
    .EXAMPLE
        Edit-DFProfile
        Opens the current profile in whatever editor $Env:EDITOR points to.
    .EXAMPLE
        ep
        Same as above using the ep alias.
    .OUTPUTS
        None
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
    .DESCRIPTION
        Emits all (or filtered) environment variables as KEY=VALUE strings sorted
        by name, mirroring the Unix env command output format for easy grepping
        and human scanning.
    .EXAMPLE
        Get-DFEnv
        Lists all environment variables in KEY=VALUE format, sorted by name.
    .EXAMPLE
        Get-DFEnv XDG*
        Lists only the XDG-prefixed environment variables.
    .OUTPUTS
        System.String — one KEY=VALUE string per matching environment variable.
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
    .DESCRIPTION
        Dot-sources $PROFILE in the current session so edits to aliases, functions,
        and module imports take effect immediately. Emits a warning if $PROFILE does
        not exist rather than silently succeeding.
    .EXAMPLE
        Invoke-DFProfileReload
        Re-applies all profile settings in the current session.
    .EXAMPLE
        reload
        Same as above using the reload alias — useful after editing the profile with ep.
    .OUTPUTS
        None
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
