#Requires -Version 7.2

$script:DFToolNotes = @{}

function Add-DFToolNote {
    <#
    .SYNOPSIS
        Records a note for a tool's status (e.g. a role flag it lacks); a repeated note is kept once.
    .PARAMETER Tool
        The tool name.
    .PARAMETER Note
        The note.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Note)
    if (-not $script:DFToolNotes.ContainsKey($Tool)) { $script:DFToolNotes[$Tool] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFToolNotes[$Tool].Contains($Note)) { $script:DFToolNotes[$Tool].Add($Note) }
}

function Get-DFToolNote {
    <#
    .SYNOPSIS
        Returns a tool's status notes, in the order they were added.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    if ($script:DFToolNotes.ContainsKey($Tool)) { [string[]]@($script:DFToolNotes[$Tool]) }
}

function Clear-DFToolNote {
    <#
    .SYNOPSIS
        Forgets a tool's status notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    $script:DFToolNotes.Remove($Tool)
}
