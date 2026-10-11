#Requires -Version 7.2

# What the current session decided, per requested tool: name -> DotForge.ToolStatus.
# $null until Start-DFSession (or Register-DFTool) first runs. Get-DFToolStatus reads it.
$script:DFSessionStatus = $null
# The session's requested tool records and role winners, for Get-DFRole.
$script:DFSessionToolDb = @{}
$script:DFSessionRoleWinners = $null
$script:DFSessionToolsPath = $null

function Invoke-DFSessionActivation {
    <#
    .SYNOPSIS
        Checks, sets up and activates a set of requested tools, recording each one's status for the session.
    .DESCRIPTION
        The shared core of Start-DFSession and Register-DFTool -Name. For the
        given request entries (Resolve-DFRequestedTools output):
          - reads only those tool records (Import-DFToolDb -Name);
          - orders them by after and requires;
          - picks role winners among them (Get-DFRoleWinners);
          - activates each installed one through Invoke-DFToolRegistration,
            including its one-time setup. A failure is recorded as Failed with
            its message, and the rest continue.
        A tool already Active in this session is not activated again, so a
        second call only adds. Each tool's status (Active, Missing, Failed,
        Excluded) goes into $script:DFSessionStatus, along with the roles it
        won and the fallback detail for a missing preferred role tool.
    .PARAMETER Request
        Request entries: Name, RequestedBy, Excluded.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .PARAMETER Reactivate
        Tools to activate again even if already Active (Register-DFTool -Name:
        re-applying a tool you name is the point of naming it).
    .OUTPUTS
        The tool records that are Active after this call.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Request = @(),
        [string]$ToolsPath,
        [AllowEmptyCollection()][string[]]$Reactivate = @()
    )
    if (-not $script:DFSessionStatus) {
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $status = $script:DFSessionStatus
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $toolsDir = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath } else { Join-Path $PSScriptRoot '../Tools' })

    Set-DFExcludedToolStatus -Request $Request
    $wanted = @($Request | Where-Object { -not $_.Excluded })
    $toolDb = if ($wanted) { Import-DFToolDb -Name $wanted.Name @pathArgs } else { @{} }
    $requestedBy = @{}
    foreach ($entry in $wanted) { $requestedBy[$entry.Name] = $entry.RequestedBy }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $wanted) {
        if ($toolDb.ContainsKey($entry.Name)) { $records.Add($toolDb[$entry.Name]) }
        else { $status[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Failed -RequestedBy $entry.RequestedBy -Detail 'its tool record is missing or invalid (see the warning above)' }
    }

    $requirements = Resolve-DFToolRequirements -Records $records -ToolDb $toolDb -RequestedBy $requestedBy `
        -Excluded @(Get-DFExcludedToolNames) @pathArgs
    # A tool whose old config location still holds the user's config is left
    # alone entirely until they resolve it (Resolve-DFToolConflict).
    $owned = Select-DFOwnedRecord -Records $records -RequestedBy $requestedBy -Reactivate $Reactivate
    $records = $owned.Records
    $tools = @(Get-DFActivationOrder -Records $records -ToolDb $toolDb -RequirementEdges $requirements.Edges)
    $roleDb = Get-DFRoleDb
    $winners = Get-DFRoleWinners -ToolDb $toolDb -Tools $tools -RoleDb $roleDb
    # Stored before any companion runs: a companion may ask Get-DFRole who won.
    foreach ($name in $toolDb.Keys) { $script:DFSessionToolDb[$name] = $toolDb[$name] }
    $script:DFSessionRoleWinners = $winners
    Write-DFRoleNotice -RoleWinners $winners -RoleDb $roleDb
    $context = [pscustomobject]@{
        RoleWinners = $winners
        RoleDb      = $roleDb
        ToolsPath   = $toolsDir
        SkipSetup   = @(Get-DFConfig SkipSetup)
    }

    $prewarmJob = Start-DFActivationPrewarm -Tools $tools
    try {
        foreach ($tool in $tools) {
            if ((Test-DFToolActive $tool.name) -and $tool.name -notin $Reactivate) { continue }
            $blocker = Get-DFActivationBlocker -Tool $tool -Requirements $requirements @pathArgs
            if ($blocker) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Missing -RequestedBy $requestedBy[$tool.name] -Detail $blocker
                continue
            }
            # Installed only now (an earlier companion put it on PATH, as fnm does
            # for node and npm): its ownership check couldn't run before.
            if ($owned.State.Unchecked.Contains($tool.name) -and
                -not (Test-DFToolOwnership -Record $tool -State $owned.State -RequestedBy $requestedBy)) { continue }
            # One tool's failure (a throwing companion, or any error under a
            # profile's $ErrorActionPreference = 'Stop') must not stop the rest.
            try {
                Invoke-DFToolRegistration -Tool $tool -Context $context
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name]
            } catch {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Failed -RequestedBy $requestedBy[$tool.name] -Detail $_.Exception.Message
            }
        }
    } finally {
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
        if ($owned.State.Changed) { Save-DFToolOwnership -Ownership $owned.State.Table }
    }

    Add-DFRoleOutcomeStatus -RoleWinners $winners

    # Install hints are built later, when the status is read (Add-DFInstallHint).
    $script:DFSessionToolsPath = $ToolsPath

    foreach ($tool in $tools) { if (Test-DFToolActive $tool.name) { $tool } }
}

function Set-DFExcludedToolStatus {
    <#
    .SYNOPSIS
        Records Excluded for each excluded request entry that isn't already Active.
    .PARAMETER Request
        Request entries: Name, RequestedBy, Excluded.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Request = @())
    foreach ($entry in $Request) {
        if ($entry.Excluded -and -not (Test-DFToolActive $entry.Name)) {
            $script:DFSessionStatus[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Excluded `
                -RequestedBy $entry.RequestedBy -Detail 'excluded by ExcludeTools'
        }
    }
}

function Get-DFExcludedToolNames {
    <#
    .SYNOPSIS
        Every tool name ExcludeTools excludes, with +groups expanded.
    .DESCRIPTION
        Every excluded name, not just the requested ones: a required tool can be
        excluded without having been requested.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $groups = Get-DFGroupDb
    foreach ($excludeEntry in @(Get-DFConfig ExcludeTools)) {
        if ($excludeEntry) { Expand-DFGroupEntry -Entry $excludeEntry -GroupDb $groups }
    }
}

function Get-DFActivationOrder {
    <#
    .SYNOPSIS
        Orders the records for activation: by after, requires, and after: ["role:<name>"].
    .DESCRIPTION
        after: ["role:<name>"] orders a tool after every requested member of
        that role. Those edges are added to (a copy of) the requirement edges,
        and Invoke-DFTopoSort orders the records.
    .PARAMETER Records
        The records to order.
    .PARAMETER ToolDb
        Name -> record for the requested tools.
    .PARAMETER RequirementEdges
        Resolve-DFToolRequirements' Edges: tool name -> names it must come after.
    .OUTPUTS
        The records, in activation order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][hashtable]$RequirementEdges
    )
    $edges = @{}
    foreach ($name in $RequirementEdges.Keys) { $edges[$name] = @($RequirementEdges[$name]) }
    foreach ($record in $Records) {
        foreach ($afterEntry in @($record.after | Where-Object { $_ -like 'role:*' })) {
            $role = $afterEntry.Substring(5)
            foreach ($member in @($ToolDb.Values | Where-Object { $_.name -ne $record.name -and $_.roles.PSObject.Properties[$role] })) {
                $edges[$record.name] = @(@($edges[$record.name]) + $member.name | Where-Object { $_ })
            }
        }
    }
    Invoke-DFTopoSort -Tools $Records.ToArray() -ExtraEdges $edges | Where-Object { $_ }
}

function Start-DFActivationPrewarm {
    <#
    .SYNOPSIS
        Starts loading, in the background, the installed prewarm modules about to be activated.
    .PARAMETER Tools
        The ordered tool records.
    .OUTPUTS
        The prewarm job, or nothing when no module needs it.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Tools = @())
    $prewarmModules = @(foreach ($tool in $Tools) {
        if ($tool.type -eq 'module' -and $tool.prewarm -and -not (Test-DFToolActive $tool.name) -and
            (Test-DFToolAvailable -Executable $tool.executable -Type 'module')) { $tool.executable }
    })
    if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
}

function Get-DFActivationBlocker {
    <#
    .SYNOPSIS
        Says why a tool can't be activated now, or returns an empty string when nothing blocks it.
    .DESCRIPTION
        In order: a requirement Resolve-DFToolRequirements blocked (excluded, or
        no record); a required tool that didn't activate; the tool not being
        installed (with a hint naming any required role none of whose members
        is requested).
    .PARAMETER Tool
        The tool record.
    .PARAMETER Requirements
        Resolve-DFToolRequirements result.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$Requirements,
        [string]$ToolsPath
    )
    if ($Requirements.Blocked.ContainsKey($Tool.name)) { return $Requirements.Blocked[$Tool.name] }
    # A required tool (not a role) was ordered first; if it then failed to
    # activate, neither can this one. (On a requires cycle, the tool not
    # yet reached has no status, so the cycle doesn't block itself.)
    $status = $script:DFSessionStatus
    $unmet = @(foreach ($req in @($Tool.requires)) {
        if ($req -and $req -notlike 'role:*' -and $status.Contains($req) -and -not (Test-DFToolActive $req)) { $req }
    })
    if ($unmet) { return "requires $($unmet -join ', '), which is not available" }
    if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return '' }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $detail = "'$($Tool.executable)' is not installed"
    if ($Requirements.RoleHint.ContainsKey($Tool.name)) {
        $detail += "; $(Get-DFRoleRequirementHint -Role $Requirements.RoleHint[$Tool.name] @pathArgs)"
    }
    $detail
}

function Add-DFRoleOutcomeStatus {
    <#
    .SYNOPSIS
        Adds the role outcomes to the session status: each winner's Roles, and each missing preferred tool's stand-in.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$RoleWinners)
    $status = $script:DFSessionStatus
    foreach ($roleOutcome in $RoleWinners.Values) {
        if ($status.Contains($roleOutcome.Winner) -and $roleOutcome.Role -notin $status[$roleOutcome.Winner].Roles) {
            $status[$roleOutcome.Winner].Roles = [string[]](@($status[$roleOutcome.Winner].Roles) + $roleOutcome.Role)
        }
        if ($roleOutcome.Reason -eq 'fallback' -and $status.Contains($roleOutcome.Preferred) -and $status[$roleOutcome.Preferred].State -eq 'Missing') {
            $preferred = $status[$roleOutcome.Preferred]
            $preferred.Detail = "$($preferred.Detail); using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"
            $preferred | Add-Member -NotePropertyName FallbackRole -NotePropertyValue $roleOutcome.Role -Force
            $preferred | Add-Member -NotePropertyName FallbackTool -NotePropertyValue $roleOutcome.Winner -Force
        }
    }
}

function New-DFToolStatus {
    <#
    .SYNOPSIS
        Creates one DotForge.ToolStatus record.
    .PARAMETER Name
        Tool name.
    .PARAMETER State
        Active, Missing, Failed, Excluded or Conflict (its old config location
        holds the user's config; see Resolve-DFToolConflict).
    .PARAMETER RequestedBy
        'Tools', '+group', or what else requested it.
    .PARAMETER Detail
        Failure message or other explanation.
    .OUTPUTS
        DotForge.ToolStatus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Active', 'Missing', 'Failed', 'Excluded', 'Conflict')][string]$State,
        [string]$RequestedBy,
        [string]$Detail
    )
    [pscustomobject]@{
        PSTypeName  = 'DotForge.ToolStatus'
        Name        = $Name
        State       = $State
        RequestedBy = $RequestedBy
        Roles       = [string[]]@()
        Detail      = $Detail
    }
}

function Test-DFToolActive {
    <#
    .SYNOPSIS
        True when the tool is Active in this session.
    .PARAMETER Name
        Tool name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    [bool]($script:DFSessionStatus -and $script:DFSessionStatus.Contains($Name) -and
        $script:DFSessionStatus[$Name].State -eq 'Active')
}

function Set-DFXdgEnvironment {
    <#
    .SYNOPSIS
        Exports the five XDG folders to the session and creates them.
    .DESCRIPTION
        A value you set is kept (canonicalized); an unset one gets its XDG
        default from Get-DFXdgPath. Exported so other programs see them too.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    foreach ($kind in 'Config', 'Data', 'State', 'Cache', 'Bin') {
        $path = Get-DFXdgPath $kind
        Set-Item -Path "Env:XDG_$($kind.ToUpperInvariant())_HOME" -Value $path
        New-DFDirectory $path
    }
}

function Write-DFSessionNotice {
    <#
    .SYNOPSIS
        Warns, at the end of a load, about requested tools that are missing or failed.
    .DESCRIPTION
        Silent when nothing is missing. Up to five missing tools are named,
        each with the role it was preferred for and its stand-in when one is
        in use; more than five gives the count and the commands instead.
        Failed tools get their own line.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:DFSessionStatus) { return }
    $all = @($script:DFSessionStatus.Values)
    $missing = @($all | Where-Object State -eq 'Missing')
    $failed = @($all | Where-Object State -eq 'Failed')
    if ($missing) {
        $n = $missing.Count
        $what = if ($n -eq 1) { "1 requested tool isn't installed" } else { "$n requested tools aren't installed" }
        if ($n -le 5) {
            $names = foreach ($m in $missing) {
                if ($m.PSObject.Properties['FallbackTool']) { "$($m.Name) ($($m.FallbackRole) — using $($m.FallbackTool))" } else { $m.Name }
            }
            Write-Warning "DotForge: $what`: $($names -join ', '). Run Install-DFTool -Missing to install $(if ($n -eq 1) { 'it' } else { 'them' })."
        } else {
            Write-Warning "DotForge: $what. See Get-DFToolStatus -Missing; install them with Install-DFTool -Missing."
        }
    }
    if ($failed) {
        $what = if ($failed.Count -eq 1) { '1 tool failed to load' } else { "$($failed.Count) tools failed to load" }
        Write-Warning "DotForge: $what`: $($failed.Name -join ', '). See Get-DFToolStatus -Failed."
    }
    foreach ($conflicted in @($all | Where-Object State -eq 'Conflict')) {
        $name = $conflicted.Name
        $paths = @($conflicted.Conflicts.OldPaths) -join ', '
        $guides = @($conflicted.Conflicts | Where-Object { -not $_.Move } | ForEach-Object Guide)
        $inUse = @($conflicted.Conflicts | Where-Object TargetHasContent | ForEach-Object Target)
        $how = if ($guides) { "$($guides -join ' ') Then run Resolve-DFToolConflict $name -Adopt" }
               elseif ($inUse) { "$($inUse -join ', ') has config too: if that is the copy you use, copy anything you need from the old one into it and run Resolve-DFToolConflict $name -Adopt" }
               else { "Run Resolve-DFToolConflict $name -Move (or -Adopt)" }
        Write-Warning "DotForge: $name isn't active: your existing config at $paths would be hidden. $how, or remove $name from Tools."
    }
}

function Select-DFOwnedRecord {
    <#
    .SYNOPSIS
        Drops requested tools whose config DotForge would hide, recording their Conflict status; records the rest as owned.
    .DESCRIPTION
        Runs before activation order and roles, so a tool in conflict gets no
        role and blocks the tools that require it. Only installed tools that
        aren't already active are checked here; one that isn't installed yet
        is listed in State.Unchecked and checked by the activation loop when
        its turn comes (an earlier companion may put it on PATH). Ownership
        changes are saved once, after the loop. See
        docs/superpowers/specs/2026-10-11-config-ownership-design.md.
    .PARAMETER Records
        The requested records (after Resolve-DFToolRequirements).
    .PARAMETER RequestedBy
        Name -> RequestedBy.
    .PARAMETER Reactivate
        Names re-registered on purpose (checked even when active).
    .OUTPUTS
        pscustomobject: Records (List[object], the records to activate) and
        State (Test-DFToolOwnership's state: Table, Readable, Changed, Unchecked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Reactivate = @()
    )
    $table = Read-DFToolOwnership
    $state = [pscustomobject]@{
        # Unreadable: still check (nothing owned), but never write over the file.
        Table     = if ($null -ne $table) { $table } else { @{} }
        Readable  = $null -ne $table
        Changed   = $false
        Unchecked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        if ((Test-DFToolActive $record.name) -and $record.name -notin $Reactivate) { $kept.Add($record); continue }
        if (-not (Test-DFToolAvailable -Executable $record.executable -Type $record.type)) {
            $null = $state.Unchecked.Add($record.name)
            $kept.Add($record)
            continue
        }
        if (Test-DFToolOwnership -Record $record -State $state -RequestedBy $RequestedBy) { $kept.Add($record) }
    }
    [pscustomobject]@{ Records = $kept; State = $state }
}

function Test-DFToolOwnership {
    <#
    .SYNOPSIS
        Checks one installed tool against the ownership table: false (and status Conflict) when its old config location holds the user's config.
    .DESCRIPTION
        A tool with no conflict, a complete check and a relocated path is
        recorded as owned (how: clean). An owned tool's unfinished removals
        from Resolve-DFToolConflict -Move are retried. Changes go into
        State.Table and set State.Changed; the caller saves them.
    .PARAMETER Record
        The tool record.
    .PARAMETER State
        Select-DFOwnedRecord's State.
    .PARAMETER RequestedBy
        Name -> RequestedBy.
    .OUTPUTS
        System.Boolean: whether the tool may be activated.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Record,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][hashtable]$RequestedBy
    )
    $table = $State.Table
    $check = Find-DFToolConflict -Tool $Record -Ownership $table
    if ($check.Conflicts) {
        $paths = @($check.Conflicts.OldPaths) -join ', '
        $status = New-DFToolStatus -Name $Record.name -State Conflict -RequestedBy $RequestedBy[$Record.name] -Detail "your existing config at $paths would be hidden"
        $status | Add-Member -NotePropertyName Conflicts -NotePropertyValue $check.Conflicts
        $script:DFSessionStatus[$Record.name] = $status
        return $false
    }
    if (-not $State.Readable) { return $true }
    if ($check.Complete -and -not $table.ContainsKey($Record.name) -and @(Get-DFToolRelocation -Tool $Record)) {
        $table[$Record.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'clean' }
        $State.Changed = $true
    }
    if ($table.ContainsKey($Record.name) -and $table[$Record.name].PSObject.Properties['pending']) {
        if (Invoke-DFPendingRemoval -Name $Record.name -Ownership $table) { $State.Changed = $true }
    }
    $true
}
function Resolve-DFToolRequirements {
    <#
    .SYNOPSIS
        Expands the requested tools' requires: adds required tools, and records the ordering requirements impose.
    .DESCRIPTION
        For each record's requires entry, transitively:
          - A tool name: the tool is requested too (RequestedBy
            'requires (<tool>)') and ordered first. If it is excluded, or has
            no record, the requiring tool is blocked with that reason.
          - role:<name>: the tool is ordered after every requested member of
            the role. A member is never requested on the user's behalf: which
            version manager or runtime to use is the user's choice, made by
            listing it in Tools. With no member requested nothing is blocked
            (the runtime can come from outside DotForge, e.g. a standalone
            node on PATH); the role is recorded in RoleHint so that, if the
            tool turns out to be missing, its detail can name the role.
    .PARAMETER Records
        The requested records. Required tools are appended.
    .PARAMETER ToolDb
        Name -> record for the requested tools. Additions are added here too.
    .PARAMETER RequestedBy
        Name -> RequestedBy. Additions are recorded here.
    .PARAMETER Excluded
        Names excluded by ExcludeTools.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        pscustomobject with three hashtables:
          Edges: tool name -> names it must come after (for Invoke-DFTopoSort -ExtraEdges).
          Blocked: tool name -> why it can't be activated.
          RoleHint: tool name -> the required roles none of whose members is requested.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Excluded = @(),
        [string]$ToolsPath
    )
    $edges = @{}
    $blocked = @{}
    $roleHint = @{}
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $add = {
        param($Record, [string]$By)
        $ToolDb[$Record.name] = $Record
        $RequestedBy[$Record.name] = $By
        $Records.Add($Record)
        $queue.Enqueue($Record)
    }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($record in $Records.ToArray()) { $queue.Enqueue($record) }

    while ($queue.Count) {
        $record = $queue.Dequeue()
        foreach ($req in @($record.requires)) {
            if (-not $req) { continue }
            if ($req -like 'role:*') {
                $role = $req.Substring(5)
                $members = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties[$role] })
                if (-not $members) { $roleHint[$record.name] = @(@($roleHint[$record.name]) + $role | Where-Object { $_ }) }
                foreach ($member in $members) {
                    if ($member.name -ne $record.name) { $edges[$record.name] = @(@($edges[$record.name]) + $member.name | Where-Object { $_ }) }
                }
                continue
            }
            if ($req -in $Excluded) {
                $blocked[$record.name] = "requires $req, which is excluded"
                continue
            }
            if (-not $ToolDb.ContainsKey($req)) {
                $found = Import-DFToolDb -Name $req @pathArgs
                if (-not $found.Count) {
                    $blocked[$record.name] = "requires $req, which has no tool record"
                    continue
                }
                & $add @($found.Values)[0] "requires ($($record.name))"
            }
            $edges[$record.name] = @(@($edges[$record.name]) + $req | Where-Object { $_ })
        }
    }
    [pscustomobject]@{ Edges = $edges; Blocked = $blocked; RoleHint = $roleHint }
}

function Get-DFRoleRequirementHint {
    <#
    .SYNOPSIS
        Says which tools could fill roles a missing tool requires, e.g. "needs a js-runtime: add fnm or mise to Tools".
    .DESCRIPTION
        Finding a role's members means reading every tool record, so this runs
        only when a tool is already missing, never on a normal load.
    .PARAMETER Role
        The role names.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Role,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $all = Import-DFToolDb @pathArgs
    @(foreach ($r in $Role) {
        $names = @($all.Values | Where-Object { $_.roles.PSObject.Properties[$r] } | ForEach-Object name | Sort-Object)
        if ($names.Count -gt 1) { "needs a $r`: add $($names[0..($names.Count - 2)] -join ', ') or $($names[-1]) to Tools" }
        elseif ($names) { "needs a $r`: add $($names[0]) to Tools" }
        else { "needs a $r" }
    }) -join '; '
}

function Add-DFInstallHint {
    <#
    .SYNOPSIS
        Adds to each Missing tool's status detail how Install-DFTool would install it.
    .DESCRIPTION
        Building the install layer reads every tool record, so it runs when the
        status is read (Get-DFToolStatus), never at startup, and once per tool.
        A failure (say, a malformed manager record) is reported with
        Write-Verbose; the status stays usable.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:DFSessionStatus) { return }
    $todo = @($script:DFSessionStatus.Values | Where-Object {
        $_.State -eq 'Missing' -and -not $_.PSObject.Properties['InstallHinted'] -and -not $_.PSObject.Properties['FallbackTool'] })
    if (-not $todo) { return }
    foreach ($s in $todo) { $s | Add-Member -NotePropertyName InstallHinted -NotePropertyValue $true -Force }
    try {
        $pathArgs = if ($script:DFSessionToolsPath) { @{ ToolsPath = $script:DFSessionToolsPath } } else { @{} }
        $all = Import-DFToolDb @pathArgs
        $plan = New-DFInstallPlan -Name @($todo | ForEach-Object { $_.Name }) -ToolDb $all `
            -IsAvailable { param($r) $r -and (Test-DFToolAvailable -Executable $r.executable -Type $r.type) } 3>$null
        foreach ($it in $plan.Items) {
            $st = $script:DFSessionStatus[$it.Tool]
            if (-not $st -or $st -notin $todo) { continue }
            $how = if ($it.ProvidedBy) { "comes with $($it.ProvidedBy)" } else { "via $($it.Manager.name)" }
            $st.Detail = "$($st.Detail); Install-DFTool -Missing will install it $how"
        }
        foreach ($g in $plan.Gaps) {
            $st = $script:DFSessionStatus[$g.Tool]
            if ($st -and $st -in $todo) { $st.Detail = "$($st.Detail); can't install yet: $($g.Reason)" }
        }
    } catch {
        Write-Verbose "DotForge: couldn't work out how missing tools would install: $($_.Exception.Message)"
    }
}
