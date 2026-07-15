#Requires -Version 7.0

function Get-DFCommandConflict {
    <#
    .SYNOPSIS
        Reports DotForge commands that another tool shadows before PowerShell can
        resolve them.

    .DESCRIPTION
        Coreutils for Windows installs a PSConsoleHostReadLine hook that rewrites
        command names to '<name>.cmd' before PowerShell resolves them. Any DotForge
        alias sharing a name with an enabled coreutils utility is therefore
        unreachable at the prompt — and because the rewrite happens above command
        resolution, Get-Command still reports DotForge's version, so the conflict is
        invisible to normal probing.

        This function compares the command names DotForge creates (its own helper
        aliases plus every alias and picker alias declared in the tool database)
        against the set the coreutils hook will rewrite, and returns one object per
        conflict along with the command that resolves it.

        The check is host-accurate: the coreutils hook is injected only into the
        ConsoleHost profile, so hosts that never load it (such as the VS Code
        integrated terminal) correctly report no conflicts. Nothing is spawned and
        no registry is read. When coreutils is not installed, or its hook is not
        loaded in this host, this returns nothing.

        Resolving a conflict requires elevation and is a policy choice, so DotForge
        never applies it: keep the coreutils utility, or disable it and let
        DotForge's version through. The Fix property carries the exact command.

    .PARAMETER ToolsPath
        Directory of tool JSON records to read alias names from. Defaults to the
        module's own Tools directory.

    .PARAMETER IncludeIgnored
        Also return conflicts listed in $Global:DFConfig.IgnoreConflicts, which are
        suppressed by default.

    .EXAMPLE
        Get-DFCommandConflict

        Lists every DotForge command currently shadowed by coreutils.

    .EXAMPLE
        (Get-DFCommandConflict).DisableWith | Sort-Object -Unique

        Produces the argument list for 'coreutils-manager disable'. Use DisableWith
        rather than Command: 'la' is not a coreutils utility and the manager rejects
        it, so it maps to 'ls'.

    .EXAMPLE
        $Global:DFConfig = @{ IgnoreConflicts = @('cat') }
        Get-DFCommandConflict

        Reports conflicts while accepting coreutils' cat over DotForge's bat alias.

    .OUTPUTS
        [PSCustomObject] with Command, ShadowedBy, WouldResolveTo, Ignored,
        DisableWith, and Fix properties. Returns nothing when no conflict exists.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ToolsPath,
        [switch]$IncludeIgnored
    )

    $shadowed = Get-DFCoreutilsShadowSet
    if (-not $shadowed) { return }

    # Names DotForge creates. Two sources, because they are created two different ways:
    #  1. Helper aliases (touch, env, paste, ...) — created at import by Public/*.ps1.
    #     They are Set-Alias -Scope Global, so the module never owns them and
    #     (Get-Module DotForge).ExportedAliases is empty; the manifest's
    #     AliasesToExport is the only maintained list of them.
    #  2. Tool aliases and picker aliases (cat, ls, ff, ...) — created by
    #     Register-DFTool from the tool database.
    $owned = [System.Collections.Generic.List[string]]::new()

    # Cached: this runs from Register-DFTool at profile load, and re-parsing the
    # manifest each call is the bulk of this function's cost.
    if ($null -eq $script:DFManifestAliases) {
        $script:DFManifestAliases = @()
        $manifest = Join-Path $PSScriptRoot '../DotForge.psd1'
        if (Test-Path $manifest) {
            $data = Import-PowerShellDataFile -Path $manifest -ErrorAction Ignore
            if ($data -and $data.AliasesToExport) {
                $script:DFManifestAliases = [string[]]@($data.AliasesToExport)
            }
        }
    }
    if ($script:DFManifestAliases) { $owned.AddRange([string[]]$script:DFManifestAliases) }

    $dbParams = @{}
    if ($ToolsPath) { $dbParams['ToolsPath'] = $ToolsPath }
    # Import-DFToolDb returns a hashtable keyed by tool name, not a list.
    $db = Import-DFToolDb @dbParams -ErrorAction Ignore
    foreach ($tool in @($db.Values)) {
        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $owned.AddRange([string[]]@($aliases.PSObject.Properties.Name))
        }
        $picker = $tool.PSObject.Properties['picker']?.Value
        if ($picker -is [PSCustomObject]) {
            $pAlias = $picker.PSObject.Properties['alias']?.Value
            if ($pAlias) { $owned.Add([string]$pAlias) }
        }
    }

    $ignored = @()
    if ($Global:DFConfig -and $Global:DFConfig['IgnoreConflicts']) {
        $ignored = [string[]]@($Global:DFConfig['IgnoreConflicts'])
    }

    foreach ($name in ($owned | Sort-Object -Unique)) {
        if ($shadowed -notcontains $name) { continue }

        $isIgnored = $ignored -contains $name
        if ($isIgnored -and -not $IncludeIgnored) { continue }

        # The alias/function still resolves — the hook intercepts above resolution —
        # so this reports what the user loses to the rewrite.
        $target = Get-Command -Name $name -ErrorAction Ignore |
            Where-Object { $_.CommandType -ne 'Application' } |
            Select-Object -First 1

        # coreutils-manager has no 'la' utility and rejects it: there is no la.cmd, and
        # the installer synthesizes 'la' into the hook only while 'ls' is enabled. So
        # 'ls' is what you disable, and doing so removes 'la' with it.
        $disableWith = if ($name -eq 'la') { 'ls' } else { $name }

        [PSCustomObject]@{
            Command        = $name
            ShadowedBy     = 'coreutils'
            WouldResolveTo = if ($target) { $target.Definition ?? $target.Name } else { $null }
            Ignored        = $isIgnored
            DisableWith    = $disableWith
            Fix            = "coreutils-manager disable $disableWith   (run elevated)"
        }
    }
}
