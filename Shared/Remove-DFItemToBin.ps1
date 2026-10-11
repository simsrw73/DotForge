#Requires -Version 7.2

function Remove-DFItemToBin {
    <#
    .SYNOPSIS
        Moves an old config file or folder out of the tool's way, recoverably.
    .DESCRIPTION
        Renames it to <leaf>.dotforge-moved first: that fails cleanly, with no
        window, when anything inside is in use. On Windows the renamed item
        then goes to the Recycle Bin; if that step fails, the renamed copy
        stays where it is, which still counts as removed.
    .PARAMETER Path
        The old location.
    .OUTPUTS
        None. Throws when the rename fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $movedName = (Split-Path $Path -Leaf) + '.dotforge-moved'
    $moved = Join-Path (Split-Path $Path) $movedName
    Rename-Item -LiteralPath $Path -NewName $movedName -ErrorAction Stop
    if (-not $IsWindows) { return }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $bin = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        if (Test-Path -LiteralPath $moved -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($moved, $ui, $bin) }
        else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($moved, $ui, $bin) }
    } catch {
        Write-Verbose "DotForge: $moved stays where it is: $($_.Exception.Message)"
    }
}
