#Requires -Version 7.0

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

    foreach ($entry in $Request) {
        if ($entry.Excluded -and -not (Test-DFToolActive $entry.Name)) {
            $status[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Excluded -RequestedBy $entry.RequestedBy -Detail 'excluded by ExcludeTools'
        }
    }
    $wanted = @($Request | Where-Object { -not $_.Excluded })
    $toolDb = if ($wanted) { Import-DFToolDb -Name $wanted.Name @pathArgs } else { @{} }
    $requestedBy = @{}
    foreach ($entry in $wanted) { $requestedBy[$entry.Name] = $entry.RequestedBy }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $wanted) {
        if ($toolDb.ContainsKey($entry.Name)) { $records.Add($toolDb[$entry.Name]) }
        else { $status[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Failed -RequestedBy $entry.RequestedBy -Detail 'its tool record is missing or invalid (see the warning above)' }
    }

    # Every excluded name, not just the requested ones: a required tool can be
    # excluded without having been requested.
    $groups = Get-DFGroupDb
    $excluded = @(foreach ($excludeEntry in @(Get-DFConfig ExcludeTools)) {
        if ($excludeEntry) { Expand-DFGroupEntry -Entry $excludeEntry -GroupDb $groups }
    })
    $requirements = Resolve-DFToolRequirements -Records $records -ToolDb $toolDb -RequestedBy $requestedBy -Excluded $excluded @pathArgs
    $edges = $requirements.Edges
    $blocked = $requirements.Blocked
    $roleHint = $requirements.RoleHint

    # after: ["role:<name>"] orders a tool after every requested member of that role.
    foreach ($record in $records) {
        foreach ($afterEntry in @($record.after | Where-Object { $_ -like 'role:*' })) {
            $role = $afterEntry.Substring(5)
            foreach ($member in @($toolDb.Values | Where-Object { $_.name -ne $record.name -and $_.roles.PSObject.Properties[$role] })) {
                $edges[$record.name] = @(@($edges[$record.name]) + $member.name | Where-Object { $_ })
            }
        }
    }

    $tools = @(Invoke-DFTopoSort -Tools $records.ToArray() -ExtraEdges $edges | Where-Object { $_ })
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

    $prewarmModules = @(foreach ($tool in $tools) {
        if ($tool.type -eq 'module' -and $tool.prewarm -and -not (Test-DFToolActive $tool.name) -and
            (Test-DFToolAvailable -Executable $tool.executable -Type 'module')) { $tool.executable }
    })
    $prewarmJob = if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
    try {
        foreach ($tool in $tools) {
            if ((Test-DFToolActive $tool.name) -and $tool.name -notin $Reactivate) { continue }
            if ($blocked.ContainsKey($tool.name)) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Missing -RequestedBy $requestedBy[$tool.name] -Detail $blocked[$tool.name]
                continue
            }
            # A required tool (not a role) was ordered first; if it then failed to
            # activate, neither can this one. (On a requires cycle, the tool not
            # yet reached has no status, so the cycle doesn't block itself.)
            $unmet = @(foreach ($req in @($tool.requires)) {
                if ($req -and $req -notlike 'role:*' -and $status.Contains($req) -and -not (Test-DFToolActive $req)) { $req }
            })
            if ($unmet) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Missing -RequestedBy $requestedBy[$tool.name] -Detail "requires $($unmet -join ', '), which is not available"
                continue
            }
            if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type)) {
                $detail = "'$($tool.executable)' is not installed"
                if ($roleHint.ContainsKey($tool.name)) { $detail += "; $(Get-DFRoleRequirementHint -Role $roleHint[$tool.name] @pathArgs)" }
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Missing -RequestedBy $requestedBy[$tool.name] -Detail $detail
                continue
            }
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
    }

    foreach ($roleOutcome in $winners.Values) {
        if ($status.Contains($roleOutcome.Winner) -and $roleOutcome.Role -notin $status[$roleOutcome.Winner].Roles) {
            $status[$roleOutcome.Winner].Roles = [string[]](@($status[$roleOutcome.Winner].Roles) + $roleOutcome.Role)
        }
        if ($roleOutcome.Reason -eq 'fallback' -and $status.Contains($roleOutcome.Preferred) -and $status[$roleOutcome.Preferred].State -eq 'Missing') {
            $status[$roleOutcome.Preferred].Detail = "$($status[$roleOutcome.Preferred].Detail); using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"
            $status[$roleOutcome.Preferred] | Add-Member -NotePropertyName FallbackRole -NotePropertyValue $roleOutcome.Role -Force
            $status[$roleOutcome.Preferred] | Add-Member -NotePropertyName FallbackTool -NotePropertyValue $roleOutcome.Winner -Force
        }
    }

    # Install hints are built later, when the status is read (Add-DFInstallHint).
    $script:DFSessionToolsPath = $ToolsPath

    foreach ($tool in $tools) { if (Test-DFToolActive $tool.name) { $tool } }
}

function New-DFToolStatus {
    <#
    .SYNOPSIS
        Creates one DotForge.ToolStatus record.
    .PARAMETER Name
        Tool name.
    .PARAMETER State
        Active, Missing, Failed or Excluded.
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
        [Parameter(Mandatory)][ValidateSet('Active', 'Missing', 'Failed', 'Excluded')][string]$State,
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
