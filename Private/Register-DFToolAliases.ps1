#Requires -Version 7.2

function Test-DFCommandExists {
    <#
    .SYNOPSIS
        Whether a program or script of that name is on PATH (a seam tests mock).
    .PARAMETER Name
        The command name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction Ignore)
}

function Register-DFToolAliases {
    <#
    .SYNOPSIS
        Creates one tool's declared aliases (or wrapper functions, for
        aliases that carry arguments).
    .DESCRIPTION
        For each alias in -Aliases (by default the tool's own top-level
        aliases): a zero-argument alias becomes a plain Set-Alias; an alias
        with args becomes a global wrapper function, removing any colliding
        built-in alias first (Alias outranks Function in command resolution,
        so a built-in like `cd` would otherwise shadow the wrapper). An alias
        declared ifFree is skipped, with a status note, when a program of that
        name is on PATH (a cc alias must not hide a C compiler).
    .PARAMETER Tool
        The tool record declaring the aliases.
    .PARAMETER Aliases
        The aliases to create. Defaults to the tool's own top-level aliases;
        Invoke-DFToolRegistration passes a won role's aliases here.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [AllowNull()]
        [object]$Aliases = $Tool.aliases
    )

    if (-not $Aliases) { return }

    $Aliases.PSObject.Properties | ForEach-Object {
        $aliasName = $_.Name

        # ConvertTo-DFToolRecord guarantees { command; args[] } per alias.
        $aliasCmd  = $_.Value.command
        $aliasArgs = $_.Value.args

        if (-not $aliasCmd) { return }
        if ($_.Value.PSObject.Properties['ifFree']?.Value -and (Test-DFCommandExists -Name $aliasName)) {
            Add-DFToolNote -Tool $Tool.name -Note "$aliasName isn't defined: a $aliasName program already exists"
            return
        }

        if ($aliasArgs.Count -eq 0) {
            Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
        } else {
            # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
            # function of the same name in command resolution
            # (Alias > Function), so it would shadow the wrapper
            # function below. Remove the colliding global alias first.
            # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
            if (Test-Path "Alias:\$aliasName") {
                Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
            }
            $capturedCmd  = $aliasCmd
            $capturedArgs = $aliasArgs
            Set-Item -Path "function:global:$aliasName" -Value {
                & $capturedCmd @capturedArgs @args
            }.GetNewClosure()
        }
    }
}
