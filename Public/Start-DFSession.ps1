#Requires -Version 7.2

function Start-DFSession {
    <#
    .SYNOPSIS
        Configures the tools you request for this PowerShell session. Call it once, from your profile.
    .DESCRIPTION
        Start-DFSession is DotForge's profile entry point:
          1. Stores the configuration (unknown keys warn): -Config when given,
             else the config file, $XDG_CONFIG_HOME/dotforge/config.psd1
             (~/.config/dotforge/config.psd1). -Config replaces the file
             entirely; the two are never merged. The file is a PowerShell data
             file (literal values and comments, no code). A missing or
             unreadable file warns, naming it, and configures nothing.
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

        With ShowBanner, it clears the screen (unless BannerClear is $false)
        and prints one line at once; slow banner work (fastfetch, drive health,
        the public IP) runs in the background while tools load, and the banner
        prints a line at a time when the load ends.

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
        The session configuration hashtable. Optional: without it, the config
        file is read. When given, the config file is not read at all.
    .PARAMETER ToolsPath
        Read tool records and companions from this folder instead of the
        module's Tools/. For testing and custom tool sets.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession

        Configures what ~/.config/dotforge/config.psd1 asks for, e.g. a file
        holding @{ Tools = @('+core', 'starship'); Theme = 'catppuccin-mocha' }.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession -Config @{ Tools = @('+core', 'starship'); ExcludeTools = @('less') }

        Configures every +core tool except less, plus starship, ignoring the config file.
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
        [System.Collections.IDictionary]$Config,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    Write-DFDevBuildNotice
    # -Config replaces the config file entirely; the two are never merged.
    if (-not $PSBoundParameters.ContainsKey('Config')) { $Config = Read-DFConfigFile }
    Set-DFSessionConfig -Config $Config
    Set-DFXdgEnvironment

    $request = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -ExcludeTools @(Get-DFConfig ExcludeTools) `
        -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs))
    # ShowBanner: the first line now, the rest's slow parts in the background while tools load.
    $banner = Start-DFBanner -Tools @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)

    # A second call only adds; a tool that is no longer requested can't be
    # cleanly undone (aliases, environment, prompt hooks), so say so.
    if ($script:DFSessionStatus) {
        $still = @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)
        $dropped = @($script:DFSessionStatus.Values | Where-Object { $_.State -eq 'Active' -and $_.Name -notin $still } | ForEach-Object Name)
        if ($dropped) {
            Write-Warning "DotForge: $($dropped -join ', ') $(if ($dropped.Count -eq 1) { 'is' } else { 'are' }) no longer requested but stay active until you open a new shell."
        }
    }

    $shown = $false
    try {
        $null = Invoke-DFSessionActivation -Request $request @pathArgs
        # Before the notices, so warnings print under the banner.
        Show-DFBanner -State $banner
        $shown = $true
    } finally {
        # A failed or stopped load leaves no banner work running.
        if (-not $shown) { Stop-DFBanner -State $banner }
        Set-DFBannerSessionStarted
    }

    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) {
        $activeNames = @($script:DFSessionStatus.Values | Where-Object State -eq 'Active' | ForEach-Object Name)
        $active = if ($activeNames) { @((Import-DFToolDb -Name $activeNames @pathArgs).Values) } else { @() }
        Write-DFConflictNotice -Tools $active
    }
    Write-DFSessionNotice
}
