#Requires -Version 7.2

function Remove-DFDesktopEnv {
    <#
    .SYNOPSIS
        Removes the desktop variables and Path entries DotForge wrote to the Windows user environment (Set-DFDesktopEnv), for some tools or all.
    .DESCRIPTION
        Only variables and Path entries DotForge recorded in
        $XDG_STATE_HOME\dotforge\desktop-env.json are touched. A variable goes
        only while its value is still the one DotForge wrote: one you changed
        since is left as it is, and the output says so. A Path entry goes from
        the user Path wherever it now is (once; an entry already gone counts as
        removed), and nothing else on the Path changes. DotForge forgets all of
        them. Remove-DFTool does the same for the tool it removes. New programs
        see the change; running ones keep their environment.
    .PARAMETER Name
        The tools. Leave it out for every variable and Path entry DotForge wrote.
    .EXAMPLE
        Remove-DFDesktopEnv komorebi

        Removes KOMOREBI_CONFIG_HOME from the Windows user environment, if DotForge set it and it is unchanged.
    .EXAMPLE
        Remove-DFDesktopEnv -WhatIf

        Lists every desktop variable DotForge wrote, without removing anything.
    .OUTPUTS
        DotForge.DesktopEnvResult per recorded variable or Path entry: Kind
        (Variable or Path), Tool, Name (Path for an entry), Value (what DotForge
        wrote; the folder for an entry), Current and Action (Removed, Changed,
        or Failed when the registry refused the removal: it stays recorded,
        and an error says why).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string[]]$Name)

    if (-not (Test-DFIsWindows)) { Write-Host 'Desktop variables are a Windows feature; nothing to do here.'; return }
    $state = Read-DFDesktopEnvState
    if ($null -eq $state) {
        Write-Error "DotForge: $(Get-DFDesktopEnvStatePath) can't be read, so nothing is removed. Fix or delete that file first."
        return
    }
    $mine = @($state.Vars.Keys | Where-Object { -not $Name -or $state.Vars[$_].tool -in $Name } | Sort-Object) +
        @($state.Path.Keys | Where-Object { -not $Name -or $state.Path[$_].tool -in $Name } | Sort-Object | ForEach-Object { "Path -= $_" })
    if (-not $mine) { Write-Host 'DotForge set no desktop variables or Path entries for these tools.'; return }
    if (-not (Test-DFDesktopEnvShouldProcess -Cmdlet $PSCmdlet -Target 'the Windows user environment' -Action "Remove $($mine -join ', ')")) { return }
    Remove-DFDesktopEnvSet -Tool $Name -State $state
}
