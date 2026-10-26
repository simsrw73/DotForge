#Requires -Version 7.2

function Remove-DFDesktopEnv {
    <#
    .SYNOPSIS
        Removes the desktop variables DotForge wrote to the Windows user environment (Set-DFDesktopEnv), for some tools or all.
    .DESCRIPTION
        Only variables DotForge recorded in
        $XDG_STATE_HOME\dotforge\desktop-env.json are touched, and each only
        while its value is still the one DotForge wrote: one you changed since
        is left as it is, and the output says so. DotForge forgets both.
        Remove-DFTool does the same for the tool it removes. New programs see
        the change; running ones keep their environment.
    .PARAMETER Name
        The tools. Leave it out for every variable DotForge wrote.
    .EXAMPLE
        Remove-DFDesktopEnv komorebi

        Removes KOMOREBI_CONFIG_HOME from the Windows user environment, if DotForge set it and it is unchanged.
    .EXAMPLE
        Remove-DFDesktopEnv -WhatIf

        Lists every desktop variable DotForge wrote, without removing anything.
    .OUTPUTS
        DotForge.DesktopEnvResult per recorded variable: Tool, Name, Value
        (what DotForge wrote), Current and Action (Removed or Changed).
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
    $mine = @($state.Keys | Where-Object { -not $Name -or $state[$_].tool -in $Name } | Sort-Object)
    if (-not $mine) { Write-Host 'DotForge set no desktop variables for these tools.'; return }
    if (-not (Test-DFDesktopEnvShouldProcess -Cmdlet $PSCmdlet -Target 'the Windows user environment' -Action "Remove $($mine -join ', ')")) { return }
    Remove-DFDesktopEnvSet -Tool $Name -State $state
}
