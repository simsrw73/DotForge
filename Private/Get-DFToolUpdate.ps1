#Requires -Version 7.2

function New-DFToolUpdate {
    <#
    .SYNOPSIS
        Creates one DotForge.ToolUpdate row, shown as Tool, Manager, Installed, Update.
    .PARAMETER Tool
        Tool name.
    .PARAMETER Found
        Find-DFToolSource's result.
    .PARAMETER State
        Outdated, UpToDate, Unknown, NotFound or Runtime.
    .PARAMETER Available
        The newer version, for Outdated.
    .PARAMETER Update
        What the Update column says.
    .OUTPUTS
        DotForge.ToolUpdate.
    #>
    [CmdletBinding()]
    param([string]$Tool, [pscustomobject]$Found, [string]$State, [string]$Available, [string]$Update)
    $row = [pscustomobject]@{
        PSTypeName = 'DotForge.ToolUpdate'
        Tool       = $Tool
        Manager    = $Found.Manager.name
        Installed  = $Found.Installed
        Available  = $Available
        State      = $State
        Update     = $Update
        Found      = $Found
    }
    # Four default columns, so it shows as a table.
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Tool', 'Manager', 'Installed', 'Update'))
    $row.PSObject.Members.Add([System.Management.Automation.PSMemberSet]::new('PSStandardMembers', [System.Management.Automation.PSMemberInfo[]]@($display)))
    $row
}

function Get-DFToolUpdate {
    <#
    .SYNOPSIS
        For each tool: the manager it came from, its installed version, and whether an update is available.
    .DESCRIPTION
        Finds each tool's manager (Find-DFToolSource), then asks that
        manager's outdated function once per command run. State is Outdated
        (with Available), UpToDate, Unknown (the manager can't say what is
        outdated), NotFound, or Runtime (its manager declares no update: a
        version manager such as fnm owns it).
    .PARAMETER Name
        Tool names.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER ToolsPath
        The Tools folder (for Tools/<manager>.manage.ps1).
    .OUTPUTS
        DotForge.ToolUpdate.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools')
    )
    $cache = @{}
    foreach ($toolName in $Name) {
        $tool = $ToolDb[$toolName]
        if (-not $tool) { Write-Warning "DotForge: unknown tool '$toolName'."; continue }
        $found = Find-DFToolSource -Tool $tool -ToolDb $ToolDb -Cache $cache -ToolsPath $ToolsPath
        if (-not $found.Manager) { New-DFToolUpdate -Tool $toolName -Found $found -State NotFound -Update $found.Detail; continue }
        $manager = $found.Manager.name
        if (-not $found.Block.update) {
            New-DFToolUpdate -Tool $toolName -Found $found -State Runtime -Update "managed by $($manager): update it with $manager"
            continue
        }
        if (-not $found.Block.outdated) { New-DFToolUpdate -Tool $toolName -Found $found -State Unknown -Update 'unknown'; continue }
        $row = Get-DFManagerInstalled -Manager $found.Manager -Block $found.Block -Operation outdated -Cache $cache |
            Where-Object { $_.Id -eq $found.Id } | Select-Object -First 1
        if ($row) { New-DFToolUpdate -Tool $toolName -Found $found -State Outdated -Available $row.Available -Update $row.Available }
        else { New-DFToolUpdate -Tool $toolName -Found $found -State UpToDate -Update 'up to date' }
    }
}
