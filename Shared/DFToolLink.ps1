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
    # Non-recursive deletes of the link entry: a junction is deleted as an empty directory.
    if (([IO.DirectoryInfo]::new($Path)).LinkTarget) { [IO.Directory]::Delete($Path) }
    elseif (([IO.FileInfo]::new($Path)).LinkTarget) { [IO.File]::Delete($Path) }
}

function New-DFToolLink {
    <#
    .SYNOPSIS
        Links an XDG location to a tool's existing folder (a junction) or file (a symlink, with Developer Mode).
    .DESCRIPTION
        A junction needs no admin rights or Developer Mode. A file symlink needs
        Developer Mode; without it nothing is made and Note says so. A link
        already pointing at the target is left as it is. An empty folder at
        Path (no files and no links anywhere below it, such as one an earlier
        load created through xdg.dirs) is replaced. Anything else at Path
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
    if (-not $existing -and (Test-Path -LiteralPath $Path -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Ignore | Where-Object { -not $_.PSIsContainer -or $_.LinkTarget })) {
        [IO.Directory]::Delete($Path, $true)
    }
    if ($existing -or (Test-Path -LiteralPath $Path)) { throw "DotForge: $Path already exists, so it can't be linked to $Target." }
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

function Set-DFToolLinkState {
    <#
    .SYNOPSIS
        Records, for this session, the links a tool's ownership check made or kept (registration reads them).
    .PARAMETER Name
        The tool.
    .PARAMETER Links
        Its ownership entry's links (key, path, target, made); empty when it has none.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Links = @())
    if ($script:DFToolLinks -isnot [hashtable]) { $script:DFToolLinks = @{} }
    $script:DFToolLinks[$Name] = @($Links)
}

function Get-DFToolLinkedVar {
    <#
    .SYNOPSIS
        The variables of a tool that point at linked existing data, which registration must not set.
    .PARAMETER Name
        The tool.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFToolLinks -isnot [hashtable] -or -not $script:DFToolLinks.ContainsKey($Name)) { return [string[]]@() }
    [string[]]@($script:DFToolLinks[$Name] | ForEach-Object key | Where-Object { $_ -cnotmatch '^\$\{' })
}

function Test-DFInLinkedPath {
    <#
    .SYNOPSIS
        Whether a path is a tool's linked XDG location or inside it (DotForge never writes there: it's the user's existing data).
    .PARAMETER Name
        The tool.
    .PARAMETER Path
        A canonical path.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    if ($script:DFToolLinks -isnot [hashtable] -or -not $script:DFToolLinks.ContainsKey($Name)) { return $false }
    $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($link in $script:DFToolLinks[$Name]) {
        if ($Path -eq $link.path -or $Path.StartsWith($link.path + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}
