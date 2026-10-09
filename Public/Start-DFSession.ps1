#Requires -Version 7.0

function Start-DFSession {
    <#
    .SYNOPSIS
        Configures the tools you request for this PowerShell session. Call it once, from your profile.
    .DESCRIPTION
        Start-DFSession is DotForge's profile entry point:
          1. Stores -Config as the session's configuration (unknown keys warn).
          2. Exports the XDG folders (XDG_CONFIG_HOME and the rest).
          3. Resolves Tools and ExcludeTools: +groups expand, exclusions win.
          4. Reads only the requested tools' records, checks which are
             installed, and picks role winners among them.
          5. Runs each installed tool's one-time setup (first time only), then
             activates it: environment variables, aliases, pickers, companion,
             role hook. One tool's failure never stops the rest.
          6. Checks for coreutils shadowing DotForge's commands (SkipConflictCheck
             turns this off).
          7. Warns about requested tools that aren't installed or failed, with
             the command that installs them.

        Tools that aren't requested are never looked at. Nothing is installed:
        run Install-DFTool -Missing for that. Calling Start-DFSession again
        applies the new config and activates newly requested tools; a tool no
        longer requested stays active until you open a new shell.

        Config keys (see docs/guide/configuration.md for all of them):
            Tools              Tool names and +groups to configure.
            ExcludeTools       Tool names and +groups to leave out.
            Defaults           Role -> preferred tool, e.g. @{ prompt = 'starship' }.
            Theme              Shared theme name.
            SkipSetup          Tools whose one-time setup never runs.
            SkipConflictCheck  $true skips the coreutils shadowing check.
            IgnoreConflicts    Command names left out of that check.
    .PARAMETER Config
        The session configuration hashtable. Required.
    .PARAMETER ToolsPath
        Read tool records and companions from this folder instead of the
        module's Tools/. For testing and custom tool sets.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession -Config @{ Tools = @('+core', 'starship'); ExcludeTools = @('less') }

        Configures every +core tool except less, plus starship.
    .EXAMPLE
        $DFConfig = @{ Tools = @('+core', '+git'); Defaults = @{ pager = 'moor' }; Theme = 'catppuccin-mocha' }
        Start-DFSession -Config $DFConfig

        Keeps the configuration in a variable of your own. DotForge doesn't read
        the variable itself, only what you pass.
    .OUTPUTS
        None. See Get-DFToolStatus for what the session decided.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    Set-DFSessionConfig -Config $Config
    Set-DFXdgEnvironment

    $request = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -ExcludeTools @(Get-DFConfig ExcludeTools) `
        -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs))

    # A second call only adds; a tool that is no longer requested can't be
    # cleanly undone (aliases, environment, prompt hooks), so say so.
    if ($script:DFSessionStatus) {
        $still = @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)
        $dropped = @($script:DFSessionStatus.Values | Where-Object { $_.State -eq 'Active' -and $_.Name -notin $still } | ForEach-Object Name)
        if ($dropped) {
            Write-Warning "DotForge: $($dropped -join ', ') $(if ($dropped.Count -eq 1) { 'is' } else { 'are' }) no longer requested but stay active until you open a new shell."
        }
    }

    $null = Invoke-DFSessionActivation -Request $request @pathArgs

    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) {
        $activeNames = @($script:DFSessionStatus.Values | Where-Object State -eq 'Active' | ForEach-Object Name)
        $active = if ($activeNames) { @((Import-DFToolDb -Name $activeNames @pathArgs).Values) } else { @() }
        Write-DFConflictNotice -Tools $active
    }
    Write-DFSessionNotice
}
