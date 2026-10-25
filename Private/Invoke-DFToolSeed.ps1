#Requires -Version 7.2

function Invoke-DFToolSeed {
    <#
    .SYNOPSIS
        Copies a tool's setup.seed files into place, skipping any destination that already exists.
    .DESCRIPTION
        setup.seed maps a destination path template (${XDG_*} expanded by
        Expand-DFXdgPath) to a file bundled under Tools/. Each file is copied
        only when its destination doesn't exist, so a user's edits are never
        overwritten. This is part of the one-time setup step
        (Invoke-DFToolCompanion), so a file the user deletes on purpose isn't
        recreated on the next load either. A source may contain {theme}: the
        tool's theme value this session (with theme.files, the theme's own file
        or folder, an absolute path).
    .PARAMETER Tool
        The tool record. A record without setup.seed seeds nothing.
    .PARAMETER ToolsPath
        The folder the seed sources are relative to, for a record with no folder
        of its own; a loaded record's seeds are next to its JSON.
    .OUTPUTS
        System.Collections.Hashtable. One setup action per seed: type
        'seedConfig', path, and created ($false when an existing file was kept).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][string]$ToolsPath
    )
    $seed = $Tool.PSObject.Properties['setup']?.Value?.seed
    if (-not $seed) { return }
    $ToolsPath = Get-DFToolFolder -Tool $Tool -Default $ToolsPath
    foreach ($s in $seed.PSObject.Properties) {
        $dest = ConvertTo-DFPath (Expand-DFXdgPath $s.Name)
        # A linked location is the user's existing data: never seed into it.
        if (Test-DFInLinkedPath -Name $Tool.name -Path $dest) { continue }
        $source = [string]$s.Value
        if ($source.Contains('{theme}')) {
            # With theme.files the value is the theme's own file or folder (an absolute path).
            $theme = if ($Tool.theme) { (Get-DFToolTheme -Tool $Tool).Value }
            if (-not $theme) { throw "seed source '$source' needs a theme, and $($Tool.name) has none this session" }
            $source = $source.Replace('{theme}', [string]$theme)
        }
        $src = if ([System.IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $ToolsPath $source }
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "seed source '$source' not found under $ToolsPath"
        }
        $created = -not (Test-Path -LiteralPath $dest)
        if ($created) {
            New-DFDirectory (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dest
            Write-Verbose "DotForge: seeded $($Tool.name) config at $dest"
        }
        @{ type = 'seedConfig'; path = $dest; created = $created }
    }
}

# The seed actions of a tool's running one-time setup, recorded with it by
# Complete-DFToolSetup, so a setup script doesn't have to pass them on.
$script:DFPendingSeedActions = @{}

function Set-DFPendingSeedAction {
    <#
    .SYNOPSIS
        Keeps a running setup's seed actions until Complete-DFToolSetup records them.
    .PARAMETER Name
        The tool name.
    .PARAMETER Actions
        The actions Invoke-DFToolSeed returned.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Actions = @())
    $script:DFPendingSeedActions[$Name] = @($Actions)
}

function Get-DFPendingSeedAction {
    <#
    .SYNOPSIS
        Returns a running setup's seed actions.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.Object[].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFPendingSeedActions.ContainsKey($Name)) { @($script:DFPendingSeedActions[$Name]) }
}

function Clear-DFPendingSeedAction {
    <#
    .SYNOPSIS
        Forgets a setup's seed actions: recorded, or the setup failed.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $script:DFPendingSeedActions.Remove($Name)
}

function Get-DFSeededPath {
    <#
    .SYNOPSIS
        The files a tool's recorded setup created by seeding (not ones it found and kept).
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    $entry = (Get-DFToolSetupState).PSObject.Properties[$Name]?.Value
    if (-not $entry) { return }
    [string[]]@(foreach ($action in @($entry.actions)) {
        if (-not $action) { continue }
        $type = if ($action -is [System.Collections.IDictionary]) { $action['type'] } else { $action.PSObject.Properties['type']?.Value }
        $created = if ($action -is [System.Collections.IDictionary]) { $action['created'] } else { $action.PSObject.Properties['created']?.Value }
        $path = if ($action -is [System.Collections.IDictionary]) { $action['path'] } else { $action.PSObject.Properties['path']?.Value }
        if ($type -eq 'seedConfig' -and $created -and $path) { [string]$path }
    })
}
