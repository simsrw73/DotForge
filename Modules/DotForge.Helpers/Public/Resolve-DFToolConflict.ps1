#Requires -Version 7.2

function Resolve-DFToolConflict {
    <#
    .SYNOPSIS
        Keeps a tool's existing data when its XDG location holds content too: sets the XDG copy aside and links to the existing data.
    .DESCRIPTION
        DotForge links a requested tool's empty XDG locations to the data it
        already has (its own default folders, or where a variable set outside
        DotForge points), and leaves the variables that would hide that data
        unset. When an XDG location holds content too, DotForge can't choose,
        so the tool waits, inactive (Get-DFToolStatus -Conflict).

        -Adopt keeps the existing data: each XDG copy in the way is renamed to
        <name>.dotforge-moved next to where it was, never deleted, and the XDG
        location is linked to the existing data. If a copy can't be renamed (a
        file in use), nothing is changed and Problems says why. To keep the XDG
        copy instead, follow the tool's guide in its status, or remove the
        tool from Tools.

        With no tool name, it goes through every tool waiting on you and
        offers Adopt (Enter) or Skip. Where it can't ask, it only lists them.

        Links are recorded in $XDG_STATE_HOME\dotforge\ownership.json; DotForge
        removes them with the tool (Remove-DFTool), never what they point to.
    .PARAMETER Name
        The tool. Leave it out to go through every tool waiting on you.
    .PARAMETER Adopt
        Keep the existing data: set the XDG copies aside and link to it.
    .EXAMPLE
        Resolve-DFToolConflict

        Goes through every tool waiting on you, one at a time, offering Adopt or Skip.
    .EXAMPLE
        Resolve-DFToolConflict bat -Adopt -WhatIf

        Shows what would be set aside and linked, without changing anything.
    .EXAMPLE
        Resolve-DFToolConflict bat -Adopt

        Renames $XDG_CONFIG_HOME\bat to bat.dotforge-moved and links $XDG_CONFIG_HOME\bat to your existing bat config.
    .OUTPUTS
        DotForge.ConflictResult: Tool, Action (Adopt, AlreadyOwned or
        Nothing), Linked (the XDG locations now linked), Aside (where the XDG
        copies went) and Problems (why nothing was changed).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Guided')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Adopt')]
        [string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Adopt')][switch]$Adopt
    )

    if ($PSCmdlet.ParameterSetName -eq 'Guided') { return Invoke-DFConflictGuide }
    $tool = (Import-DFToolDb -Name $Name)[$Name]
    if (-not $tool) { Write-Error "DotForge: no tool record named '$Name'."; return }
    $ownership = Read-DFToolOwnership
    if ($null -eq $ownership) {
        Write-Error "DotForge: $(Get-DFToolOwnershipPath) can't be read, so ownership can't be recorded; fix or delete that file first."
        return
    }
    $result = New-DFConflictResult -Tool $Name -Action Adopt
    if ($ownership.ContainsKey($Name)) {
        Write-Host "DotForge already handles $Name's data; nothing to do."
        $result.Action = 'AlreadyOwned'
        return $result
    }
    Invoke-DFConflictAdopt -Tool $tool -Ownership $ownership -Result $result -Cmdlet $PSCmdlet
}
