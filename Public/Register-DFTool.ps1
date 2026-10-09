#Requires -Version 7.0

function Register-DFTool {
    <#
    .SYNOPSIS
        Configures one or more known CLI tools in the current session.
    .DESCRIPTION
        For each requested tool that is installed (its executable is on PATH,
        or for a "type": "module" tool, the module is available), Register-DFTool:

          1. Applies its XDG configuration: sets the env vars in xdg.vars and
             creates the directories in xdg.dirs.
          2. Sets the non-XDG env vars in its "env" block (e.g. FZF_DEFAULT_OPTS,
             LESS) for the current process.
          3. Defines its aliases and wrapper functions.
          4. Builds its declarative fzf picker function, if it declares one.
          5. For each role it wins (see Get-DFRole), applies that role's
             variables and aliases. Roles it loses are skipped entirely.
          6. Dot-sources its companion Tools/<name>.ps1, if one exists, then
             runs the companion's hook for each role it won, and runs
             Tools/<name>.setup.ps1 once ever per machine (tracked in
             $XDG_STATE_HOME\dotforge\setup-state.json).

        Tools that aren't installed are skipped silently (use -Verbose to see
        them). Tools are registered in dependency order, honoring "dependsOn".
        If one tool fails (a companion throws, or any error under
        $ErrorActionPreference = 'Stop'), DotForge warns with its name and
        goes on with the rest. After the loop it warns once if Coreutils for
        Windows shadows any DotForge command (see Get-DFCommandConflict).

        $DFConfig keys read:
            SkipTools          tool names excluded from -All
            SkipSetup          tool names whose one-time setup script never runs
            Defaults           role -> tool, e.g. @{ prompt = 'starship'; pager = 'bat' };
                               picks the winner of each role. Without it the
                               highest-priority installed tool wins (with a
                               one-time warning for prompt, project-env and
                               navigation)
            SkipConflictCheck  $true disables the coreutils shadowing warning
            IgnoreConflicts    command names left out of that warning
        Tool companions also read their own keys (Theme, <Tool>Theme,
        PSReadLineEditMode, ShimsPath, …).

        Side effects: changes are scoped to the current session (env vars,
        functions, aliases, key bindings), except what a companion or setup
        script writes to disk: deployed config and theme files under
        $XDG_CONFIG_HOME, caches under $XDG_CACHE_HOME, the setup-state file,
        and for delta, one include.path line in your global git config. Some
        tools relocate their data to XDG paths, so a tool that already had files
        in its old default location stops seeing them.
    .PARAMETER Name
        One or more tool names to configure. An unknown name writes a warning
        and is skipped. $DFConfig['SkipTools'] is not applied to names you list
        explicitly.
    .PARAMETER All
        Configure every known tool that is installed, except those in
        $DFConfig['SkipTools'].
    .PARAMETER ToolsPath
        Read tool records and companions from this directory instead of the
        module's Tools folder. Intended for tests.
    .EXAMPLE
        Register-DFTool -All

        Configures every installed tool in one call. Typical profile usage.
    .EXAMPLE
        Register-DFTool -Name psreadline, PSFzf

        Configures only psreadline and PSFzf (in dependency order).
    .EXAMPLE
        $DFConfig = @{ Defaults = @{ listing = 'eza'; prompt = 'starship' } }
        Import-Module DotForge
        Register-DFTool -All -Verbose

        Gives ls/ll/la/tree to eza and the prompt to starship (lsd and
        oh-my-posh stay usable by name), and prints which tools were
        registered or skipped.
    .OUTPUTS
        None. Changes the current session and may write the files listed above.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/safety.md
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFToolDb')]
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName')]
        [string[]]$Name,
        [Parameter(ParameterSetName = 'All')]
        [switch]$All,
        [string]$ToolsPath
    )

    if (-not $Name -and -not $All) {
        Write-Error 'Specify -Name <tool> or -All.' -ErrorAction Stop
        return
    }

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs
    # An old-style global $DFConfig is no longer read; say so instead of silently
    # dropping its settings (some of them, like SkipSetup, are protections).
    Assert-DFSessionConfigured

    $resolvedToolsPath = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath } else { Join-Path $PSScriptRoot '../Tools' })

    $tools       = Invoke-DFTopoSort -Tools @(Get-DFRegistrationSet -ToolDb $db -Name $Name -All:$All)
    $roleDb      = Get-DFRoleDb
    $roleWinners = Get-DFRoleWinners -ToolDb $db -Tools $tools -RoleDb $roleDb
    Write-DFRoleNotice -RoleWinners $roleWinners -RoleDb $roleDb
    $skipSetup   = @(Get-DFConfig SkipSetup)

    # Pre-import the module tools in a background thread so their real import
    # below is faster (warm OS caches); see Start-DFModulePrewarm. A tool opts out
    # with "prewarm": false.
    $prewarmModules = @($tools | Where-Object {
        $_.type -eq 'module' -and $_.prewarm -and (Test-DFToolAvailable -Executable $_.executable -Type 'module')
    } | ForEach-Object executable)
    $prewarmJob = if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
    try {
        foreach ($tool in $tools) {
            if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type)) {
                Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
                continue
            }
            # One tool's failure (most often a throwing companion, or any error under a
            # profile's $ErrorActionPreference = 'Stop') must not abort every tool after it.
            try {
                Invoke-DFToolRegistration -Tool $tool -RoleWinners $roleWinners -ToolsPath $resolvedToolsPath -SkipSetup $skipSetup -RoleDb $roleDb
            } catch {
                Write-Warning "DotForge: $($tool.name) failed to register: $($_.Exception.Message)"
                continue
            }
            Write-Verbose "DotForge: $($tool.name) registered"
        }
        if (-not (Get-DFConfig SkipConflictCheck -Default $false)) { Write-DFConflictNotice -Tools $tools }
    } finally {
        # Even if a companion throws or registration is interrupted, so the job
        # never lingers in Get-Job. Nothing needs its result.
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
    }
}
