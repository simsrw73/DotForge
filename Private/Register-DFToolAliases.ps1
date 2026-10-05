#Requires -Version 7.0

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
        so a built-in like `cd` would otherwise shadow the wrapper).
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
