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
        value is left as it is. One set to something else (by you, or by a
        package manager) is yours: in an interactive console you're asked
        whether to keep it or replace it; otherwise, or with -Confirm:$false,
        it is kept, and the output says so.

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
    .OUTPUTS
        DotForge.DesktopEnvResult per variable: Tool, Name, Value (DotForge's),
        Current (the value before) and Action (Set, AlreadySet, Kept or Replaced).
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
    $plan = @(Get-DFDesktopEnvPlan -Tools $tools -Ask $ask)
    if (-not $plan) { Write-Host 'None of these tools suggests desktop variables.'; return }
    foreach ($kept in @($plan | Where-Object Action -eq 'Kept')) {
        Write-Host "Kept your $($kept.Name) = $($kept.Current) (DotForge's would be $($kept.Value))."
    }
    $writes = @($plan | Where-Object Action -in 'Set', 'Replaced')
    $what = if ($writes) { @($writes | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { 'nothing to write; record what is already set' }
    if (-not (Test-DFDesktopEnvShouldProcess -Cmdlet $PSCmdlet -Target 'the Windows user environment' -Action "Set $what")) { return }
    Write-DFDesktopEnvPlan -Plan $plan -State $state
    if ($writes) { Write-Host 'New programs see the change; programs already running keep their environment.' }
    $plan
}
