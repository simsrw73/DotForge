#Requires -Version 7.2

function Resolve-DFToolConflict {
    <#
    .SYNOPSIS
        Settles a tool whose existing data and XDG location both hold content: keep the existing copy (-Adopt) or the XDG copy (-KeepXdg).
    .DESCRIPTION
        DotForge links a requested tool's empty XDG locations to the data it
        already has (its own default folders, or where a variable set outside
        DotForge points), and leaves the variables that would hide that data
        unset. When an XDG location holds content too, DotForge can't choose,
        so the tool waits, inactive (Get-DFToolStatus -Conflict).

        -Adopt keeps the existing data: each XDG copy in the way is renamed to
        <name>.dotforge-moved next to where it was, never deleted, and the XDG
        location is linked to the existing data. If a copy can't be renamed (a
        file in use), nothing is changed and Problems says why.

        -KeepXdg keeps the XDG copy, such as config restored from your
        dotfiles: each existing copy in the way is renamed to
        <name>.dotforge-moved next to where it was, never deleted, and the tool
        uses the XDG folders from its next load. Read the tool's guide in its
        status first: some old folders hold installed packages to reinstall.
        When a variable you set points at the existing copy, nothing is
        changed: remove that variable first. Or remove the tool from Tools.

        With no tool name, it goes through every tool waiting on you and
        offers Adopt (Enter), Keep XDG or Skip. Where it can't ask, it only
        lists them.

        Links are recorded in $XDG_STATE_HOME\dotforge\ownership.json; DotForge
        removes them with the tool (Remove-DFTool), never what they point to.
    .PARAMETER Name
        The tool. Leave it out to go through every tool waiting on you.
    .PARAMETER Adopt
        Keep the existing data: set the XDG copies aside and link to it.
    .PARAMETER KeepXdg
        Keep the XDG copies: set the existing copies aside.
    .EXAMPLE
        Resolve-DFToolConflict

        Goes through every tool waiting on you, one at a time, offering Adopt, Keep XDG or Skip.
    .EXAMPLE
        Resolve-DFToolConflict bat -Adopt -WhatIf

        Shows what would be set aside and linked, without changing anything.
    .EXAMPLE
        Resolve-DFToolConflict bat -Adopt

        Renames $XDG_CONFIG_HOME\bat to bat.dotforge-moved and links $XDG_CONFIG_HOME\bat to your existing bat config.
    .EXAMPLE
        Resolve-DFToolConflict bat -KeepXdg

        Renames your existing bat config folder to bat.dotforge-moved, so bat uses $XDG_CONFIG_HOME\bat from its next load.
    .OUTPUTS
        DotForge.ConflictResult: Tool, Action (Adopt, KeepXdg, AlreadyOwned or
        Nothing), Linked (the XDG locations now linked), Aside (where the
        copies set aside went) and Problems (why nothing was changed).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Guided')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Adopt')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'KeepXdg')]
        [string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Adopt')][switch]$Adopt,
        [Parameter(Mandatory, ParameterSetName = 'KeepXdg')][switch]$KeepXdg
    )

    if ($PSCmdlet.ParameterSetName -eq 'Guided') { return Invoke-DFConflictGuide }
    $tool = (Import-DFToolDb -Name $Name)[$Name]
    if (-not $tool) { Write-Error "DotForge: no tool record named '$Name'."; return }
    $ownership = Read-DFToolOwnership
    if ($null -eq $ownership) {
        Write-Error "DotForge: $(Get-DFToolOwnershipPath) can't be read, so ownership can't be recorded; fix or delete that file first."
        return
    }
    $result = New-DFConflictResult -Tool $Name -Action $PSCmdlet.ParameterSetName
    if ($ownership.ContainsKey($Name)) {
        Write-Host "DotForge already handles $Name's data; nothing to do."
        $result.Action = 'AlreadyOwned'
        return $result
    }
    $step = if ($KeepXdg) { 'Invoke-DFConflictKeepXdg' } else { 'Invoke-DFConflictAdopt' }
    & $step -Tool $tool -Ownership $ownership -Result $result -Cmdlet $PSCmdlet
}
