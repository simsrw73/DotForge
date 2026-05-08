#Requires -Version 7.0

function Set-DFLocationUp {
    <#
    .SYNOPSIS
        Navigates up one or more directory levels from the current location.
    .PARAMETER Levels
        Number of directory levels to ascend. Defaults to 1.
    .EXAMPLE
        Set-DFLocationUp
    .EXAMPLE
        up 3
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateRange(1, 99)]
        [int]$Levels = 1
    )
    $path = ('../' * $Levels).TrimEnd('/')
    Set-Location $path
}
Set-Alias -Name up -Value Set-DFLocationUp -Scope Global -Force

function New-DFDirectoryAndSet {
    <#
    .SYNOPSIS
        Creates a directory and immediately changes into it.
    .PARAMETER Path
        Path of the directory to create and enter.
    .EXAMPLE
        New-DFDirectoryAndSet src/lib
    .EXAMPLE
        mkcd ~/projects/newrepo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )
    New-DFDirectory $Path
    Set-Location $Path
}
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet -Scope Global -Force

function Select-DFLocation {
    <#
    .SYNOPSIS
        Fuzzy-searches subdirectories and changes to the selected one.
    .EXAMPLE
        Select-DFLocation
    .EXAMPLE
        fcd
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   {
            if (Get-Command fd -ErrorAction Ignore) {
                fd --type d 2>$null
            } else {
                Get-ChildItem -Recurse -Directory -ErrorAction Ignore |
                    Select-Object -ExpandProperty FullName
            }
        } `
        -Header 'Select directory  [Enter to cd]' `
        -Action { param($dir) Set-Location $dir }
}
Set-Alias -Name fcd -Value Select-DFLocation -Scope Global -Force
