#Requires -Version 7.2

function Set-DFDesktopEnv {
    <#
    .SYNOPSIS
        Writes the desktop variables your tools suggest to the Windows user environment, so programs started outside pwsh see them.
    .DESCRIPTION
        DotForge sets a tool's variables in each pwsh session only. A program
        started another way (komorebi at sign-in, a desktop app, an editor)
        sees only the Windows user environment (HKCU\Environment). A tool
        record suggests which of its variables those programs need
        (desktop); Get-DFToolStatus notes the ones they lack. Nothing is
        written until you run this command: running it is the opt-in.

        A variable that is missing is written. One already set to the same
        value is left as it is, and stays yours: DotForge won't remove it
        (it isn't recorded, so removing the tool never removes it). One set to something else (by you, or by a
        package manager) is yours: in an interactive console you're asked
        whether to keep it or replace it; otherwise, or with -Confirm:$false,
        it is kept, and the output says so.

        A record may also name folders desktop apps need on the Windows user
        Path (desktopPath; fnm's default Node). A folder already on it, however
        written, is left as it is and stays yours. A missing one is added at
        the end. When another copy of one of its commands is on the Path, an
        interactive console asks whether to put the folder before that copy,
        after it, or skip it (a copy on the system Path comes first whatever
        the order, so then you're asked only whether to add it); otherwise it
        is added at the end and the output names the copy that comes first.
        A folder under one of the tool's variables is skipped while that
        variable has another value, in this shell or for desktop apps: the
        folder would be one the tool never uses, and the output says what to
        add instead.

        What DotForge writes is recorded in
        $XDG_STATE_HOME\dotforge\desktop-env.json, so Remove-DFDesktopEnv and
        Remove-DFTool remove only that, and only while it is unchanged. New
        programs see the change; running ones keep their environment.
    .PARAMETER Name
        The tools. Leave it out for every tool your session requests.
    .EXAMPLE
        Set-DFDesktopEnv -WhatIf

        Shows which desktop variables your requested tools would set, without writing anything.
    .EXAMPLE
        Set-DFDesktopEnv komorebi

        Sets KOMOREBI_CONFIG_HOME in the Windows user environment, so komorebi finds its config when it starts at sign-in.
    .EXAMPLE
        Set-DFDesktopEnv fnm

        Sets FNM_DIR for desktop apps and adds fnm's default Node folder to the user Path, so an editor started from the Start menu finds node.
    .OUTPUTS
        DotForge.DesktopEnvResult per variable and per Path entry: Kind
        (Variable or Path), Tool, Name (the variable, or Path), Value
        (DotForge's value, or the folder), Current (the value before; for a
        Path entry the matching segment as written, or $null), Action (Set,
        AlreadySet, Kept or Replaced; for a Path entry Set, AlreadySet or
        Skipped) and Shadowed (a Path entry's other copies of its commands:
        Command, Path, Scope).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string[]]$Name)

    if (-not (Test-DFIsWindows)) { Write-Host 'Desktop variables are a Windows feature; nothing to do here.'; return }
    $tools = @(Get-DFDesktopEnvTool -Name $Name)
    $state = Read-DFDesktopEnvState
    if ($null -eq $state) {
        Write-Error "DotForge: $(Get-DFDesktopEnvStatePath) can't be read, so nothing is written (it couldn't be recorded). Fix or delete that file first."
        return
    }
    $ask = (Test-DFConflictPrompt) -and $ConfirmPreference -ne 'None' -and -not $WhatIfPreference
    # Variables first: a value kept here is what the Path entries' guard sees.
    $varPlan = @(Get-DFDesktopEnvPlan -Tools $tools -Ask $ask)
    $plan = @($varPlan) + @(Get-DFDesktopPathPlan -Tools $tools -Ask $ask -VarPlan $varPlan)
    if (-not $plan) { Write-Host 'None of these tools suggests desktop variables or Path entries.'; return }
    foreach ($kept in @($plan | Where-Object Action -eq 'Kept')) {
        Write-Host "Kept your $($kept.Name) = $($kept.Current) (DotForge's would be $($kept.Value))."
    }
    $writes = @($plan | Where-Object { $_.Action -in 'Set', 'Replaced' })
    if (-not $writes) { return $plan }
    $what = @($writes | ForEach-Object { if ($_.Kind -eq 'Path') { "Path += $($_.Value)" } else { "$($_.Name)=$($_.Value)" } }) -join ', '
    if (-not (Test-DFDesktopEnvShouldProcess -Cmdlet $PSCmdlet -Target 'the Windows user environment' -Action "Set $what")) { return }
    Write-DFDesktopEnvPlan -Plan $plan -State $state
    if (-not $ask) { Write-DFDesktopPathShadowNote -Plan $plan }
    Write-Host 'New programs see the change; programs already running keep their environment.'
    $plan
}
