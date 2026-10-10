#Requires -Version 7.0

function Expand-DFInstallArgv {
    <#
    .SYNOPSIS
        Fills a manager's argv template: {id} becomes every id, other {name} tokens come from -Values.
    .PARAMETER Template
        The argv template from installs.command or installs.feeds. A token
        that is exactly {id} expands to every id; a token containing {id}
        (pkg@{id}) is repeated once per id.
    .PARAMETER Values
        ids (string[]) plus any other token values (name, url).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string[]]$Template, [Parameter(Mandatory)][hashtable]$Values)
    [string[]]@(foreach ($t in $Template) {
        $fill = { param($text) [regex]::Replace($text, '\{(\w+)\}', { param($m) [string]$Values[$m.Groups[1].Value] }) }
        if ($t -eq '{id}') { @($Values.ids) }
        # {id} inside a token (node@{id}) gives one argument per id.
        elseif ($t.Contains('{id}')) { foreach ($i in @($Values.ids)) { & $fill $t.Replace('{id}', $i) } }
        else { & $fill $t }
    })
}

function Invoke-DFInstallCommand {
    <#
    .SYNOPSIS
        Runs one package-manager command and returns its exit code and output. The only place DotForge runs a manager.
    .DESCRIPTION
        An argv runs as a native command; a function (installs.function, e.g.
        Install-PSResource) is called with -Arguments splatted. -Elevate runs
        the argv through -ElevateWith (the elevator role's executable, e.g.
        gsudo). Tests mock this function.
    .PARAMETER Manager
        The manager's tool record (for messages).
    .PARAMETER Argv
        The command line, already expanded.
    .PARAMETER Function
        A PowerShell command to call instead of an argv.
    .PARAMETER Arguments
        Parameters for -Function.
    .PARAMETER Elevate
        Run through -ElevateWith.
    .PARAMETER ElevateWith
        The elevator's executable.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [string[]]$Argv = @(),
        [string]$Function,
        [hashtable]$Arguments = @{},
        [switch]$Elevate,
        [string]$ElevateWith
    )
    if ($Function) {
        try {
            $out = & $Function @Arguments -ErrorAction Stop 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = 0; Output = $out }
        } catch {
            return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
        }
    }
    $exe, $rest = if ($Elevate) { $ElevateWith, $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
    # A manager can resolve to a .ps1 shim (scoop.ps1) that runs in-process and
    # never sets an exit code: don't read a stale one from an earlier command.
    $global:LASTEXITCODE = 0
    $out = & $exe @rest 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}
