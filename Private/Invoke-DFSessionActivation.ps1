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

    foreach ($e in $Request) {
        if ($e.Excluded -and -not ($status.Contains($e.Name) -and $status[$e.Name].State -eq 'Active')) {
            $status[$e.Name] = New-DFToolStatus -Name $e.Name -State Excluded -RequestedBy $e.RequestedBy -Detail 'excluded by ExcludeTools'
        }
    }
    $wanted = @($Request | Where-Object { -not $_.Excluded })
    $db = if ($wanted) { Import-DFToolDb -Name $wanted.Name @pathArgs } else { @{} }
    $by = @{}
    foreach ($e in $wanted) { $by[$e.Name] = $e.RequestedBy }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $wanted) {
        if ($db.ContainsKey($e.Name)) { $records.Add($db[$e.Name]) }
        else { $status[$e.Name] = New-DFToolStatus -Name $e.Name -State Failed -RequestedBy $e.RequestedBy -Detail 'its tool record is missing or invalid (see the warning above)' }
    }

    $edges = @{}
    $blocked = @{}
    $roleHint = @{}
    # Every excluded name, not just the requested ones: a required tool can be
    # excluded without having been requested.
    $groups = Get-DFGroupDb
    $excluded = @(foreach ($x in @(Get-DFConfig ExcludeTools)) {
        if (-not $x) { continue }
        if ($x.StartsWith('+')) { $g = $x.Substring(1); if ($groups.Contains($g)) { $groups[$g].Tools } } else { $x }
    })
    Resolve-DFToolRequirements -Records $records -ToolDb $db -RequestedBy $by -Excluded $excluded `
        -Edges $edges -Blocked $blocked -RoleHint $roleHint @pathArgs

    # after: ["role:<name>"] orders a tool after every requested member of that role.
    foreach ($r in $records) {
        foreach ($a in @($r.after | Where-Object { $_ -like 'role:*' })) {
            $role = $a.Substring(5)
            foreach ($m in @($db.Values | Where-Object { $_.name -ne $r.name -and $_.roles.PSObject.Properties[$role] })) {
                $edges[$r.name] = @(@($edges[$r.name]) + $m.name | Where-Object { $_ })
            }
        }
    }

    $tools = @(Invoke-DFTopoSort -Tools $records.ToArray() -ExtraEdges $edges | Where-Object { $_ })
    $roleDb = Get-DFRoleDb
    $winners = Get-DFRoleWinners -ToolDb $db -Tools $tools -RoleDb $roleDb
    # Stored before any companion runs: a companion may ask Get-DFRole who won.
    foreach ($k in $db.Keys) { $script:DFSessionToolDb[$k] = $db[$k] }
    $script:DFSessionRoleWinners = $winners
    Write-DFRoleNotice -RoleWinners $winners -RoleDb $roleDb
    $skipSetup = @(Get-DFConfig SkipSetup)

    $prewarmModules = @(foreach ($t in $tools) {
        if ($t.type -eq 'module' -and $t.prewarm -and -not ($status.Contains($t.name) -and $status[$t.name].State -eq 'Active') -and
            (Test-DFToolAvailable -Executable $t.executable -Type 'module')) { $t.executable }
    })
    $prewarmJob = if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
    try {
        foreach ($t in $tools) {
            if ($status.Contains($t.name) -and $status[$t.name].State -eq 'Active' -and $t.name -notin $Reactivate) { continue }
            if ($blocked.ContainsKey($t.name)) {
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Missing -RequestedBy $by[$t.name] -Detail $blocked[$t.name]
                continue
            }
            # A required tool (not a role) was ordered first; if it then failed to
            # activate, neither can this one. (On a requires cycle, the tool not
            # yet reached has no status, so the cycle doesn't block itself.)
            $unmet = @(foreach ($req in @($t.requires)) {
                if ($req -and $req -notlike 'role:*' -and $status.Contains($req) -and $status[$req].State -ne 'Active') { $req }
            })
            if ($unmet) {
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Missing -RequestedBy $by[$t.name] -Detail "requires $($unmet -join ', '), which is not available"
                continue
            }
            if (-not (Test-DFToolAvailable -Executable $t.executable -Type $t.type)) {
                $detail = "'$($t.executable)' is not installed"
                if ($roleHint.ContainsKey($t.name)) { $detail += "; $(Get-DFRoleRequirementHint -Role $roleHint[$t.name] @pathArgs)" }
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Missing -RequestedBy $by[$t.name] -Detail $detail
                continue
            }
            # One tool's failure (a throwing companion, or any error under a
            # profile's $ErrorActionPreference = 'Stop') must not stop the rest.
            try {
                Invoke-DFToolRegistration -Tool $t -RoleWinners $winners -ToolsPath $toolsDir -SkipSetup $skipSetup -RoleDb $roleDb
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Active -RequestedBy $by[$t.name]
            } catch {
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Failed -RequestedBy $by[$t.name] -Detail $_.Exception.Message
            }
        }
    } finally {
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
    }

    foreach ($w in $winners.Values) {
        if ($status.Contains($w.Winner) -and $w.Role -notin $status[$w.Winner].Roles) {
            $status[$w.Winner].Roles = [string[]](@($status[$w.Winner].Roles) + $w.Role)
        }
        if ($w.Reason -eq 'fallback' -and $status.Contains($w.Preferred) -and $status[$w.Preferred].State -eq 'Missing') {
            $status[$w.Preferred].Detail = "$($status[$w.Preferred].Detail); using $($w.Winner) instead ($($w.Role))"
            $status[$w.Preferred] | Add-Member -NotePropertyName FallbackRole -NotePropertyValue $w.Role -Force
            $status[$w.Preferred] | Add-Member -NotePropertyName FallbackTool -NotePropertyValue $w.Winner -Force
        }
    }

    # Install hints are built later, when the status is read (Add-DFInstallHint).
    $script:DFSessionToolsPath = $ToolsPath

    foreach ($t in $tools) { if ($status[$t.name].State -eq 'Active') { $t } }
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
            node on PATH); the role is recorded in -RoleHint so that, if the
            tool turns out to be missing, its detail can name the role.
    .PARAMETER Records
        The requested records. Required tools are appended.
    .PARAMETER ToolDb
        Name -> record for the requested tools. Additions are added here too.
    .PARAMETER RequestedBy
        Name -> RequestedBy. Additions are recorded here.
    .PARAMETER Excluded
        Names excluded by ExcludeTools.
    .PARAMETER Edges
        Filled: tool name -> names it must come after (for Invoke-DFTopoSort -ExtraEdges).
    .PARAMETER Blocked
        Filled: tool name -> why it can't be activated.
    .PARAMETER RoleHint
        Filled: tool name -> the required roles none of whose members is requested.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Excluded = @(),
        [Parameter(Mandatory)][hashtable]$Edges,
        [Parameter(Mandatory)][hashtable]$Blocked,
        [Parameter(Mandatory)][hashtable]$RoleHint,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $add = {
        param($Record, [string]$By)
        $ToolDb[$Record.name] = $Record
        $RequestedBy[$Record.name] = $By
        $Records.Add($Record)
        $queue.Enqueue($Record)
    }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Records.ToArray()) { $queue.Enqueue($r) }

    while ($queue.Count) {
        $r = $queue.Dequeue()
        foreach ($req in @($r.requires)) {
            if (-not $req) { continue }
            if ($req -like 'role:*') {
                $role = $req.Substring(5)
                $members = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties[$role] })
                if (-not $members) { $RoleHint[$r.name] = @(@($RoleHint[$r.name]) + $role | Where-Object { $_ }) }
                foreach ($m in $members) {
                    if ($m.name -ne $r.name) { $Edges[$r.name] = @(@($Edges[$r.name]) + $m.name | Where-Object { $_ }) }
                }
                continue
            }
            if ($req -in $Excluded) {
                $Blocked[$r.name] = "requires $req, which is excluded"
                continue
            }
            if (-not $ToolDb.ContainsKey($req)) {
                $found = Import-DFToolDb -Name $req @pathArgs
                if (-not $found.Count) {
                    $Blocked[$r.name] = "requires $req, which has no tool record"
                    continue
                }
                & $add @($found.Values)[0] "requires ($($r.name))"
            }
            $Edges[$r.name] = @(@($Edges[$r.name]) + $req | Where-Object { $_ })
        }
    }
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
