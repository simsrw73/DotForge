#Requires -Version 7.2

function Invoke-DFCommandCapture {
    <#
    .SYNOPSIS
        Private seam — runs an external command and returns its combined output + exit code.
    .DESCRIPTION
        Exists so tests can mock command execution without spawning a real process
        (mirrors the Invoke-DFFzf wrapper). Executables run with a time limit;
        functions, cmdlets, and aliases keep the normal PowerShell invocation path.
        Captured lines are joined with the platform newline, preserving the
        command's original line breaks.
    .PARAMETER Name
        The executable or command to run.
    .PARAMETER Arguments
        Arguments to pass to the command.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for an executable before it is stopped. Default: 10.
    .OUTPUTS
        PSCustomObject with Text, ExitCode, and TimedOut properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string[]]$Arguments = @(),

        [int]$TimeoutSeconds = 10
    )

    $application = Get-Command $Name -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($application) {
        try {
            $result = Invoke-DFBoundedProcess -FilePath $application.Source -ArgumentList $Arguments `
                -TimeoutSeconds $TimeoutSeconds -IncludeStandardError
            return [pscustomobject]@{
                Text     = ($result.Lines | ForEach-Object { "$_" }) -join [Environment]::NewLine
                ExitCode = $result.ExitCode
                TimedOut = $false
            }
        } catch {
            # Only the runner's time limit means "timed out"; anything else (the program
            # couldn't start, say) is a real error and surfaces as before.
            if ($_.Exception.Message -notlike '*did not finish within*') { throw }
            return [pscustomobject]@{
                Text     = ''
                ExitCode = -1
                TimedOut = $true
            }
        }
    }

    $output = & $Name @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    [pscustomobject]@{
        Text     = $text
        ExitCode = $exitCode
        TimedOut = $false
    }
}
