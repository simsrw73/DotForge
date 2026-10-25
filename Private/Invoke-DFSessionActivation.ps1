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
            # A tool that only draws icons waits for a Nerd Font; the load says why (Write-DFNerdFontNotice).
            if ($tool.nerdFont -eq 'required' -and -not (Test-DFIconsOn)) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Excluded -RequestedBy $requestedBy[$tool.name] -Detail 'needs a Nerd Font (icons are off; see NerdFont)'
                continue
            }
            $blocker = @(Get-DFActivationBlocker -Tool $tool -Requirements $requirements @pathArgs)
            if ($blocker) {
                # Installed, but a tool it needs isn't active: Blocked. Not installed: Missing (Install-DFTool -Missing).
                $state = if (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type) { 'Blocked' } else { 'Missing' }
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State $state -RequestedBy $requestedBy[$tool.name] -Detail $blocker
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
                $oldLocations = if ($owned.State.Notes.ContainsKey($tool.name)) { $owned.State.Notes[$tool.name] } else { @() }
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name] -Detail @(@(Get-DFEnvKeptNote -Tool $tool.name) + @(Get-DFToolNote -Tool $tool.name) + @($oldLocations))
            } catch {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Failed -RequestedBy $requestedBy[$tool.name] -Detail $_.Exception.Message
            }
        }
    } finally {
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
        Complete-DFToolOwnership -State $owned.State
    }

    # A role nothing in the session fills may name a fallback (pager: more).
    Set-DFRoleFallback -RoleDb $roleDb -RoleWinners $winners -SessionTools @($script:DFSessionToolDb.Values) | Out-Null
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
        foreach ($afterEntry in @($record.after)) {
            $reference = ConvertFrom-DFToolReference -Reference $afterEntry
            if (-not $reference -or $reference.Kind -ne 'Role') { continue }
            foreach ($member in @(Get-DFRoleMember -Role $reference.Name -Tools @($ToolDb.Values) | Where-Object { $_.name -ne $record.name })) {
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
            -not ($tool.nerdFont -eq 'required' -and -not (Test-DFIconsOn)) -and
            (Test-DFToolAvailable -Executable $tool.executable -Type 'module')) { $tool.executable }
    })
    if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
}

function Get-DFActivationBlocker {
    <#
    .SYNOPSIS
        Says why a tool can't be activated now, or returns nothing when nothing blocks it.
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
        System.String[]: the reasons, empty when nothing blocks it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
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
        if ((ConvertFrom-DFToolReference -Reference $req).Kind -eq 'Tool' -and $status.Contains($req) -and -not (Test-DFToolActive $req)) { $req }
    })
    if ($unmet) { return "requires $($unmet -join ', '), which is not available" }
    if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    "'$($Tool.executable)' is not installed"
    if ($Requirements.RoleHint.ContainsKey($Tool.name)) {
        Get-DFRoleRequirementHint -Role $Requirements.RoleHint[$Tool.name] @pathArgs
    }
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
            Add-DFToolStatusDetail -Status $preferred -Text "using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"
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
        Active, Missing (not installed), Blocked (installed, but a tool it
        requires isn't active), Failed, Excluded or Conflict (its old config
        location holds the user's config; see Resolve-DFToolConflict).
    .PARAMETER RequestedBy
        'Tools', '+group', or what else requested it.
    .PARAMETER Detail
        Lines explaining the state (failure message, what blocks it, values kept over the tool's own). Joined with '; ' in Detail.
    .OUTPUTS
        DotForge.ToolStatus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Active', 'Missing', 'Blocked', 'Failed', 'Excluded', 'Conflict')][string]$State,
        [string]$RequestedBy,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Detail = @()
    )
    $status = [pscustomobject]@{
        PSTypeName  = 'DotForge.ToolStatus'
        Name        = $Name
        State       = $State
        RequestedBy = $RequestedBy
        Roles       = [string[]]@()
        DetailItems = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($line in $Detail) { if ($line) { $status.DetailItems.Add($line) } }
    # One place renders the lines, so no producer joins strings itself (T-28).
    $status | Add-Member -MemberType ScriptProperty -Name Detail -Value { $this.DetailItems -join '; ' }
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Name', 'State', 'RequestedBy', 'Roles', 'Detail'))
    $status | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    $status
}

function Add-DFToolStatusDetail {
    <#
    .SYNOPSIS
        Appends a line to a tool status's Detail.
    .PARAMETER Status
        A DotForge.ToolStatus record.
    .PARAMETER Text
        The line; empty text is ignored.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Status, [AllowEmptyString()][string]$Text)
    if ($Text) { $Status.DetailItems.Add($Text) }
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
        Warns, at the end of a load, about requested tools that are missing or failed, prints new setup notes, and says why icons are off.
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
    Write-DFSetupNoteNotice
    Write-DFNerdFontNotice
    if (-not $script:DFSessionStatus) { return }
    $all = @($script:DFSessionStatus.Values)
    $missing = @($all | Where-Object State -eq 'Missing')
    $failed = @($all | Where-Object State -eq 'Failed')
    $blocked = @($all | Where-Object State -eq 'Blocked')
    if ($blocked) {
        $what = if ($blocked.Count -eq 1) { "1 tool can't load until a tool it needs does" } else { "$($blocked.Count) tools can't load until tools they need do" }
        Write-Warning "DotForge: $what`: $(($blocked | ForEach-Object { "$($_.Name) ($($_.Detail))" }) -join ', ')."
    }
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
    # One line for every tool waiting on the user; each one's advice is in Get-DFToolStatus -Conflict.
    $waiting = @($all | Where-Object { $_.State -eq 'Conflict' -and -not $_.Warned })
    if ($waiting) {
        foreach ($conflicted in $waiting) { $conflicted.Warned = $true }
        $what = if ($waiting.Count -eq 1) { '1 tool is' } else { "$($waiting.Count) tools are" }
        Write-Warning "DotForge: $what waiting on your existing config: $($waiting.Name -join ', '). See Get-DFToolStatus -Conflict, or run Resolve-DFToolConflict to go through them."
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
        State (Test-DFToolOwnership's state: Table, Readable, Changed,
        Unchecked, Clean).
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
        Changed   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Unchecked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Clean     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Notes     = @{}   # tool -> notes about old locations that don't hold it back
        Reactivate = $Reactivate
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
        Checks one installed tool against its existing data: links an empty XDG location to it, or returns false (status Conflict) when both hold content.
    .DESCRIPTION
        For each location Find-DFToolConflict classifies as Link, the XDG
        location is linked to the existing data (New-DFToolLink) and the tool
        is recorded as owned with how 'linked' and its links; registration then
        leaves those variables unset and seeds nothing inside them. An owned
        linked tool's links are checked: one whose target is gone is removed,
        with a note, and the tool behaves as fresh again. A tool with no
        conflict, a complete check and a relocated path is listed in
        State.Clean, to be recorded as owned (how: clean) if it ends up active.
        Changes go into State.Table and their names into State.Changed.
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
    $name = $Record.name
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($table.ContainsKey($name) -and $table[$name].how -eq 'linked') {
        $kept = Confirm-DFToolLinks -Name $name -Entry $table[$name] -Notes $notes
        if ($kept.Count -ne @($table[$name].links).Count) {
            if ($kept.Count) { $table[$name].links = @($kept) } else { $table.Remove($name) }
            $null = $State.Changed.Add($name)
        }
    }
    $check = Find-DFToolConflict -Tool $Record -Ownership $table -Written (Get-DFEnvState).Written
    $blocking = @($check.Conflicts | Where-Object Action -eq 'Conflict')
    if ($blocking) {
        Set-DFToolLinkState -Name $name
        $paths = @($blocking.OldPaths) -join ', '
        $status = New-DFToolStatus -Name $name -State Conflict -RequestedBy $RequestedBy[$name] -Detail "your existing data at $paths and the XDG location both hold content. $((Get-DFConflictAdvice -Name $name -Conflicts $blocking).Text)"
        $status | Add-Member -NotePropertyName Conflicts -NotePropertyValue $blocking
        # Write-DFSessionNotice warns once per conflict: a later Register-DFTool
        # re-checks every requested tool, but warns again only for one it names.
        $previous = $script:DFSessionStatus[$name]
        $warned = $name -notin $State.Reactivate -and $previous -and $previous.State -eq 'Conflict' -and
            $previous.PSObject.Properties['Warned'] -and $previous.Warned
        $status | Add-Member -NotePropertyName Warned -NotePropertyValue ([bool]$warned)
        $script:DFSessionStatus[$name] = $status
        return $false
    }
    $toLink = @($check.Conflicts | Where-Object Action -eq 'Link')
    # Every planned link keeps its variable unset and its folder seed-free this session, made or not:
    # the tool then uses its existing data where it is.
    $planned = @(foreach ($item in $toLink) { [pscustomobject]@{ key = $item.Key; path = $item.Target; target = $item.Existing; made = $false } })
    if ($toLink -and -not $State.Readable) {
        # Links can't be recorded, so none are made: an unrecorded link would never be cleaned up.
        $notes.Add("$(Get-DFToolOwnershipPath) can't be read right now, so DotForge uses your existing data where it is and links it on a later load")
    } elseif ($toLink) {
        foreach ($link in $planned) { $link.made = New-DFToolLinkFor -Path $link.path -Target $link.target -Notes $notes }
        # A link that failed outright (not one waiting on Developer Mode) is retried next load, unrecorded.
        # ($true -ne 'failed' is false in PowerShell: the string converts to a boolean, so test the type.)
        $recorded = @($planned | Where-Object { $_.made -isnot [string] })
        if ($recorded) {
            $table[$name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'linked'; links = $recorded }
            $null = $State.Changed.Add($name)
        }
    }
    $owned = @(if ($table.ContainsKey($name) -and $table[$name].how -eq 'linked') { $table[$name].links })
    Set-DFToolLinkState -Name $name -Links @(if ($toLink) { $planned } else { $owned })
    if ($notes.Count -and $State.PSObject.Properties['Notes']) { $State.Notes[$name] = [string[]]$notes }
    if (-not $State.Readable) { return $true }
    if ($check.Complete -and -not $toLink -and -not $table.ContainsKey($name) -and @(Get-DFToolRelocation -Tool $Record)) {
        $null = $State.Clean.Add($name)
    }
    $true
}

function New-DFToolLinkFor {
    <#
    .SYNOPSIS
        Links one XDG location to a tool's existing data and notes it in the tool's status: $true (linked), $false (waits on Developer Mode) or 'failed'.
    .DESCRIPTION
        A link that can't be made (a network-share target, a folder in use, a
        race with another shell) never fails the load: it is noted, and the
        tool keeps using its existing data.
    .PARAMETER Path
        The XDG location.
    .PARAMETER Target
        The existing data.
    .PARAMETER Notes
        The tool's status notes; one is added per link (or per link that can't be made).
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Notes)
    try { $result = New-DFToolLink -Path $Path -Target $Target }
    catch {
        $Notes.Add("couldn't link $Path to your existing $Target ($($_.Exception.Message)); the tool uses it where it is, and DotForge tries again next load")
        return 'failed'
    }
    if ($result.Made) { $Notes.Add("linked $Path to your existing $Target") } else { $Notes.Add("your existing data is at $Target; $($result.Note)") }
    $result.Made
}

function Confirm-DFToolLinks {
    <#
    .SYNOPSIS
        Checks an owned linked tool's links: removes one whose target is gone (with a note), retries one that couldn't be made, and returns the links still in use.
    .PARAMETER Name
        The tool.
    .PARAMETER Entry
        Its ownership entry (how linked).
    .PARAMETER Notes
        The tool's status notes.
    .OUTPUTS
        PSCustomObject[]: the links to keep.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][PSCustomObject]$Entry, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Notes)
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($link in @($Entry.links)) {
        if (-not (Test-Path -LiteralPath $link.target)) {
            try { Remove-DFToolLink -Path $link.path }
            catch { $Notes.Add("couldn't remove the link at $($link.path) ($($_.Exception.Message))") }
            $Notes.Add("$($link.target) is gone (was $Name uninstalled?), so DotForge removed its link at $($link.path) and uses the XDG location again")
            continue
        }
        $made = if ((Get-DFToolLinkTarget -Path $link.path) -eq (ConvertTo-DFPath $link.target)) {
            $Notes.Add("linked $($link.path) to your existing $($link.target)")
            $true
        } elseif (-not (Test-Path -LiteralPath $link.path)) {
            (New-DFToolLinkFor -Path $link.path -Target $link.target -Notes $Notes) -eq $true
        } else {
            $Notes.Add("$($link.path) is no longer DotForge's link to $($link.target); DotForge leaves it alone")
            $true
        }
        $kept.Add([pscustomobject]@{ key = $link.key; path = $link.path; target = $link.target; made = $made })
    }
    , $kept.ToArray()
}

function Complete-DFToolOwnership {
    <#
    .SYNOPSIS
        Records as owned the checked tools that ended up active, then saves the ownership table if anything changed.
    .DESCRIPTION
        A tool that was blocked or failed isn't recorded: the user may keep
        using it outside DotForge, and its config must still be found later.
    .PARAMETER State
        Select-DFOwnedRecord's State.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State)
    if (-not $State.Readable) { return }
    foreach ($name in $State.Clean) {
        if (-not (Test-DFToolActive $name)) { continue }
        $State.Table[$name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'clean' }
        $null = $State.Changed.Add($name)
    }
    if ($State.Changed.Count) { Save-DFToolOwnership -Ownership $State.Table -Name @($State.Changed) }
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
            $reference = ConvertFrom-DFToolReference -Reference $req
            if (-not $reference) { continue }
            if ($reference.Kind -eq 'Role') {
                $role = $reference.Name
                $members = @(Get-DFRoleMember -Role $role -Tools @($ToolDb.Values))
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
        $names = @(Get-DFRoleMember -Role $r -Tools @($all.Values) | ForEach-Object name)
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
            Add-DFToolStatusDetail -Status $st -Text "Install-DFTool -Missing will install it $how"
        }
        foreach ($g in $plan.Gaps) {
            $st = $script:DFSessionStatus[$g.Tool]
            if ($st -and $st -in $todo) { Add-DFToolStatusDetail -Status $st -Text "can't install yet: $($g.Reason)" }
        }
    } catch {
        Write-Verbose "DotForge: couldn't work out how missing tools would install: $($_.Exception.Message)"
    }
}
