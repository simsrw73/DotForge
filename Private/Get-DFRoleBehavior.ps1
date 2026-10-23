#Requires -Version 7.2

function Resolve-DFRoleWords {
    <#
    .SYNOPSIS
        A won role's words as the winner's arguments; missing words are returned, not thrown.
    .PARAMETER Words
        The words, in the order their flags go.
    .PARAMETER Flags
        The winner's role block flags (word -> arguments, each a string or a
        { ifFile, unlessFile, args } group).
    .PARAMETER Tool
        The winner's tool record, for a group's {settings.<name>} and {theme}.
    .OUTPUTS
        pscustomobject { Args = [string[]]; Missing = [string[]] }.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Words, [AllowNull()][object]$Flags, [PSCustomObject]$Tool)
    $argList = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $Words) {
        $mapped = if ($Flags) { $Flags.PSObject.Properties[$word] }
        if (-not $mapped) { $missing.Add($word); continue }
        foreach ($item in @($mapped.Value)) {
            # A string first: -is [pscustomobject] is also true of a PSObject-wrapped string.
            if ($item -is [string]) { if ($item) { $argList.Add($item) } }
            elseif ($item -is [pscustomobject]) { foreach ($a in Resolve-DFRoleFlagGroup -Group $item -Tool $Tool) { $argList.Add($a) } }
        }
    }
    [pscustomobject]@{ Args = [string[]]$argList.ToArray(); Missing = [string[]]$missing.ToArray() }
}

function Select-DFRoleWord {
    <#
    .SYNOPSIS
        A role's words, without the ones that draw Nerd Font icons while icons are off.
    .DESCRIPTION
        The one place icon words are dropped (behaviors.nerdFontWords, Test-DFIconsOn).
        A dropped word is not a missing flag; the winner's status says icons are off.
    .PARAMETER Words
        The words of one alias, picker list or variable.
    .PARAMETER RoleDefinition
        The role record, with behaviors.
    .PARAMETER Tool
        The winner's tool record, for its status note.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()][string[]]$Words,
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $iconWords = @($RoleDefinition.behaviors.nerdFontWords)
    if (-not $iconWords.Count -or -not @($Words | Where-Object { $_ -in $iconWords }).Count -or (Test-DFIconsOn)) { return [string[]]@($Words) }
    Add-DFToolNote -Tool $Tool.name -Note 'icons off: no Nerd Font (see NerdFont)'
    [string[]]@($Words | Where-Object { $_ -notin $iconWords })
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
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words $RoleDefinition.behaviors.aliases[$name] -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
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
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words @($picker.list) -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $picker.alias | Where-Object { $_ }) }
        $copy = [ordered]@{}
        foreach ($p in $picker.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        # The list becomes PowerShell code (Set-DFPickerFunction), so each argument is a literal.
        $copy['list'] = (@($command) + @($resolved.Args | ForEach-Object { ConvertTo-DFPowerShellLiteral $_ })) -join ' '
        [pscustomobject]$copy
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    @($pickers)
}

function Resolve-DFRoleFlagGroup {
    <#
    .SYNOPSIS
        A conditional flag group's arguments: passed only while ifFile exists and unlessFile doesn't.
    .DESCRIPTION
        Paths expand {theme} (the tool's resolved theme value; none means the file is
        missing), then {settings.<name>} and ${XDG_*} (Expand-DFToolToken), and are
        canonical. {file} in args is the ifFile path.
    .PARAMETER Group
        { ifFile?, unlessFile?, args }.
    .PARAMETER Tool
        The tool record.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][PSCustomObject]$Group, [PSCustomObject]$Tool)
    $expand = {
        param([string]$Template)
        if (-not $Template) { return }
        if ($Template.Contains('{theme}')) {
            $theme = if ($Tool -and $Tool.theme) { (Get-DFToolTheme -Tool $Tool).Value }
            if (-not $theme) { return }
            $Template = $Template.Replace('{theme}', [string]$theme)
        }
        Expand-DFToolToken -Tool $Tool -Text $Template
    }
    $ifFile = $Group.PSObject.Properties['ifFile']?.Value
    $unlessFile = $Group.PSObject.Properties['unlessFile']?.Value
    $file = if ($ifFile) { & $expand $ifFile }
    if ($ifFile -and -not ($file -and (Test-Path -LiteralPath $file -PathType Leaf))) { return }
    if ($unlessFile) {
        # Fail closed: a guard path that can't be named can't be shown absent.
        $other = & $expand $unlessFile
        if (-not $other -or (Test-Path -LiteralPath $other -PathType Leaf)) { return }
    }
    # A path ends up inside a command line (PAGER, a picker's list): never let it carry shell syntax.
    if ($file -and $file -match '[`"$%\r\n]') {
        if ($Tool) { Add-DFToolNote -Tool $Tool.name -Note "skipped a flag group: unsafe characters in path '$file'" }
        return
    }
    [string[]]@(foreach ($arg in @($Group.args)) { if ($file) { ([string]$arg).Replace('{file}', $file) } else { [string]$arg } })
}

function Get-DFRoleBehaviorEnv {
    <#
    .SYNOPSIS
        Builds a won role's behavior variables: the winner's executable and each word's flags.
    .DESCRIPTION
        The executable is the ${DF_TOOL_EXE} token (ConvertTo-DFToolExePathToken: the
        winner's own build, quoted when it has a space). An argument holding a space is
        quoted, so a program that splits the variable keeps it whole. A missing word is
        noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.env.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary: variable -> command line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = ConvertTo-DFToolExePathToken -Tool $Tool
    $values = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.env.Keys) {
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words $RoleDefinition.behaviors.env[$name] -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
        # git runs PAGER through sh, and bat/delta split it shell-style: a backslash is an escape
        # there, so paths use forward slashes (as ${DF_TOOL_EXE} does), and an argument with a
        # space or shell punctuation is double-quoted.
        $quoted = foreach ($a in $resolved.Args) {
            $a = $a.Replace('\', '/')
            if ($a -match '[\s;&|<>()''^*?\[#~]') { "`"$a`"" } else { $a }
        }
        $values[$name] = (@($command) + @($quoted)) -join ' '
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    $values
}
function ConvertTo-DFPowerShellLiteral {
    <#
    .SYNOPSIS
        An argument as PowerShell source: bare when plainly safe, else a single-quoted literal.
    .PARAMETER Value
        The argument.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '^[A-Za-z0-9_./:=+,@-]+$') { return $Value }
    "'" + $Value.Replace("'", "''") + "'"
}