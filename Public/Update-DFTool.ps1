#Requires -Version 7.2

function Update-DFTool {
    <#
    .SYNOPSIS
        Shows which of your tools have updates, and updates them through the manager each came from.
    .DESCRIPTION
        Each tool's manager is found by asking the managers of its own sources;
        a tool installed through two managers is reported under the first one
        found, in install precedence (InstallVia, the tool's install.prefer,
        InstallOrder, DotForge's order).

        With no -Name or -All, shows a table for the session's active tools
        (Tool, Manager, Installed, Update: the newer version, "up to date",
        "unknown" when the manager can't say, or why the tool can't be
        updated) and changes nothing.

        -All updates every active tool that has an update, plus the unknowns
        (the manager does nothing for one that is current). -Name does the same
        for the named tools. Tools are updated in one call per manager where
        the manager allows it. A manager that needs administrator rights gets
        them the way Install-DFTool does.

        Runtimes that a version manager owns (node through fnm or mise, Python
        through uv or pymanager) aren't updated here: the table names the
        manager to use.
    .PARAMETER Name
        Tools to update.
    .PARAMETER All
        Update every active tool that has an update.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Update-DFTool

        Shows the update table for the session's tools.
    .EXAMPLE
        Update-DFTool -All -WhatIf

        Shows which managers would update which tools, without running them.
    .EXAMPLE
        Update-DFTool -Name fzf, bat

        Updates fzf and bat.
    .OUTPUTS
        DotForge.ToolUpdate (bare), or PSCustomObject per tool: Tool, Result (Updated, Failed, Skipped), Detail.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Show')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Name', Position = 0)][string[]]$Name,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @pathArgs
    $targets = if ($Name) { $Name } else { @(Get-DFToolStatus 3>$null | Where-Object State -eq 'Active' | ForEach-Object { $_.Name }) }
    if (-not $targets) { Write-Host 'DotForge: no active tools. Start-DFSession configures the tools you request.'; return }
    $rows = @(Get-DFToolUpdate -Name $targets -ToolDb $db @pathArgs)
    if ($PSCmdlet.ParameterSetName -eq 'Show') { return $rows }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows | Where-Object State -notin 'Outdated', 'Unknown') {
        $results.Add([pscustomobject]@{ Tool = $row.Tool; Result = 'Skipped'; Detail = $row.Update })
    }
    $toUpdate = @($rows | Where-Object State -in 'Outdated', 'Unknown')
    if (-not $toUpdate) { Write-Host 'Everything is up to date.'; return $results.ToArray() }

    foreach ($group in $toUpdate | Group-Object { "$($_.Found.Manager.name)|$($_.Found.Source)" }) {
        $found = $group.Group[0].Found
        $tools = @($group.Group.Tool)
        if (-not $PSCmdlet.ShouldProcess("$($tools -join ', ') through $($found.Manager.name)", 'Update')) { continue }
        $outcomes = @(Invoke-DFManagerOperation -Operation update -Found $found -Ids ([string[]]@($group.Group.Found.Id)) -ToolDb $db)
        $outcomes = @(Resolve-DFPartialUpdate -Found $found -Rows @($group.Group) -Outcomes $outcomes)
        for ($n = 0; $n -lt $tools.Count; $n++) {
            $results.Add((ConvertTo-DFManagerResult -Tool $tools[$n] -Outcome $outcomes[$n] -Manager $found.Manager.name -Success 'Updated'))
        }
        if ($found.Block.reactivate -and @($outcomes | Where-Object ExitCode -eq 0).Count) { Register-DFTool -Name $found.Manager.name @pathArgs 3>$null }
    }
    $results.ToArray()
}
