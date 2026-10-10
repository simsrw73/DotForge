#Requires -Version 7.2

function Register-DFTool {
    <#
    .SYNOPSIS
        Adds one or more tools to the current session, without restarting the shell.
    .DESCRIPTION
        Start-DFSession configures the tools your profile requests. Use
        Register-DFTool to add another tool (or +group) to the session you
        are in, for example to try one out, or after installing it.
        Install-DFTool calls it for the tools it installs.

        Each named tool goes through the same steps Start-DFSession uses: its
        record is read, role winners are recomputed over the session's tools
        plus the new ones, and an installed tool is set up (once ever) and
        activated:

          1. Its XDG configuration: the env vars in xdg.vars and the
             directories in xdg.dirs.
          2. The non-XDG env vars in its "env" block.
          3. Its aliases and wrapper functions, and its declarative picker.
          4. For each role it wins, that role's variables and aliases.
          5. Its companion Tools/<name>.ps1 and its role hooks; and once
             ever per machine, Tools/<name>.setup.ps1.

        A tool that isn't installed is reported as missing, a tool that fails
        is reported and the rest continue, and a tool you name is applied again
        even if it is already active (useful after changing its settings). Get-DFToolStatus shows the result. Registering a tool doesn't
        add it to your profile's Tools: add it there to load it in future
        sessions.

        Side effects: changes are scoped to the current session (env vars,
        functions, aliases, key bindings), except what a companion or setup
        script writes to disk: deployed config and theme files under
        $XDG_CONFIG_HOME, caches under $XDG_CACHE_HOME, the setup-state file,
        and for delta, one include.path line in your global git config. Some
        tools relocate their data to XDG paths, so a tool that already had
        files in its old default location stops seeing them.
    .PARAMETER Name
        Tool names and +groups to add. An unknown name warns and is skipped.
    .PARAMETER ToolsPath
        Read tool records and companions from this directory instead of the
        module's Tools folder. Intended for tests.
    .EXAMPLE
        Register-DFTool -Name glow

        Adds glow to this session.
    .EXAMPLE
        Register-DFTool +git

        Adds every tool in the +git group (delta, gh, lazygit) to this session.
    .OUTPUTS
        None. Changes the current session and may write the files listed above.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/safety.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [string]$ToolsPath
    )
    # An old-style global $DFConfig is no longer read; say so instead of silently
    # dropping its settings (some of them, like SkipSetup, are protections).
    Assert-DFSessionConfigured
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    # The session's requested tools plus the new ones, so role winners are
    # computed over everything requested; tools already active are skipped.
    $request = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:DFSessionStatus) {
        foreach ($s in $script:DFSessionStatus.Values) {
            if ($s.State -eq 'Excluded') { continue }
            $request.Add([pscustomobject]@{ Name = $s.Name; RequestedBy = $s.RequestedBy; Excluded = $false })
            $null = $seen.Add($s.Name)
        }
    }
    foreach ($e in @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs) -Source 'Register-DFTool')) {
        if ($seen.Add($e.Name)) { $e.RequestedBy = 'Register-DFTool'; $request.Add($e) }
    }

    # Tools you name are re-applied even if already active (e.g. after a config change).
    $reapply = @(foreach ($e in @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs) 3>$null)) { $e.Name })
    $active = @(Invoke-DFSessionActivation -Request $request.ToArray() -Reactivate $reapply @pathArgs)
    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) { Write-DFConflictNotice -Tools $active }
    Write-DFSessionNotice
}
