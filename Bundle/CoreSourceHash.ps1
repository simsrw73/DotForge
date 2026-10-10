#Requires -Version 7.0
# Shared by DotForge.psm1 (does Bundle/DotForge.Core.ps1 match the sources?) and
# build/Build-DFCoreBundle.ps1 (which writes it). One definition, so they can't drift.

function Get-DFCoreSourceFile {
    <#
    .SYNOPSIS
        The startup core's source files, in load order: Shared/, Private/, Public/.
    .PARAMETER Root
        The module folder.
    .OUTPUTS
        System.IO.FileInfo[].
    #>
    param([Parameter(Mandatory)][string]$Root)
    foreach ($d in 'Shared', 'Private', 'Public') { Get-ChildItem -Path (Join-Path $Root $d) -Filter '*.ps1' }
}

function Get-DFCoreSourceText {
    <#
    .SYNOPSIS
        A source file's text as bundled and hashed: BOM removed, line endings LF.
    .PARAMETER Path
        The file.
    .OUTPUTS
        System.String.
    #>
    param([Parameter(Mandatory)][string]$Path)
    [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
}

function Get-DFCoreSourceHash {
    <#
    .SYNOPSIS
        SHA-256 over the core's sources (relative path + normalized text, in load order).
    .PARAMETER Root
        The module folder.
    .OUTPUTS
        System.String. Lowercase hex.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    foreach ($f in Get-DFCoreSourceFile -Root $Root) {
        $rel = [IO.Path]::GetRelativePath($Root, $f.FullName).Replace('\', '/')
        $sha.AppendData([Text.Encoding]::UTF8.GetBytes("$rel`n$(Get-DFCoreSourceText -Path $f.FullName)`n"))
    }
    [Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant()
}
