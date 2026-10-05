#Requires -Version 7.0

function Register-DFToolAliases {
    <#
    .SYNOPSIS
        Creates one tool's declared aliases (or wrapper functions, for
        aliases that carry arguments), honoring role-loser alias suppression.
    .DESCRIPTION
        For each alias in $Tool.aliases: if $RoleWinner names a different
        tool that won this alias's role, the alias is skipped (Write-Verbose
        only -- every other alias, XDG config, and picker $Tool declares
        still applies elsewhere in Register-DFTool). Otherwise, a zero-
        argument alias becomes a plain Set-Alias; an alias with args becomes
        a global wrapper function, removing any colliding built-in alias
        first (Alias outranks Function in command resolution, so a built-in
        like `cd` would otherwise shadow the wrapper).
    .PARAMETER Tool
        The tool record declaring the aliases.
    .PARAMETER RoleWinner
        $null, or a hashtable @{ WinnerName; AliasKeys } naming the tool that
        won $Tool's role and which of its own alias keys are suppressed on
        every other tool sharing that role.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [object]$RoleWinner
    )

    if (-not $Tool.aliases) { return }

    $Tool.aliases.PSObject.Properties | ForEach-Object {
        $aliasName = $_.Name

        if ($RoleWinner -and $RoleWinner.WinnerName -ne $Tool.name -and $aliasName -in $RoleWinner.AliasKeys) {
            Write-Verbose "DotForge: $($Tool.name) alias '$aliasName' suppressed — '$($RoleWinner.WinnerName)' won role '$($Tool.role)'"
            return
        }

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
