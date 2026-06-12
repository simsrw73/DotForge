#Requires -Version 7.0

function Invoke-DFCommandCapture {
    <#
    .SYNOPSIS
        Private seam — runs an external command and returns its combined output + exit code.
    .DESCRIPTION
        Exists so tests can mock command execution without spawning a real process
        (mirrors the Invoke-DFFzf wrapper). Runs `& $Name @Arguments 2>&1`, joins the
        captured lines with the platform newline (preserving the command's original line breaks),
        and returns the text alongside $LASTEXITCODE.
    .PARAMETER Name
        The executable or command to run.
    .PARAMETER Arguments
        Arguments to pass to the command.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string[]]$Arguments = @()
    )
    $output = & $Name @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    [pscustomobject]@{
        Text     = $text
        ExitCode = $exitCode
    }
}
