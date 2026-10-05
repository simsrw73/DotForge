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
        Chooses one winner per single-kind role for this registration.
    .DESCRIPTION
        Candidates are the tools in -Tools that declare the role and are
        installed. The winner is the $DFConfig.Defaults entry when it names a
        candidate (reason 'Defaults'); otherwise the candidate with the highest
        roles.<role>.priority, ties broken by name (reason 'priority', or 'sole'
        for a single candidate). A Defaults entry naming an unknown role or a
        non-member warns; one naming a member that is not a candidate falls
        back silently, since registering a subset is legitimate. A tool
        declaring a role the definitions don't know warns and is ignored for
        it. Category roles and roles without candidates are left out. Never
        throws.
    .PARAMETER ToolDb
        The tool database (for membership checks of Defaults entries).
    .PARAMETER Tools
        The tools being registered in this call.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        System.Collections.Hashtable. Role name -> @{ Role; Winner; Reason; Candidates }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [AllowEmptyCollection()][object[]]$Tools = @(),
        [hashtable]$RoleDb = (Get-DFRoleDb)
    )
    $winners = @{}
    $defaults = Get-DFConfig Defaults -Default @{}

    foreach ($roleName in @($defaults.Keys)) {
        if (-not $RoleDb.ContainsKey($roleName)) {
            Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names an unknown role — ignoring. See Get-DFRole for the list."
        }
    }

    # One pass over the registration set builds role -> candidates; this runs
    # at every startup, so it avoids a pipeline per role. Topo-sorting an
    # empty set can hand back a lone $null, hence the null check.
    $candidatesByRole = @{}
    foreach ($t in $Tools) {
        if (-not $t) { continue }
        $available = $null
        foreach ($rp in $t.roles.PSObject.Properties) {
            $rn = $rp.Name
            if (-not $RoleDb.ContainsKey($rn)) {
                # Stay quiet when no definitions loaded at all (Get-DFRoleDb already
                # warned), and for a legacy v1 role string, which was free-form.
                if ($RoleDb.Count -and -not $rp.Value.legacy) { Write-Warning "DotForge: $($t.name) declares unknown role '$rn' — ignored." }
                continue
            }
            if ($RoleDb[$rn].kind -ne 'single') { continue }
            if ($null -eq $available) { $available = Test-DFToolAvailable -Executable $t.executable -Type $t.type }
            if (-not $available) { continue }
            if (-not $candidatesByRole.ContainsKey($rn)) { $candidatesByRole[$rn] = [System.Collections.Generic.List[object]]::new() }
            $candidatesByRole[$rn].Add($t)
        }
    }

    foreach ($roleName in @($RoleDb.Keys)) {
        if ($RoleDb[$roleName].kind -ne 'single') { continue }
        $candidates = if ($candidatesByRole.ContainsKey($roleName)) { $candidatesByRole[$roleName] } else { @() }

        $winner = $null
        $reason = $null
        $chosen = $defaults[$roleName]
        if ($chosen) {
            $chosenTool = $ToolDb[$chosen]
            if (-not $chosenTool -or -not $chosenTool.roles.PSObject.Properties[$roleName]) {
                $members = @(foreach ($t in $ToolDb.Values) { if ($t.roles.PSObject.Properties[$roleName]) { $t.name } }) | Sort-Object
                Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names '$chosen', which is not a $roleName tool (choose from: $($members -join ', ')) — using priority."
            } else {
                foreach ($c in $candidates) { if ($c.name -eq $chosen) { $winner = $chosen; $reason = 'Defaults'; break } }
            }
        }
        if ($candidates.Count -eq 0) { continue }
        if (-not $winner) {
            $top = $null
            foreach ($c in $candidates) {
                if ($null -eq $top) { $top = $c; continue }
                $cp = $c.roles.$roleName.priority
                $tp = $top.roles.$roleName.priority
                if ($cp -gt $tp -or ($cp -eq $tp -and [string]::Compare($c.name, $top.name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { $top = $c }
            }
            $winner = $top.name
            $reason = if ($candidates.Count -eq 1) { 'sole' } else { 'priority' }
        }
        $names = [string[]]@(foreach ($c in $candidates) { $c.name })
        [array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        $winners[$roleName] = [pscustomobject]@{
            Role       = $roleName
            Winner     = $winner
            Reason     = $reason
            Candidates = $names
        }
    }
    $winners
}

function Invoke-DFToolRegistration {
    <#
    .SYNOPSIS
        Applies one installed tool's configuration: XDG, environment, aliases, picker, won roles, companion.
    .DESCRIPTION
        The per-tool body of Register-DFTool. For each role the tool won, its role
        block's env (through Set-DFRoleEnv) and aliases are applied before the
        companion runs, and its role hook is called right after it (by
        Invoke-DFToolCompanion). Roles it lost are skipped entirely. Anything a
        companion writes to the output stream passes through to the caller.
    .PARAMETER Tool
        The normalized tool record.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .PARAMETER ToolsPath
        The resolved Tools folder holding companions.
    .PARAMETER SkipSetup
        Tool names whose one-time setup script must not run.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        None of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [Parameter(Mandatory)][string]$ToolsPath,
        [string[]]$SkipSetup = @(),
        [hashtable]$RoleDb = (Get-DFRoleDb)
    )
    Set-DFToolXdgConfig -Tool $Tool

    # Non-XDG settings apply regardless of xdg.method. Expand-DFXdgPath expands
    # ${XDG_*} and passes flag strings through byte-for-byte.
    if ($Tool.env) {
        foreach ($var in $Tool.env.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($var.Name, (Expand-DFXdgPath $var.Value), 'Process')
        }
    }

    # A legacy (v1 "role" string) loser keeps v1 behavior: its top-level aliases
    # that the role reserves are left to the winner.
    $suppressed = @(foreach ($rp in $Tool.roles.PSObject.Properties) {
        $won = $RoleWinners[$rp.Name]
        if ($rp.Value.legacy -and $won -and $won.Winner -ne $Tool.name -and $RoleDb.ContainsKey($rp.Name)) {
            $RoleDb[$rp.Name].reserved.aliases
        }
    })
    $topAliases = $Tool.aliases
    if ($suppressed -and $topAliases) {
        $kept = [ordered]@{}
        foreach ($a in $topAliases.PSObject.Properties) {
            if ($a.Name -in $suppressed) { Write-Verbose "DotForge: $($Tool.name) alias '$($a.Name)' left to the winner of its role"; continue }
            $kept[$a.Name] = $a.Value
        }
        $topAliases = [pscustomobject]$kept
    }
    Register-DFToolAliases -Tool $Tool -Aliases $topAliases
    New-DFToolPickerFunction -Tool $Tool

    # Enumerate properties rather than .Name: on a tool with no roles,
    # member enumeration would yield a single $null.
    $roleNames = @(foreach ($rp in $Tool.roles.PSObject.Properties) { $rp.Name }) | Sort-Object
    $wonRoles = foreach ($roleName in $roleNames) {
        $won = $RoleWinners[$roleName]
        if (-not $won -or $won.Winner -ne $Tool.name) { continue }
        $block = $Tool.roles.$roleName
        if ($block.env) {
            foreach ($var in $block.env.PSObject.Properties) {
                Set-DFRoleEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Role $roleName -Winner $won.Winner -Reason $won.Reason
            }
        }
        if ($block.aliases) { Register-DFToolAliases -Tool $Tool -Aliases $block.aliases }
        [pscustomobject]@{
            Role         = $roleName
            Hook         = $RoleDb[$roleName].hook
            HookRequired = -not ($block.env -or $block.aliases -or $block.legacy -or $RoleDb[$roleName].emptyMembership)
        }
    }

    Invoke-DFToolCompanion -Tool $Tool -ToolsPath $ToolsPath -SkipSetup $SkipSetup -WonRoles @($wonRoles)
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
