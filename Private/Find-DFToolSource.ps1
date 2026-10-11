#Requires -Version 7.2

$script:DFManagerOpsLoaded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Import-DFManagerOps {
    <#
    .SYNOPSIS
        Loads a manager's Tools/<name>.manage.ps1 (its list and outdated functions), once per session.
    .DESCRIPTION
        A manager's companion runs only when the manager is an active tool,
        but npm may have installed tools without npm being in Tools, so its
        list and outdated functions live in a separate file loaded when a
        command needs them. Each function the file defines becomes a function
        of DotForge's own scope. No file: nothing happens.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER ToolsPath
        The Tools folder.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    $path = Join-Path $ToolsPath "$($Manager.name).manage.ps1"
    if (-not $script:DFManagerOpsLoaded.Add($path) -or -not (Test-Path -LiteralPath $path)) { return }
    # Dot-sourcing here would define the functions in this function's scope
    # only; define each one at script scope instead.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock()
    }
}

function Get-DFManagerInstalled {
    <#
    .SYNOPSIS
        What a manager has installed, from its list function: rows of Id, Installed and Available.
    .DESCRIPTION
        Calls the function named by the block's list with -Manager. A missing
        function, one that throws, and rows without a text Id all count as
        "nothing installed", never an error. With -Cache, each manager is asked
        once per command run.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER Block
        Its installs block for the source.
    .PARAMETER Operation
        list (what is installed) or outdated (what has an update).
    .PARAMETER Cache
        A hashtable kept for one command run.
    .OUTPUTS
        PSCustomObject[]: Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [Parameter(Mandatory)][pscustomobject]$Block,
        [ValidateSet('list', 'outdated')][string]$Operation = 'list',
        [hashtable]$Cache = @{}
    )
    $key = "$($Manager.name)|$($Block.from)|$Operation"
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $function = $Block.$Operation
    $rows = @(if ($function -and (Get-Command $function -ErrorAction Ignore)) {
        try {
            & $function -Manager $Manager | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Id']?.Value -is [string] -and $_.Id }
        } catch {
            Write-Verbose "DotForge: $($Manager.name) $Operation failed: $($_.Exception.Message)"
        }
    })
    $Cache[$key] = $rows
    $rows
}

function Find-DFToolSource {
    <#
    .SYNOPSIS
        Finds which manager a tool was installed through, by asking the managers of its own sources.
    .DESCRIPTION
        Asks only the managers of the sources in the tool's packages, in
        install precedence (Get-DFInstallSourceOrder: InstallVia, the tool's
        install.prefer, InstallOrder, DotForge's order), then any source that
        ExcludeSources left out, since a tool may have been installed through
        it before. Managers that aren't installed are skipped. The first
        manager whose list has the tool's id (or its feed-qualified id) wins,
        so a tool installed twice is reported under the first one found.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER Cache
        A hashtable kept for one command run, so each manager is asked once.
    .PARAMETER ToolsPath
        The Tools folder (for Tools/<manager>.manage.ps1).
    .OUTPUTS
        PSCustomObject: Tool, Source, Manager, Block, Id, Installed, Detail. Manager is $null when not found; Detail says why.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [hashtable]$Cache = @{},
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools')
    )
    $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties | Where-Object { Get-DFPackageRef $_.Value } | ForEach-Object { $_.Name } })
    $sources = @(@(Get-DFInstallSourceOrder -Tool $Tool -ToolDb $ToolDb 3>$null) + $have | Select-Object -Unique)
    $asked = [System.Collections.Generic.List[string]]::new()
    foreach ($source in $sources) {
        $ref = Get-DFPackageRef $Tool.packages.$source
        foreach ($manager in Get-DFSourceManager -Source $source -ToolDb $ToolDb) {
            if (-not (Test-DFToolAvailable -Executable $manager.executable -Type $manager.type)) { continue }
            $block = Get-DFInstallBlock -Manager $manager -Source $source
            if (-not $asked.Contains($manager.name)) { $asked.Add($manager.name) }
            Import-DFManagerOps -Manager $manager -ToolsPath $ToolsPath
            $ids = @($ref.Id) + @(if ($ref.Feed -and $block.feeds) { $block.feeds.id.Replace('{feed}', $ref.Feed.name).Replace('{id}', $ref.Id) })
            $row = Get-DFManagerInstalled -Manager $manager -Block $block -Cache $Cache | Where-Object { $_.Id -in $ids } | Select-Object -First 1
            if ($row) {
                return [pscustomobject]@{ Tool = $Tool.name; Source = $source; Manager = $manager; Block = $block; Id = $row.Id; Installed = $row.Installed; Detail = "via $($manager.name)" }
            }
        }
    }
    $detail = if ($asked.Count) { "not installed through any of: $($asked -join ', ')" } else { "no manager for $($sources -join ', ') is installed" }
    [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Id = $null; Installed = $null; Detail = $detail }
}
