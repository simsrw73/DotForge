#Requires -Version 7.2

function Resolve-DFToolConflict {
    <#
    .SYNOPSIS
        Hands a tool's config over to DotForge when its old config location still holds your config.
    .DESCRIPTION
        DotForge leaves a requested tool inactive (Get-DFToolStatus -Conflict)
        while the tool's own default location holds config or data that its
        XDG locations would hide. This command resolves that, one of three ways:

        -Move copies the old config to the XDG location, then renames the old
        copy out of the tool's way. It runs only when every check passes, and
        otherwise changes nothing and lists what to fix: the XDG location
        must be empty, the tool must not be running, no text file or
        environment variable may name the old location, and the tool must
        allow DotForge to move it. Every copied file is checked by size and
        SHA-256. The old copy is renamed to <name>.dotforge-moved next to where
        it was, never deleted: delete it yourself when you're satisfied. A copy
        that can't be renamed yet (a file in use) is retried on later loads.

        -Adopt records that DotForge owns the tool's config and moves
        nothing: use it when you've moved or merged the config yourself, or
        don't need the old copy.

        -Done clears a move's unfinished removals after you've dealt with
        them yourself.

        With no tool name, it goes through every tool waiting on you
        (Get-DFToolStatus -Conflict) and offers each one's advised action:
        -Move when the XDG location is empty, -Adopt when it already has your
        config, and Skip when the tool must be moved by hand first. Enter takes
        the advice; A, M or S picks. Where it can't ask, it only lists them.

        Ownership is recorded in $XDG_STATE_HOME\dotforge\ownership.json. From
        then on DotForge configures the tool in its sessions and ignores
        anything left in the old location. Programs started outside a
        DotForge session keep using the old location.
    .PARAMETER Name
        The tool. Leave it out to go through every tool waiting on you.
    .PARAMETER Move
        Copy the old config to the XDG location, check it, then rename the old copy to <name>.dotforge-moved.
    .PARAMETER Adopt
        Record ownership without moving anything.
    .PARAMETER Done
        Clear a move's unfinished removals, keeping ownership.
    .EXAMPLE
        Resolve-DFToolConflict

        Goes through every tool waiting on your existing config, one at a time, offering the advised action for each.
    .EXAMPLE
        Resolve-DFToolConflict bat -Move -WhatIf

        Shows what would be moved, without changing anything.
    .EXAMPLE
        Resolve-DFToolConflict bat -Move

        Moves bat's config from its old location to $XDG_CONFIG_HOME\bat, then loads it with Register-DFTool -Name bat.
    .EXAMPLE
        Resolve-DFToolConflict starship -Adopt

        You've already moved starship.toml yourself: DotForge takes over starship's config.
    .OUTPUTS
        DotForge.ConflictResult: Tool, Action (Move, Adopt, Done or
        AlreadyOwned), Moved (the new locations), Aside (where the old copies
        went), Pending (old copies still to rename) and Problems (why a move
        didn't run).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Guided')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Move')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Adopt')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Done')]
        [string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Move')][switch]$Move,
        [Parameter(Mandatory, ParameterSetName = 'Adopt')][switch]$Adopt,
        [Parameter(Mandatory, ParameterSetName = 'Done')][switch]$Done
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

    if ($Done) { return Complete-DFConflictPending -Name $Name -Ownership $ownership -Result $result -Cmdlet $PSCmdlet }
    if ($ownership.ContainsKey($Name)) {
        Write-Host "DotForge already owns $Name's config; nothing to do."
        $result.Action = 'AlreadyOwned'
        return $result
    }
    if ($Adopt) {
        if ($PSCmdlet.ShouldProcess($Name, 'Record that DotForge owns its config (nothing is moved)')) {
            $ownership[$Name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'adopt' }
            Save-DFToolOwnership -Ownership $ownership -Name $Name
            Write-Host "DotForge now owns $Name's config. Load it with: Register-DFTool -Name $Name"
        }
        return $result
    }
    Invoke-DFConflictMove -Tool $tool -Ownership $ownership -Result $result -Cmdlet $PSCmdlet
}
