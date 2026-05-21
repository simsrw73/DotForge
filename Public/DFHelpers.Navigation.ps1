#Requires -Version 7.0

function Set-DFLocationUp {
    <#
    .SYNOPSIS
        Navigates up one or more directory levels from the current location.
    .PARAMETER Levels
        Number of directory levels to ascend. Defaults to 1.
    .DESCRIPTION
        Constructs a relative path of N repeated '../' segments and passes it to
        Set-Location, providing a concise alternative to chaining multiple cd ..
        commands when navigating out of deeply nested directories.
    .EXAMPLE
        Set-DFLocationUp
        Moves up one directory level (equivalent to cd ..).
    .EXAMPLE
        up 3
        Moves up three directory levels at once using the up alias.
    .OUTPUTS
        None
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
    .DESCRIPTION
        Combines New-DFDirectory and Set-Location into a single command, mirroring
        the common mkcd shell function. Creates all intermediate directories as
        needed before changing into the final path.
    .EXAMPLE
        New-DFDirectoryAndSet src/lib
        Creates the src/lib directory tree (if needed) and changes into it.
    .EXAMPLE
        mkcd ~/projects/newrepo
        Creates and enters a new project directory using the mkcd alias.
    .OUTPUTS
        None
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
    .DESCRIPTION
        Uses fd (if available) or Get-ChildItem -Recurse -Directory to enumerate
        subdirectories, then presents them in fzf. Selecting a directory immediately
        changes the session location to it. Falls back gracefully when fd is not
        installed.
    .EXAMPLE
        Select-DFLocation
        Opens fzf over all subdirectories; selecting one changes into it.
    .EXAMPLE
        fcd
        Same as above using the fcd alias.
    .OUTPUTS
        None
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
