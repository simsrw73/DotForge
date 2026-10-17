#Requires -Version 7.2

# Chords DotForge bound this session, so registering a tool again doesn't mistake
# DotForge's own earlier binding for one the user made.
$script:DFBoundKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Set-DFRoleKeyHandler {
    <#
    .SYNOPSIS
        Binds a key-binding role's PSReadLine chord for its winner, keeping a binding the user made.
    .DESCRIPTION
        The history-search and path-insert roles bind only through this (it is
        their reserved code). When the chord already runs a custom handler that
        DotForge didn't bind this session, it is kept and the tool's status says
        so, unless Defaults names this tool for the role: then it is replaced
        with a warning. When PSReadLine isn't loaded (a redirected host, a
        VS Code task) nothing is bound, and PSReadLine isn't loaded for it.
    .PARAMETER Role
        The role name.
    .PARAMETER Chord
        The PSReadLine chord, e.g. 'Ctrl+r'.
    .PARAMETER Tool
        The winning tool's name.
    .PARAMETER Bind
        Binds the chord: Set-PSReadLineKeyHandler, or the tool's own option.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Chord,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][scriptblock]$Bind
    )
    # pwsh 7 always ships PSReadLine; an interactive console has already loaded it, a redirected host hasn't.
    if (-not (Get-Module -Name PSReadLine)) { return }
    $existing = Get-PSReadLineKeyHandler -Chord $Chord -ErrorAction Ignore | Select-Object -First 1
    if ($existing -and -not $script:DFBoundKeys.Contains($Chord) -and (Test-DFCustomKeyHandler -Handler $existing)) {
        $winner = if ($script:DFSessionRoleWinners) { $script:DFSessionRoleWinners[$Role] }
        if (-not ($winner -and $winner.Reason -eq 'Defaults')) {
            Add-DFToolNote -Tool $Tool -Note "kept your own $Chord binding, so $Tool doesn't bind it ($Role)"
            return
        }
        Write-Warning "DotForge: Defaults names $Tool for $Role; replacing your $Chord binding."
    }
    & $Bind
    [void]$script:DFBoundKeys.Add($Chord)
}

function Test-DFCustomKeyHandler {
    <#
    .SYNOPSIS
        True when a PSReadLine key handler is a custom one rather than a PSReadLine function.
    .PARAMETER Handler
        A Get-PSReadLineKeyHandler result.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Handler)
    $readLine = 'Microsoft.PowerShell.PSConsoleReadLine' -as [type]
    if (-not $readLine) { return $false }
    $name = [string]$Handler.Function
    -not ($name -and $readLine.GetMethod($name))
}
