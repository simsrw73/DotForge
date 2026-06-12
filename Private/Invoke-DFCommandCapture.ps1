#Requires -Version 7.0

function Invoke-DFCommandCapture {
    <#
    .SYNOPSIS
        Private seam — runs an external command and returns its combined output + exit code.
    .DESCRIPTION
        Exists so tests can mock command execution without spawning a real process
        (mirrors the Invoke-DFFzf wrapper). Runs `& $Name @Arguments 2>&1`, joins the
        result into one string, and returns it alongside $LASTEXITCODE.
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
    $global:LASTEXITCODE = 0
    $text = (& $Name @Arguments 2>&1 | Out-String)
    [pscustomobject]@{
        Text     = $text
        ExitCode = $LASTEXITCODE
    }
}
