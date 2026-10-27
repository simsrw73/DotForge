#Requires -Version 7.2

function Expand-DFInstallArgv {
    <#
    .SYNOPSIS
        Fills a manager's argv template: {id} becomes every id, other {name} tokens come from -Values.
    .PARAMETER Template
        The argv template from installs.install or installs.feeds. A token
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

function Invoke-DFManagerCommand {
    <#
    .SYNOPSIS
        Runs one package-manager command and returns its exit code and output. The only place DotForge runs a manager.
    .DESCRIPTION
        Serves every operation (install, update, remove, list, outdated). An
        argv runs as a native command; a function (Install-PSResource,
        Update-PSResource) is called with -Arguments splatted. -Elevation, from
        Get-DFElevationMethod, says how to get administrator rights: an
        elevator (gsudo) or Windows' sudo runs the argv in this console; RunAs
        opens a separate administrator window, whose output can't be read, so
        only its exit code comes back; Unavailable runs nothing and says why.
        Tests mock this function.
    .PARAMETER Operation
        install, update, remove, list or outdated (for messages).
    .PARAMETER Manager
        The manager's tool record (for messages).
    .PARAMETER Argv
        The command line, already expanded.
    .PARAMETER Function
        A PowerShell command to call instead of an argv. One that outputs
        { DFSkipped = <why> } is reported as skipped (ExitCode -1), not done.
    .PARAMETER Arguments
        Parameters for -Function.
    .PARAMETER Elevation
        From Get-DFElevationMethod; omit (or $null) when the command doesn't need administrator rights.
    .PARAMETER Environment
        Variables the command sees while it runs (Get-DFInstallEnvironment).
        One set outside DotForge is kept; one unset or still holding what
        DotForge wrote (Get-DFEnvState) is set. Afterwards each goes back to
        its previous value, even when the command throws, unless the command
        changed it itself (scoop's in-process shim saves some to the Windows
        environment), so the session agrees with the manager. A separate
        administrator window (RunAs) starts from the saved user environment
        and doesn't get them, nor does Windows' sudo: then a warning and the
        output name the variables not passed. gsudo passes them.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'remove', 'list', 'outdated')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [string[]]$Argv = @(),
        [string]$Function,
        [hashtable]$Arguments = @{},
        [pscustomobject]$Elevation,
        [System.Collections.IDictionary]$Environment
    )
    $changes = @(if ($Environment) { Set-DFCommandEnvironment -Environment $Environment -Manager $Manager.name })
    try {
        if ($Function) {
            # A manager's own functions live in its Tools/<name>.manage.ps1, loaded when first needed.
            if (-not (Get-Command $Function -ErrorAction Ignore)) { Import-DFManagerOps -Manager $Manager }
            try {
                $raw = @(& $Function @Arguments -ErrorAction Stop 2>&1)
                # A function that can't do it (a tool that updates itself) answers { DFSkipped = <why> }: Skipped, not done.
                $skip = $raw | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['DFSkipped'] } | Select-Object -First 1
                if ($skip) { return [pscustomobject]@{ ExitCode = -1; Output = [string]$skip.DFSkipped } }
                return [pscustomobject]@{ ExitCode = 0; Output = ($raw | Out-String) }
            } catch {
                return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
            }
        }
        $method = if ($Elevation) { $Elevation.Method } else { 'None' }
        if ($method -eq 'Unavailable') {
            return [pscustomobject]@{ ExitCode = 1; Output = "$($Manager.name) needs administrator rights: $($Elevation.Detail)" }
        }
        if ($method -eq 'RunAs') {
            # Start-Process joins -ArgumentList with spaces, so quote what would split.
            $quoted = @($Argv | Select-Object -Skip 1 | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
            try {
                $process = Start-Process -FilePath $Argv[0] -ArgumentList $quoted -Verb RunAs -Wait -PassThru -ErrorAction Stop
            } catch {
                # A declined UAC prompt is Win32 error 1223 (ERROR_CANCELLED), usually wrapped by Start-Process.
                $win32 = @($_.Exception, $_.Exception.InnerException) | Where-Object { $_ -is [System.ComponentModel.Win32Exception] } | Select-Object -First 1
                $code = if ($win32) { $win32.NativeErrorCode } else { 1 }
                return [pscustomobject]@{ ExitCode = $code; Output = "the administrator prompt was declined or failed: $($_.Exception.Message)" }
            }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = "ran in a separate administrator window (exit code $($process.ExitCode))" }
        }
        $exe, $rest = if ($method -in 'Elevator', 'WindowsSudo') { $Elevation.Executable, $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
        # A manager can resolve to a .ps1 shim (scoop.ps1) that runs in-process and
        # never sets an exit code: don't read a stale one from an earlier command.
        $global:LASTEXITCODE = 0
        # *>&1, not 2>&1: an in-process .ps1 shim also writes to the host and the
        # warning stream (scoop's "Installed apps:"), which would print mid-command.
        $items = & $exe @rest *>&1
        # list and outdated output is parsed: keep stderr and warnings out of it
        # (pip's "[notice] A new release of pip is available" would break its JSON).
        if ($Operation -in 'list', 'outdated') {
            $items = $items | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] }
        }
        $out = $items | Out-String
        $exitCode = $LASTEXITCODE
        # Windows' sudo starts the elevated command without this process's
        # environment (checked 2026-10-25; gsudo passes it).
        if ($method -eq 'WindowsSudo' -and $Environment -and $Environment.Count) {
            $note = "DotForge's install variables were not passed through Windows' sudo: $(@($Environment.Keys) -join ', ')"
            Write-Warning "DotForge: $($Manager.name): $note. The install may use the tool's default folders; installing gsudo avoids this."
            $out += "($note)"
        }
        [pscustomobject]@{ ExitCode = $exitCode; Output = $out }
    } finally {
        Restore-DFCommandEnvironment -Changes $changes
    }
}

function Set-DFCommandEnvironment {
    <#
    .SYNOPSIS
        Sets a manager command's variables in this process, keeping any set outside DotForge, and returns what it changed.
    .PARAMETER Environment
        Variable -> value (Get-DFInstallEnvironment).
    .PARAMETER Manager
        The manager's name (for messages).
    .OUTPUTS
        PSCustomObject per variable set: Name, Previous ($null when unset), Value.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [string]$Manager)
    $written = (Get-DFEnvState).Written
    foreach ($name in @($Environment.Keys)) {
        $value = [string]$Environment[$name]
        $current = [Environment]::GetEnvironmentVariable($name)
        if ($current -ceq $value) { continue }
        # Set-DFEnv's rule: a value DotForge didn't write was set outside it.
        if ($null -ne $current -and -not ($written.ContainsKey($name) -and $written[$name] -ceq $current)) {
            Write-Verbose "DotForge: keeping $name=$current, set outside DotForge, for this $Manager command."
            continue
        }
        [Environment]::SetEnvironmentVariable($name, $value)
        [pscustomobject]@{ Name = $name; Previous = $current; Value = $value }
    }
}

function Restore-DFCommandEnvironment {
    <#
    .SYNOPSIS
        Puts back the variables Set-DFCommandEnvironment changed, except one the command itself changed since.
    .PARAMETER Changes
        Set-DFCommandEnvironment's result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Changes = @())
    foreach ($change in $Changes) {
        if ([Environment]::GetEnvironmentVariable($change.Name) -cne $change.Value) { continue }
        # ($null would reach .NET as "", which leaves the variable set but empty.)
        $previous = if ($null -eq $change.Previous) { [NullString]::Value } else { $change.Previous }
        [Environment]::SetEnvironmentVariable($change.Name, $previous)
    }
}
