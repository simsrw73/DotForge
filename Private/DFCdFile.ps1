#Requires -Version 7.2

# Navigators that browse folders and, when you quit, write where you ended up to
# a file (broot's --outcmd, a file manager's cwd file). DotForge reads only the
# folder from that file and moves the shell there itself; it never runs the
# file. Design: docs/superpowers/specs/2026-10-17-directory-jump-design.md.

function ConvertFrom-DFShellCdLine {
    <#
    .SYNOPSIS
        Reads the folder from one POSIX-quoted cd line (cd 'C:\a b', with ' written as '"'"'); nothing else.
    .DESCRIPTION
        Accepts exactly one line of the form cd '<path>', where a single quote
        inside the path is written '"'"' as a POSIX shell would. Anything else
        (more lines, more words, another command, an unterminated quote)
        returns nothing, so the file's content is never treated as code.
    .PARAMETER Text
        The file's content.
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $line = $Text.TrimEnd("`r", "`n")
    if ($line -cnotmatch "^cd ((?:'[^']*'|`"'`")+)$") { return }
    $quoted = $Matches[1]
    $path = -join @([regex]::Matches($quoted, "'([^']*)'|`"'`"") | ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } else { "'" }
        })
    if ($path) { $path }
}

function Invoke-DFCdFileCommand {
    <#
    .SYNOPSIS
        Runs a navigator that writes the folder you quit in to a file, then moves the shell there.
    .DESCRIPTION
        {file} in -Arguments is replaced by a new temporary file. After the
        navigator exits with 0, the file is read as -Format ShellCd (one
        POSIX-quoted cd line, ConvertFrom-DFShellCdLine) or Path (the folder on
        its first line), and the shell moves there through Enter-DFDirectory.
        The file is always removed; its content is never run.
    .PARAMETER Executable
        The navigator.
    .PARAMETER Arguments
        Its arguments, with {file} where the cd file goes.
    .PARAMETER Format
        ShellCd or Path.
    .PARAMETER Run
        Runs the navigator and returns its exit code; for tests. Default: call it in this console.
    .OUTPUTS
        System.Boolean. Whether the shell moved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [ValidateSet('ShellCd', 'Path')][string]$Format = 'Path',
        [scriptblock]$Run = { param($Executable, $Arguments) & $Executable @Arguments; $LASTEXITCODE }
    )
    $file = New-TemporaryFile
    try {
        $argv = [string[]]@($Arguments | ForEach-Object { ([string]$_).Replace('{file}', $file.FullName) })
        $exitCode = & $Run $Executable $argv | Select-Object -Last 1
        if ($exitCode -ne 0) {
            Write-Host "DotForge: $([System.IO.Path]::GetFileName($Executable)) exited with code $exitCode" -ForegroundColor Red
            return $false
        }
        $text = [string](Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Ignore)
        $target = if ($Format -eq 'ShellCd') { ConvertFrom-DFShellCdLine -Text $text } else { ($text -split "`r?`n")[0].Trim() }
        if (-not $target) { return $false }
        Enter-DFDirectory -Path $target
    } finally {
        Remove-Item -LiteralPath $file.FullName -ErrorAction Ignore
    }
}
