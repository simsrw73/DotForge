#Requires -Version 7.2

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
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
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
function Get-DFLocationRoot {
    <#
    .SYNOPSIS
        Gets the root folder of the repository that holds the current location.
    .DESCRIPTION
        Walks up from the current folder to the nearest one that holds a .git, .jj
        or .hg entry and returns that folder the way Get-Location (pwd) does.
        A .git file counts as well as a .git folder, so inside a git worktree or
        a submodule the result is that worktree's or submodule's own root. It
        runs no external program.

        Outside a repository, or in a location that is not a file-system folder
        (HKCU:, Env:), it writes a warning and returns nothing.
    .EXAMPLE
        pwr

        Prints the root of the current repository, as pwd would print it from
        there.
    .EXAMPLE
        Get-ChildItem (Get-DFLocationRoot) -Filter *.md

        Lists the Markdown files at the root of the current repository.
    .OUTPUTS
        System.Management.Automation.PathInfo
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PathInfo])]
    param()
    $here = Get-Location
    if ($here.Provider.Name -ne 'FileSystem') {
        Write-Warning "'$here' is not a file-system folder."
        return
    }
    $markers = '.git', '.jj', '.hg'
    $folder = [IO.DirectoryInfo]::new((ConvertTo-DFPath $here.ProviderPath))
    while ($folder) {
        foreach ($marker in $markers) {
            if (Test-Path -LiteralPath (Join-Path $folder.FullName $marker)) {
                return Resolve-Path -LiteralPath $folder.FullName
            }
        }
        $folder = $folder.Parent
    }
    Write-Warning "'$($here.ProviderPath)' is not inside a repository (no .git, .jj or .hg found)."
}
function Set-DFLocationRoot {
    <#
    .SYNOPSIS
        Moves to the root folder of the repository that holds the current location.
    .DESCRIPTION
        Finds the root with Get-DFLocationRoot (the nearest folder above that
        holds a .git, .jj or .hg entry) and moves there, the way a plain cd moves
        to your home folder. Outside a repository it writes a warning and stays
        where it is. cd - returns to the folder you left.

        -WhatIf names the root without moving there; pwr (Get-DFLocationRoot)
        prints it as pwd does.
    .EXAMPLE
        cdr

        Moves to the root of the current repository.
    .EXAMPLE
        cdr -WhatIf

        Names the folder cdr would move to, and stays where it is.
    .OUTPUTS
        None
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $root = Get-DFLocationRoot
    if (-not $root) { return }
    if ($PSCmdlet.ShouldProcess($root.Path, 'Move to the repository root')) {
        Set-Location -LiteralPath $root.Path
    }
}
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
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )
    New-DFDirectory $Path
    Set-Location $Path
}
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
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
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
