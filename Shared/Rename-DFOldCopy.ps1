#Requires -Version 7.2

function Rename-DFOldCopy {
    <#
    .SYNOPSIS
        Moves a moved tool's old config out of the tool's way by renaming it next to where it was.
    .DESCRIPTION
        Renames it to <name>.dotforge-moved, or <name>.dotforge-moved-2, -3, ...
        when an earlier copy holds that name. Nothing is deleted and no window
        opens: the user deletes the renamed copy when satisfied. The rename
        fails cleanly when anything inside is in use.
    .PARAMETER Path
        The old location.
    .OUTPUTS
        System.String: the renamed copy's path. Throws when the rename fails.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $parent = Split-Path $Path
    $name = (Split-Path $Path -Leaf) + '.dotforge-moved'
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $parent $name)) {
        $n++
        $name = (Split-Path $Path -Leaf) + ".dotforge-moved-$n"
    }
    Rename-Item -LiteralPath $Path -NewName $name -ErrorAction Stop
    Join-Path $parent $name
}
