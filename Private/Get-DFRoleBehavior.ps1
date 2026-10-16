#Requires -Version 7.2

function Resolve-DFRoleWords {
    <#
    .SYNOPSIS
        A won role's words as the winner's arguments; missing words are returned, not thrown.
    .PARAMETER Words
        The words, in the order their flags go.
    .PARAMETER Flags
        The winner's role block flags (word -> string array).
    .OUTPUTS
        pscustomobject { Args = [string[]]; Missing = [string[]] }.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Words, [AllowNull()][object]$Flags)
    $argList = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $Words) {
        $mapped = if ($Flags) { $Flags.PSObject.Properties[$word] }
        if ($mapped) { foreach ($a in @($mapped.Value)) { if ($a) { $argList.Add($a) } } } else { $missing.Add($word) }
    }
    [pscustomobject]@{ Args = [string[]]$argList.ToArray(); Missing = [string[]]$missing.ToArray() }
}

function Add-DFRoleMissingWordNote {
    <#
    .SYNOPSIS
        Notes, once per word, the role words a tool has no flag for, naming the aliases and pickers that use them.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Role
        The role name.
    .PARAMETER Missing
        Word -> names of the aliases or pickers that use it.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Missing
    )
    foreach ($word in $Missing.Keys) {
        Add-DFToolNote -Tool $Tool.name -Note "$Role`: no flag for '$word' ($(@($Missing[$word]) -join ', '))"
    }
}

function Get-DFRoleBehaviorAlias {
    <#
    .SYNOPSIS
        Builds a won role's aliases from the winner's flags.
    .DESCRIPTION
        Each alias the role's behaviors define runs the winner's executable (its file
        name without extension) with each word's flags, in the role's order. A word the
        winner doesn't map is left out and noted in the tool's status.
    .PARAMETER RoleDefinition
        The role record (Get-DFRoleDb), with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role (flags).
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject: alias name -> { command; args }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $aliases = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.aliases.Keys) {
        $resolved = Resolve-DFRoleWords -Words $RoleDefinition.behaviors.aliases[$name] -Flags $Block.flags
        $aliases[$name] = [pscustomobject]@{ command = $command; args = $resolved.Args }
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    [pscustomobject]$aliases
}

function Get-DFRolePicker {
    <#
    .SYNOPSIS
        Builds a won role's pickers, with each list command made from the winner's flags.
    .DESCRIPTION
        Returns copies of the role's pickers whose list is "<executable> <flags>"; every
        other field (alias, function, preview, ...) is kept. A missing word is noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject[]: declarative pickers for Set-DFPickerFunction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $missing = [ordered]@{}
    $pickers = foreach ($picker in @($RoleDefinition.behaviors.pickers)) {
        $resolved = Resolve-DFRoleWords -Words @($picker.list) -Flags $Block.flags
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $picker.alias | Where-Object { $_ }) }
        $copy = [ordered]@{}
        foreach ($p in $picker.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        $copy['list'] = (@($command) + $resolved.Args) -join ' '
        [pscustomobject]$copy
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    @($pickers)
}
