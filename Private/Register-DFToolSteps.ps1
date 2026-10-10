#Requires -Version 7.2

# The per-session steps Invoke-DFSessionActivation runs: resolve role winners,
# register each tool, and report coreutils conflicts.

function Get-DFRoleWinners {
    <#
    .SYNOPSIS
        Chooses one winner per single-kind role for this registration.
    .DESCRIPTION
        Candidates are the tools in -Tools that declare the role and are
        installed (in a session, -Tools holds only the requested tools). A
        membership with roles.<role>.optIn true is a candidate only when
        Defaults[<role>] names that tool. The winner is the Defaults entry when
        it names a candidate (reason 'Defaults'). When the Defaults tool is
        requested but unavailable, the highest-priority candidate stands in
        (reason 'fallback', Preferred names the tool it stands in for).
        Otherwise the highest roles.<role>.priority wins, ties broken by name
        (reason 'priority', or 'sole' for a single candidate). A Defaults
        entry naming a tool that is not requested warns.
        A Defaults entry naming an unknown role or a non-member also warns. A tool
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
        System.Collections.Hashtable. Role name -> @{ Role; Winner; Reason; Candidates (by name); Ranked (by priority); Preferred }.
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
            Write-Warning "DotForge: Defaults['$roleName'] names an unknown role — ignoring. See Get-DFRole for the list."
        } elseif ($RoleDb[$roleName].kind -eq 'category') {
            Write-Warning "DotForge: Defaults['$roleName']: '$roleName' is a category, which has no winner — every member is configured. Ignoring."
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
            # optIn is generic role metadata: an optional member joins the
            # candidate set only when the user selected it for this role.
            if ($rp.Value.optIn -and $defaults[$rn] -ine $t.name) { continue }
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
        if (-not [string]::IsNullOrWhiteSpace($chosen)) {
            $chosenTool = $ToolDb[$chosen]
            if (-not $chosenTool) {
                # A role is only ever filled by a tool the user asked for.
                Write-Warning "DotForge: Defaults['$roleName'] names '$chosen', which is not requested in Tools — using priority. Add '$chosen' to Tools to use it."
            } elseif (-not $chosenTool.roles.PSObject.Properties[$roleName]) {
                $members = @(foreach ($t in $ToolDb.Values) { if ($t.roles.PSObject.Properties[$roleName]) { $t.name } }) | Sort-Object
                Write-Warning "DotForge: Defaults['$roleName'] names '$chosen', which is not a $roleName tool (requested ones: $($members -join ', ')) — using priority."
            } else {
                # Report the tool's own spelling, not the user's (names compare case-insensitively).
                foreach ($c in $candidates) { if ($c.name -eq $chosen) { $winner = $c.name; $reason = 'Defaults'; break } }
            }
        }
        if ($candidates.Count -eq 0) { continue }
        # Rank by priority (highest first), ties by name. An insertion sort over
        # the usual one to three candidates; no pipeline, since this runs at startup.
        $ranked = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $candidates) {
            $i = 0
            while ($i -lt $ranked.Count) {
                $o = $ranked[$i]
                $cp = $c.roles.$roleName.priority
                $op = $o.roles.$roleName.priority
                if ($cp -gt $op -or ($cp -eq $op -and [string]::Compare($c.name, $o.name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { break }
                $i++
            }
            $ranked.Insert($i, $c)
        }
        # The user's preferred member, when it is requested and really in the role.
        $preferred = if (-not [string]::IsNullOrWhiteSpace($chosen) -and $ToolDb[$chosen] -and
            $ToolDb[$chosen].roles.PSObject.Properties[$roleName]) { $ToolDb[$chosen].name }
        if (-not $winner) {
            $winner = $ranked[0].name
            # The preferred tool is requested but unavailable: another requested
            # tool stands in, and the end-of-load notice says so.
            $reason = if ($preferred) { 'fallback' } elseif ($candidates.Count -eq 1) { 'sole' } else { 'priority' }
        }
        $names = [string[]]@(foreach ($c in $candidates) { $c.name })
        [array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        $winners[$roleName] = [pscustomobject]@{
            Role       = $roleName
            Winner     = $winner
            Reason     = $reason
            Candidates = $names
            Ranked     = [string[]]@(foreach ($c in $ranked) { $c.name })
            Preferred  = $preferred
        }
    }
    $winners
}

function Test-DFHasEntries {
    <#
    .SYNOPSIS
        True when a parsed JSON object (such as a role block's env or aliases) has at least one property.
    .PARAMETER Object
        The object, or $null.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Object)
    $null -ne $Object -and @($Object.PSObject.Properties).Count -gt 0
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
    .PARAMETER Context
        What the whole activation shares (Invoke-DFSessionActivation builds it):
          RoleWinners: Get-DFRoleWinners result.
          RoleDb: role definitions (Get-DFRoleDb).
          ToolsPath: the resolved Tools folder holding companions.
          SkipSetup: tool names whose one-time setup script must not run.
    .OUTPUTS
        None of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$Context
    )
    $RoleWinners = $Context.RoleWinners
    $RoleDb = $Context.RoleDb
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
                # ${DF_TOOL_EXE}: the winner's own executable path (see Resolve-DFToolExecutable).
                $value = [string]$var.Value
                if ($value.Contains('${DF_TOOL_EXE}')) { $value = $value.Replace('${DF_TOOL_EXE}', (ConvertTo-DFToolExePathToken -Tool $Tool)) }
                Set-DFRoleEnv -Name $var.Name -Value (Expand-DFXdgPath $value) -Role $roleName -Winner $won.Winner -Reason $won.Reason
            }
        }
        if ($block.aliases) { Register-DFToolAliases -Tool $Tool -Aliases $block.aliases }
        [pscustomobject]@{
            Role         = $roleName
            Hook         = $RoleDb[$roleName].hook
            # An empty {} block is still an object, so count what it holds.
            HookRequired = -not ((Test-DFHasEntries $block.env) -or (Test-DFHasEntries $block.aliases) -or
                $block.legacy -or $RoleDb[$roleName].emptyMembership)
        }
    }

    Invoke-DFToolCompanion -Tool $Tool -ToolsPath $Context.ToolsPath -SkipSetup @($Context.SkipSetup) -WonRoles @($wonRoles)
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
    .PARAMETER Tools
        The tool records whose command names to check (the session's active tools).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Tools = @())
    $conflicts = @(Get-DFCommandConflict -Tools $Tools -ErrorAction Ignore)
    if (-not $conflicts) { return }
    $names = ($conflicts.Command | Sort-Object) -join ' '
    # DisableWith, not Command: 'la' is not a coreutils utility and the manager
    # rejects it; disabling 'ls' is what removes it.
    $disable = ($conflicts.DisableWith | Sort-Object -Unique) -join ' '
    Write-Warning @"
DotForge: coreutils shadows $($conflicts.Count) DotForge command(s) before PowerShell resolves them: $names
  These will not reach DotForge's version at the prompt, even though Get-Command reports otherwise.
  Keep DotForge's:  coreutils-manager disable $disable   (run elevated, once)
  Keep coreutils':  add IgnoreConflicts = @($(($conflicts.Command | Sort-Object | ForEach-Object { "'$_'" }) -join ', ')) to your Start-DFSession -Config
  Silence entirely: add SkipConflictCheck = `$true to your Start-DFSession -Config
"@
}
