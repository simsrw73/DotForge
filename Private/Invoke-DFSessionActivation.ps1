#Requires -Version 7.0

# What the current session decided, per requested tool: name -> DotForge.ToolStatus.
# $null until Start-DFSession (or Register-DFTool) first runs. Get-DFToolStatus reads it.
$script:DFSessionStatus = $null
# The session's requested tool records and role winners, for Get-DFRole.
$script:DFSessionToolDb = @{}
$script:DFSessionRoleWinners = $null

function Invoke-DFSessionActivation {
    <#
    .SYNOPSIS
        Checks, sets up and activates a set of requested tools, recording each one's status for the session.
    .DESCRIPTION
        The shared core of Start-DFSession and Register-DFTool -Name. For the
        given request entries (Resolve-DFRequestedTools output):
          - reads only those tool records (Import-DFToolDb -Name);
          - orders them by dependsOn;
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

    $records = @(foreach ($e in $wanted) {
        if ($db.ContainsKey($e.Name)) { $db[$e.Name] }
        else { $status[$e.Name] = New-DFToolStatus -Name $e.Name -State Failed -RequestedBy $e.RequestedBy -Detail 'its tool record is missing or invalid (see the warning above)' }
    })
    $tools = @(Invoke-DFTopoSort -Tools $records | Where-Object { $_ })
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
            if (-not (Test-DFToolAvailable -Executable $t.executable -Type $t.type)) {
                $status[$t.name] = New-DFToolStatus -Name $t.name -State Missing -RequestedBy $by[$t.name] -Detail "'$($t.executable)' is not installed"
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
