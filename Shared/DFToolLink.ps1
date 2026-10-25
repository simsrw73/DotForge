#Requires -Version 7.2

# Links from an XDG location to a tool's existing data (docs/superpowers/specs/2026-10-25-link-existing-design.md).
# A link is removed by deleting the link entry itself, never recursively, so its target is never touched.

function Test-DFDeveloperMode {
    <#
    .SYNOPSIS
        Whether Windows Developer Mode is on, which lets a user make file symlinks without admin rights.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    (Get-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense -ErrorAction Ignore).AllowDevelopmentWithoutDevLicense -eq 1
}

function New-DFFileSymlink {
    <#
    .SYNOPSIS
        Makes a file symlink (the one place DotForge does; tests mock it).
    .PARAMETER Path
        The link to create.
    .PARAMETER Target
        The file it points to.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop
}

function Get-DFToolLinkTarget {
    <#
    .SYNOPSIS
        The target of a junction or symlink at a path, or $null when the path isn't a link. Finds a link whose target is gone too.
    .PARAMETER Path
        The path to look at.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $target = ([IO.DirectoryInfo]::new($Path)).LinkTarget ?? ([IO.FileInfo]::new($Path)).LinkTarget
    if ($target) { ConvertTo-DFPath $target }
}

function Remove-DFToolLink {
    <#
    .SYNOPSIS
        Removes a junction or symlink, never what it points to; does nothing when the path isn't a link.
    .PARAMETER Path
        The link.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $info = [IO.FileInfo]::new($Path)
    if (-not $info.LinkTarget) { return }
    # Non-recursive deletes of the link entry itself. A junction is a directory entry; a file
    # symlink is not, though DirectoryInfo reports a LinkTarget for it too.
    if ($info.Attributes -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
}

function Remove-DFEmptyFolder {
    <#
    .SYNOPSIS
        Deletes a folder that holds only empty folders, deepest first, one non-recursive delete at a time.
    .DESCRIPTION
        Each delete fails at the OS level when its folder isn't empty, so a file
        (even one written meanwhile, or one this process can't list) is never
        deleted: the call throws instead. A link inside is never removed or
        followed: its presence throws too.
    .PARAMETER Path
        The folder.
    .OUTPUTS
        None. Throws when the folder holds anything but empty folders.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $folders = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction Stop)
    if (@($folders | Where-Object LinkTarget).Count) { throw "$Path holds a link" }
    foreach ($folder in $folders | Sort-Object { $_.FullName.Length } -Descending) { [IO.Directory]::Delete($folder.FullName) }
    [IO.Directory]::Delete($Path)
}

function New-DFToolLink {
    <#
    .SYNOPSIS
        Links an XDG location to a tool's existing folder (a junction) or file (a symlink, with Developer Mode).
    .DESCRIPTION
        A junction needs no admin rights or Developer Mode. A file symlink needs
        Developer Mode; without it nothing is made and Note says so. A link
        already pointing at the target is left as it is. A folder at Path that
        holds only empty folders (one an earlier load created through
        xdg.dirs) is replaced (Remove-DFEmptyFolder). Anything else at Path
        throws: callers check that the XDG location is empty first.
    .PARAMETER Path
        The XDG location.
    .PARAMETER Target
        The existing folder or file.
    .OUTPUTS
        PSCustomObject: Path, Target, Made (bool), Note (string or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $Path = ConvertTo-DFPath $Path
    $Target = ConvertTo-DFPath $Target
    $result = [pscustomobject]@{ Path = $Path; Target = $Target; Made = $false; Note = $null }
    $existing = Get-DFToolLinkTarget -Path $Path
    if ($existing -eq $Target) { $result.Made = $true; return $result }
    if ($existing) { throw "DotForge: $Path is already a link to $existing, so it can't be linked to $Target." }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        try { Remove-DFEmptyFolder -Path $Path }
        catch { throw "DotForge: $Path holds content, so it can't be linked to $Target ($($_.Exception.Message))." }
    }
    if (Test-Path -LiteralPath $Path) { throw "DotForge: $Path already exists, so it can't be linked to $Target." }
    New-DFDirectory (Split-Path $Path -Parent)
    if (Test-Path -LiteralPath $Target -PathType Leaf) {
        if (-not (Test-DFDeveloperMode)) {
            $result.Note = "turn on Developer Mode to let DotForge link $Path to $Target"
            return $result
        }
        New-DFFileSymlink -Path $Path -Target $Target
    } else {
        $null = New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop
    }
    $result.Made = $true
    $result
}
