#Requires -Version 7.2

function Remove-DFTool {
    <#
    .SYNOPSIS
        Removes tools through the package manager each one came from, then lists what DotForge left behind.
    .DESCRIPTION
        Each tool's manager is found by asking the managers of its own sources
        (as Update-DFTool does). Only the package is removed.

        Dependents: a tool that another active tool requires (directly, or as
        the only active member of a required role) is refused, naming the
        dependents, unless they are named too: then they are removed first. -Force removes it anyway. -IncludeDependents follows the
        requires chains and removes the dependents too, dependents first,
        after one confirmation for the whole list.

        A package manager that still has packages installed is always refused
        unless you pass -Force, and the packages it installed are never removed
        with it. So is a version manager (fnm, mise), which can't list what it
        installed.

        Afterwards it lists what is left: config files DotForge seeded, the
        changes a tool's one-time setup recorded, and the tool's entry in your
        Tools setting (DotForge never edits your profile). The setup record is
        kept, so a reinstall doesn't run setup again. The tool shows as Missing
        in Get-DFToolStatus; its aliases and functions stay until you open a
        new shell.
    .PARAMETER Name
        Tools to remove.
    .PARAMETER Force
        Remove a tool other tools require, or a manager that still has packages.
    .PARAMETER IncludeDependents
        Also remove the active tools that require these, dependents first.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Remove-DFTool -Name glow

        Asks once, removes glow through the manager that installed it, and lists its leftovers.
    .EXAMPLE
        Remove-DFTool -Name fzf -IncludeDependents -WhatIf

        Shows that PSFzf would be removed first, then fzf, without removing anything.
    .OUTPUTS
        PSCustomObject per tool: Tool, Result (Removed, Refused, NotInstalled, Failed, Skipped), Detail.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [switch]$Force,
        [switch]$IncludeDependents,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @pathArgs
    $active = @(Get-DFToolStatus 3>$null | Where-Object State -eq 'Active' | ForEach-Object { $_.Name })
    $refuse = { param($tool, $detail) [pscustomobject]@{ Tool = $tool; Result = 'Refused'; Detail = $detail } }

    # The removal order: each name after its dependents (with -IncludeDependents).
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($toolName in $Name) {
        if (-not $db[$toolName]) { Write-Warning "DotForge: unknown tool '$toolName'."; continue }
        # Dependents named in this call are removed with it, first.
        $dependents = @(Get-DFToolDependent -Name $toolName -ToolDb $db -Active $active -Transitive)
        $unnamed = @($dependents | Where-Object { $_ -notin $Name })
        if ($unnamed -and -not $Force -and -not $IncludeDependents) {
            & $refuse $toolName "required by $($unnamed -join ', '): use -IncludeDependents to remove them too, or -Force"
            continue
        }
        $chain = @(if ($IncludeDependents) { $dependents } else { $dependents | Where-Object { $_ -in $Name } }) + $toolName
        $busy = @(foreach ($member in $chain) { Get-DFManagerPackage -Manager $db[$member] @pathArgs | ForEach-Object { [pscustomobject]@{ Manager = $member; Id = $_ } } })
        if ($busy -and -not $Force) {
            $first = $busy[0].Manager
            $ids = @($busy | Where-Object Manager -eq $first | ForEach-Object Id)
            $detail = if ('?' -in $ids) { "can't tell what $first has installed (use -Force to remove it anyway)" }
                else { "$first still has packages installed: $($ids -join ', ') (use -Force to remove it anyway)" }
            & $refuse $toolName $detail
            continue
        }
        foreach ($member in $chain) { if (-not $order.Contains($member)) { $order.Add($member) } }
    }
    if (-not $order.Count -or -not $PSCmdlet.ShouldProcess($order -join ', ', 'Remove (in this order)')) { return }

    $cache = @{}
    foreach ($toolName in $order) {
        $found = Find-DFToolSource -Tool $db[$toolName] -ToolDb $db -Cache $cache @pathArgs
        if (-not $found.Manager) {
            [pscustomobject]@{ Tool = $toolName; Result = 'NotInstalled'; Detail = $found.Detail }
            continue
        }
        $outcome = @(Invoke-DFManagerOperation -Operation remove -Found $found -Tool $db[$toolName] -Ids @($found.Id) -ToolDb $db)[0]
        $result = ConvertTo-DFManagerResult -Tool $toolName -Outcome $outcome -Manager $found.Manager.name -Success 'Removed'
        if ($result.Result -eq 'Removed') {
            Set-DFRemovedToolStatus -Name $toolName
            Remove-DFToolLinkSet -Name $toolName
            # Like its links, its desktop variables never stop a removal that already happened.
            try {
                $desktopState = Read-DFDesktopEnvState
                if ($null -ne $desktopState) { $null = Remove-DFDesktopEnvSet -Tool $toolName -State $desktopState }
                else { Write-Warning "DotForge: $(Get-DFDesktopEnvStatePath) can't be read, so $toolName's desktop variables weren't removed. Fix or delete it, then run Remove-DFDesktopEnv $toolName." }
            } catch { Write-Warning "DotForge: couldn't remove $toolName's desktop variables ($($_.Exception.Message)); see Remove-DFDesktopEnv." }
            Write-DFRemoveLeftover -Tool $db[$toolName]
        }
        $result
    }
}
