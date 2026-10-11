#Requires -Version 7.2

function Get-DFManagerPackage {
    <#
    .SYNOPSIS
        The package ids a package manager still has installed; nothing for a tool that isn't a manager.
    .PARAMETER Manager
        A tool record.
    .PARAMETER ToolsPath
        The Tools folder (for Tools/<manager>.manage.ps1).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([pscustomobject]$Manager, [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    if (-not $Manager -or -not $Manager.installs) { return }
    Import-DFManagerOps -Manager $Manager -ToolsPath $ToolsPath
    foreach ($block in $Manager.installs) { Get-DFManagerInstalled -Manager $Manager -Block $block | ForEach-Object { $_.Id } }
}

function Set-DFRemovedToolStatus {
    <#
    .SYNOPSIS
        Marks a removed tool Missing in this session's status ("removed by Remove-DFTool").
    .PARAMETER Name
        The tool.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:DFSessionStatus) { return }
    $requestedBy = if ($script:DFSessionStatus.Contains($Name)) { $script:DFSessionStatus[$Name].RequestedBy }
    $script:DFSessionStatus[$Name] = New-DFToolStatus -Name $Name -State Missing -RequestedBy $requestedBy -Detail 'removed by Remove-DFTool'
}

function Write-DFRemoveLeftover {
    <#
    .SYNOPSIS
        Lists what a removed tool left behind: seeded config files, recorded setup changes, and its Tools entry.
    .DESCRIPTION
        DotForge removes only the package. Seeded files are listed when they
        still exist; setup changes are listed as the tool's setup recorded
        them (core doesn't know how to undo them). The setup record itself is
        kept, so a reinstall doesn't run setup again.
    .PARAMETER Tool
        The removed tool's record.
    .OUTPUTS
        None. Writes to the host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Tool.setup.seed) {
        foreach ($seed in $Tool.setup.seed.PSObject.Properties) {
            $path = ConvertTo-DFPath (Expand-DFXdgPath $seed.Name)
            if (Test-Path -LiteralPath $path) { $lines.Add("config file DotForge seeded: $path") }
        }
    }
    $record = (Get-DFToolSetupState).PSObject.Properties[$Tool.name]?.Value
    foreach ($action in @(${record}?.actions | Where-Object { $_ })) {
        $lines.Add("change its setup made: $(@($action.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ')")
    }
    if ($Tool.name -in @(Get-DFConfig Tools)) { $lines.Add("remove '$($Tool.name)' from Tools in your profile") }
    elseif ($script:DFSessionStatus -and $script:DFSessionStatus.Contains($Tool.name)) { $lines.Add("add '$($Tool.name)' to ExcludeTools in your profile (a group requests it)") }
    Write-Host "DotForge removed $($Tool.name). Left behind:"
    foreach ($line in $lines) { Write-Host "  $line" }
    Write-Host '  its aliases and functions stay until you open a new shell'
}
