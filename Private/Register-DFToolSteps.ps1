#Requires -Version 7.0

# The steps Register-DFTool runs, one function each, so its body reads as the
# algorithm: choose the tools, resolve role winners, register each tool, then
# finish completion and report coreutils conflicts.

function Get-DFRegistrationSet {
    <#
    .SYNOPSIS
        Returns the tool records a Register-DFTool call should consider, before ordering.
    .DESCRIPTION
        With -All: every record except those in $DFConfig.SkipTools. With
        -Name: the named records (SkipTools is not applied to names given
        explicitly); an unknown name warns and is skipped.
    .PARAMETER ToolDb
        The tool database (Import-DFToolDb).
    .PARAMETER Name
        Tool names asked for.
    .PARAMETER All
        Every known tool.
    .OUTPUTS
        PSCustomObject[]. Tool records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [string[]]$Name,
        [switch]$All
    )
    if ($All) {
        $skipTools = @(Get-DFConfig SkipTools)
        return @($ToolDb.Values | Where-Object { $_.name -notin $skipTools })
    }
    foreach ($n in $Name) {
        if ($ToolDb.ContainsKey($n)) { $ToolDb[$n] }
        else { Write-Warning "DotForge: Unknown tool '$n'" }
    }
}

function Get-DFRoleWinners {
    <#
    .SYNOPSIS
        Resolves $DFConfig.Defaults (role -> tool) into the winners that apply to this registration.
    .DESCRIPTION
        A winner applies when it exists, declares that role, is being
        registered in this call and is installed. The result maps role ->
        @{ WinnerName; AliasKeys }: every other tool with that role then skips
        exactly those alias names and keeps everything else (XDG, picker,
        companion, other aliases). Invalid entries warn and are ignored;
        nothing throws.
    .PARAMETER ToolDb
        The tool database.
    .PARAMETER Tools
        The tools being registered.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [AllowEmptyCollection()][object[]]$Tools = @()
    )
    $winners = @{}
    $defaults = Get-DFConfig Defaults
    if (-not $defaults) { return $winners }
    foreach ($roleName in $defaults.Keys) {
        $winnerName = $defaults[$roleName]
        if (-not $ToolDb.ContainsKey($winnerName)) {
            Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names unknown tool '$winnerName' — ignoring."
            continue
        }
        $winner = $ToolDb[$winnerName]
        if ($winner.role -ne $roleName) {
            Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names '$winnerName', which declares role '$($winner.role)' (expected '$roleName') — ignoring."
            continue
        }
        if (-not ($Tools | Where-Object { $_.name -eq $winnerName })) { continue }
        if (-not (Test-DFToolAvailable -Executable $winner.executable -Type $winner.type)) { continue }
        $aliasKeys = if ($winner.aliases) { @($winner.aliases.PSObject.Properties.Name) } else { @() }
        $winners[$roleName] = @{ WinnerName = $winnerName; AliasKeys = $aliasKeys }
    }
    $winners
}

function Invoke-DFToolRegistration {
    <#
    .SYNOPSIS
        Applies one installed tool's configuration: XDG, environment, aliases, picker, companion.
    .DESCRIPTION
        The per-tool body of Register-DFTool. Anything a companion writes to the
        output stream passes through to the caller, as it always has.
    .PARAMETER Tool
        The normalized tool record.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .PARAMETER ToolsPath
        The resolved Tools folder holding companions.
    .PARAMETER SkipSetup
        Tool names whose one-time setup script must not run.
    .OUTPUTS
        None of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [Parameter(Mandatory)][string]$ToolsPath,
        [string[]]$SkipSetup = @()
    )
    Set-DFToolXdgConfig -Tool $Tool

    # Non-XDG settings apply regardless of xdg.method. Expand-DFXdgPath expands
    # ${XDG_*} and passes flag strings through byte-for-byte.
    if ($Tool.env) {
        foreach ($var in $Tool.env.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($var.Name, (Expand-DFXdgPath $var.Value), 'Process')
        }
    }

    $roleWinner = if ($Tool.role) { $RoleWinners[$Tool.role] }
    Register-DFToolAliases -Tool $Tool -RoleWinner $roleWinner
    New-DFToolPickerFunction -Tool $Tool
    Invoke-DFToolCompanion -Tool $Tool -ToolsPath $ToolsPath -SkipSetup $SkipSetup
}

function Write-DFConflictNotice {
    <#
    .SYNOPSIS
        Warns once, with the fix, when Coreutils for Windows shadows DotForge commands.
    .DESCRIPTION
        One consolidated warning rather than one per tool. Costs nothing when
        coreutils is absent, and stops once the conflict is resolved. Resolving
        it needs elevation and is the user's choice, so this only prints the
        commands.
    .PARAMETER ToolsPath
        The resolved Tools folder (for the alias names to check).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolsPath)
    $conflicts = @(Get-DFCommandConflict -ToolsPath $ToolsPath -ErrorAction Ignore)
    if (-not $conflicts) { return }
    $names = ($conflicts.Command | Sort-Object) -join ' '
    # DisableWith, not Command: 'la' is not a coreutils utility and the manager
    # rejects it; disabling 'ls' is what removes it.
    $disable = ($conflicts.DisableWith | Sort-Object -Unique) -join ' '
    Write-Warning @"
DotForge: coreutils shadows $($conflicts.Count) DotForge command(s) before PowerShell resolves them: $names
  These will not reach DotForge's version at the prompt, even though Get-Command reports otherwise.
  Keep DotForge's:  coreutils-manager disable $disable   (run elevated, once)
  Keep coreutils':  `$DFConfig.IgnoreConflicts = @($(($conflicts.Command | Sort-Object | ForEach-Object { "'$_'" }) -join ', '))
  Silence entirely: `$DFConfig.SkipConflictCheck = `$true
"@
}
