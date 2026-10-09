#Requires -Version 7.0

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
        recreated on the next load either.
    .PARAMETER Tool
        The tool record. A record without setup.seed seeds nothing.
    .PARAMETER ToolsPath
        The Tools/ folder the seed sources are relative to.
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
    foreach ($s in $seed.PSObject.Properties) {
        $dest = ConvertTo-DFPath (Expand-DFXdgPath $s.Name)
        $src = Join-Path $ToolsPath $s.Value
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "seed source '$($s.Value)' not found under $ToolsPath"
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
