#Requires -Version 7.2

function Invoke-DFBoundedProcess {
    <#
    .SYNOPSIS
        Runs an executable with a time limit and returns its output lines and exit code.
    .DESCRIPTION
        For outside programs that can hang (winget waiting on a source update or
        a stuck network call). Standard output is captured and split into lines
        the way PowerShell splits a native command's output; standard error is
        discarded unless -IncludeStandardError is set. A process still running after -TimeoutSeconds is killed with
        its child processes, and the call throws, naming the command.
        Output is decoded with [Console]::OutputEncoding, as `& exe` would.
    .PARAMETER FilePath
        The executable's full path.
    .PARAMETER ArgumentList
        Arguments, each passed as one argument (no quoting needed).
    .PARAMETER TimeoutSeconds
        How long to wait before killing the process.
    .PARAMETER IncludeStandardError
        Include standard error lines after the standard output lines. The
        original interleaving of the two streams is not preserved.
    .OUTPUTS
        pscustomobject: Lines (string[]), ExitCode (int).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSeconds,
        [switch]$IncludeStandardError
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Console]::OutputEncoding
    $startInfo.StandardErrorEncoding = [Console]::OutputEncoding

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        # Read both streams asynchronously: a full, unread pipe would block the child.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Verbose "DotForge: couldn't kill '$FilePath': $($_.Exception.Message)" }
            $command = (@([System.IO.Path]::GetFileName($FilePath)) + $ArgumentList) -join ' '
            throw "DotForge: '$command' did not finish within $TimeoutSeconds s and was stopped."
        }
        $process.WaitForExit()   # lets the redirected streams drain
        $text = $stdout.GetAwaiter().GetResult()
        $lines = @($text -split '\r?\n')
        if ($lines.Count -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
        if ($IncludeStandardError) {
            $errorText = $stderr.GetAwaiter().GetResult()
            $errorLines = @($errorText -split '\r?\n')
            if ($errorLines.Count -and $errorLines[-1] -eq '') { $errorLines = @($errorLines | Select-Object -SkipLast 1) }
            $lines = @($lines) + @($errorLines)
        }
        [pscustomobject]@{ Lines = [string[]]$lines; ExitCode = $process.ExitCode }
    } finally {
        $process.Dispose()
    }
}
