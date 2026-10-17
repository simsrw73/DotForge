#Requires -Version 7.2

# Setup notes: steps only the user can take. They are collected while a tool's
# one-time setup runs, recorded with its setup record by Complete-DFToolSetup,
# printed once at the end of the load and kept in Get-DFToolStatus.
# Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.
$script:DFPendingSetupNotes = @{}
$script:DFNewSetupNotes = [System.Collections.Generic.List[object]]::new()

function Add-DFToolSetupNote {
    <#
    .SYNOPSIS
        Adds a note for the user to a tool's running one-time setup.
    .DESCRIPTION
        A Tools/<name>.setup.ps1 calls it before Complete-DFToolSetup, which
        records the notes with the setup; they are printed once at the end of
        the load and stay in Get-DFToolStatus. A repeated note is kept once.
    .PARAMETER Name
        The tool name.
    .PARAMETER Text
        What the user should do.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
    if (-not $script:DFPendingSetupNotes.ContainsKey($Name)) { $script:DFPendingSetupNotes[$Name] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFPendingSetupNotes[$Name].Contains($Text)) { $script:DFPendingSetupNotes[$Name].Add($Text) }
}

function Add-DFDeclaredSetupNote {
    <#
    .SYNOPSIS
        Adds a tool's declared setup.notes whose file conditions hold now, before its seeds are copied.
    .DESCRIPTION
        A note's ifFile/unlessFile are read like a role flag group's
        (Resolve-DFRoleFlagGroup: {theme}, {settings.<name>}, ${XDG_*}), so
        "ifFile: the config file" means the user already had one.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $setup = $Tool.setup
    if (-not $setup) { return }
    foreach ($note in @($setup.notes)) {
        if (-not $note) { continue }
        $group = [pscustomobject]@{
            ifFile     = $note.PSObject.Properties['ifFile']?.Value
            unlessFile = $note.PSObject.Properties['unlessFile']?.Value
            args       = @([string]$note.text)
        }
        foreach ($text in @(Resolve-DFRoleFlagGroup -Group $group -Tool $Tool)) { Add-DFToolSetupNote -Name $Tool.name -Text $text }
    }
}

function Get-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Returns the notes collected so far by a tool's running setup.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFPendingSetupNotes.ContainsKey($Name)) { [string[]]@($script:DFPendingSetupNotes[$Name]) }
}

function Clear-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Forgets a tool's collected notes (its setup failed, or they were recorded).
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $script:DFPendingSetupNotes.Remove($Name)
}

function Publish-DFSetupNote {
    <#
    .SYNOPSIS
        Moves a tool's recorded notes to this session's list to show at the end of the load.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($text in @(Get-DFPendingSetupNote -Name $Name)) { $script:DFNewSetupNotes.Add([pscustomobject]@{ Tool = $Name; Text = $text }) }
    Clear-DFPendingSetupNote -Name $Name
}

function Write-DFSetupNoteNotice {
    <#
    .SYNOPSIS
        Prints, once, the setup notes recorded since the last notice.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    foreach ($note in $script:DFNewSetupNotes) { Write-Host "DotForge: $($note.Tool): $($note.Text)" -ForegroundColor Cyan }
    $script:DFNewSetupNotes.Clear()
}

function Add-DFSetupNoteDetail {
    <#
    .SYNOPSIS
        Adds each tool's recorded setup notes to its status detail, once, when the status is read.
    .DESCRIPTION
        Reads the setup state only when Get-DFToolStatus runs, never at startup.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:DFSessionStatus) { return }
    $todo = @($script:DFSessionStatus.Values | Where-Object { -not $_.PSObject.Properties['SetupNoted'] })
    if (-not $todo) { return }
    $state = Get-DFToolSetupState
    foreach ($status in $todo) {
        $status | Add-Member -NotePropertyName SetupNoted -NotePropertyValue $true -Force
        $entry = $state.PSObject.Properties[$status.Name]?.Value
        $notes = if ($entry) { $entry.PSObject.Properties['notes']?.Value }
        foreach ($text in @($notes)) { if ($text) { Add-DFToolStatusDetail -Status $status -Text "setup note: $text" } }
    }
}
