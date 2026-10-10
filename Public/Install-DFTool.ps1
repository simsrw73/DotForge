#Requires -Version 7.2

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs missing tools: everything the session reported missing (-Missing), or the named tools.
    .DESCRIPTION
        Builds one plan for all targets: a source and manager per tool
        (InstallVia, the tool's install.prefer, InstallOrder, DotForge's
        order; ExcludeSources never used unless InstallVia names it), in
        stages so that a manager or runtime installs before the tools that
        need it. Nothing you didn't ask for is installed, unless you choose it
        or pass -UseDefaults.

        Modes:
          - Interactive (default, when someone can answer): each open choice
            shows its default ("Enter keeps it"); then the whole plan is shown,
            including third-party feeds and elevation, and confirmed once.
          - -UseDefaults: no questions; DotForge's and the tool specs'
            defaults fill every gap.
          - No one to ask and no -UseDefaults (a script): only what needs no
            decision installs; each gap is reported with the tools waiting on it.
          - -WhatIf: the plan only.
          - -Confirm:$false: interactive, but without the final confirmation.

        Afterwards, new tools are activated in this session. A tool you named
        that isn't in your Tools setting is active only until the shell closes.
    .PARAMETER Missing
        Install the tools Get-DFToolStatus -Missing lists.
    .PARAMETER Name
        Tools (and +groups) to install.
    .PARAMETER Via
        Install the named tools from this source, for this call only.
    .PARAMETER UseDefaults
        Don't ask: take the default for every open choice.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Install-DFTool -Missing

        Asks about anything undecided, shows the plan, and installs it.
    .EXAMPLE
        Install-DFTool -Name glow -Via scoop -UseDefaults

        Installs glow from scoop without asking.
    .EXAMPLE
        Install-DFTool -Missing -WhatIf

        Shows what would be installed, in which stage, and from where.
    .OUTPUTS
        PSCustomObject. One per tool: Tool, Result (Installed, Failed, Skipped, NotFound, Gap), Detail.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Missing')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Missing')][switch]$Missing,
        [Parameter(Mandatory, ParameterSetName = 'Name')][string[]]$Name,
        [Parameter(ParameterSetName = 'Name')][string]$Via,
        [switch]$UseDefaults,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @pathArgs

    $targets = if ($Missing) {
        @(Get-DFToolStatus -Missing 3>$null | ForEach-Object { $_.Name })
    } else {
        @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) -Source 'Install-DFTool' | ForEach-Object { $_.Name })
    }
    # Fresh checks (a previous partial run may have installed some of these),
    # each made once per call: the question loop below re-plans after every answer.
    # (Found through the caller's scope when New-DFInstallPlan invokes it; a
    # GetNewClosure() copy would lose the module's private functions.)
    $dfInstallChecked = @{}
    $isAvailable = {
        param($r)
        if (-not $r) { return $false }
        if (-not $dfInstallChecked.ContainsKey($r.name)) {
            $dfInstallChecked[$r.name] = [bool](Test-DFToolAvailable -Executable $r.executable -Type $r.type -Force)
        }
        $dfInstallChecked[$r.name]
    }
    $targets = @($targets | Where-Object { $db.ContainsKey($_) -and -not (& $isAvailable $db[$_]) })
    if (-not $targets) { Write-Host 'DotForge: nothing to install.'; return }

    $viaMap = @{}
    if ($Via) { foreach ($t in $targets) { $viaMap[$t] = $Via } }

    # Choices: one question per open gap source, until nothing more can be decided.
    $interactive = -not $UseDefaults -and (Test-DFInteractiveHost)
    $choice = @{}
    # Planning warnings (an InstallVia that doesn't apply) repeat every round: show each once.
    $script:DFInstallWarned = [System.Collections.Generic.HashSet[string]]::new()
    while ($true) {
        $plan = New-DFInstallPlan -Name $targets -ToolDb $db -IsAvailable $isAvailable -Choice $choice -Via $viaMap
        $open = @($plan.Gaps | Where-Object { $_.Options -and $_.Source -and -not $choice.ContainsKey($_.Source) })
        if (-not $open -or -not ($UseDefaults -or $interactive)) { break }
        $g = $open[0]
        $choice[$g.Source] = if ($UseDefaults) { $g.Options[0] }
            else { Read-DFInstallChoice -Prompt "$($g.Tool) needs a manager for $($g.Source)" -Options $g.Options -Default $g.Options[0] }
    }

    Write-DFInstallPlan -Plan $plan
    $gapRows = @(Get-DFInstallGapResult -Plan $plan)
    # -WhatIf: the plan only. Interactive: confirm once. -UseDefaults, or no one
    # to ask: no prompt (without -UseDefaults, only decision-free tools are planned).
    if (-not $plan.Items -or $WhatIfPreference) { return $gapRows }
    $skipConfirm = $PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm']
    if ($interactive -and -not $skipConfirm -and (Read-DFInstallChoice -Prompt "Install $(@($plan.Items).Count) tool(s) as planned above?" -Options 'y', 'n' -Default 'y') -ne 'y') { return $gapRows }

    # Installing changes what's available: the runner gets uncached checks.
    $fresh = { param($r) $r -and (Test-DFToolAvailable -Executable $r.executable -Type $r.type -Force) }
    $results = @(Invoke-DFInstallPlan -Plan $plan -ToolDb $db -IsAvailable $fresh @pathArgs)
    $done = @($results | Where-Object Result -eq 'Installed' | ForEach-Object { $_.Tool })
    if ($done) {
        Register-DFTool -Name $done @pathArgs 3>$null
        $requested = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) 3>$null | ForEach-Object { $_.Name })
        foreach ($t in $done | Where-Object { $_ -notin $requested -and $_ -in $targets }) {
            Write-Warning "DotForge: $t is installed and active now; add it to Tools to load it in future sessions."
        }
    }
    $all = @($results) + $gapRows
    Write-DFInstallSummary -Result $all
    $all
}
