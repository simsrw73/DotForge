# DotForge startup core, bundled by build/Build-DFCoreBundle.ps1. Do not edit: edit the sources.
# sources-sha256: 29a7485aa5dee9466325a99c6bec917dd59d9c3302cf78c41586f758f04bb50a

# ---- Shared/ConvertTo-DFPath.ps1
#Requires -Version 7.2

function ConvertTo-DFPath {
    <#
    .SYNOPSIS
        Canonicalizes an absolute path: native separators, no ./.., no trailing
        separator, with a leading ~ expanded to $HOME.
    .DESCRIPTION
        The single path-normalization primitive for DotForge. Returns
        [System.IO.Path]::GetFullPath's canonical form with a root-aware
        trailing-separator strip. Null/empty pass through untouched. A relative
        path is a probable bug: it is returned unchanged with a warning, never
        silently bound to the current directory. Works on paths that do not exist
        yet (no filesystem access, except that an existing 8.3 short-name segment
        is expanded to its long form).
    .PARAMETER Path
        The path to canonicalize.
    .OUTPUTS
        [string] the canonical path, or the input unchanged for null/empty/relative.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    # Expand a leading ~ (whole path, or immediately followed by a separator) to
    # $HOME. Never a ~ elsewhere — that would corrupt Windows 8.3 short names
    # (C:\PROGRA~1) or a literal filename.
    if ($Path -eq '~' -or $Path -match '^~[\\/]') {
        $Path = $HOME + $Path.Substring(1)
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Write-Warning "ConvertTo-DFPath: '$Path' is not an absolute path — returned unchanged."
        return $Path
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                              [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $full
}

function Get-DFXdgPath {
    <#
    .SYNOPSIS
        Returns one XDG base folder: the environment variable if set, otherwise the XDG default under $HOME.
    .DESCRIPTION
        The single place DotForge decides where its config, data, state, cache
        and bin folders are, so "the variable isn't set" is never a special case
        anywhere else. Defaults follow the XDG Base Directory spec:

            Config  $HOME\.config         Data   $HOME\.local\share
            State   $HOME\.local\state    Cache  $HOME\.cache
            Bin     $HOME\.local\bin      (XDG_BIN_HOME is not in the spec; the location is)

        The result is canonical (ConvertTo-DFPath). Reading never sets the
        variable; Start-DFSession exports them for other programs.
    .PARAMETER Kind
        Config, Data, State, Cache or Bin.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Config', 'Data', 'State', 'Cache', 'Bin')]
        [string]$Kind
    )
    $value = [Environment]::GetEnvironmentVariable("XDG_$($Kind.ToUpperInvariant())_HOME")
    if (-not $value) {
        $value = switch ($Kind) {
            'Config' { Join-Path $HOME '.config' }
            'Data'   { Join-Path $HOME '.local' 'share' }
            'State'  { Join-Path $HOME '.local' 'state' }
            'Cache'  { Join-Path $HOME '.cache' }
            'Bin'    { Join-Path $HOME '.local' 'bin' }
        }
    }
    ConvertTo-DFPath $value
}

# ---- Shared/DFFontName.ps1
#Requires -Version 7.2

# Names in the Windows Fonts registry keys: "<Face> <Style> (TrueType)", or, for a
# font registered by its file, "<FaceNoSpaces>-<Style> (TrueType)". Shared because the
# core detects Nerd Fonts and Install-DFNerdFont (DotForge.Helpers) registers them.

function Test-DFNerdFontName {
    <#
    .SYNOPSIS
        True when a Fonts registry value name is a Nerd Font's.
    .DESCRIPTION
        Matches, ignoring case and spaces, "NerdFont" anywhere, or NF, NFM or NFP as
        a word of its own (the short family names Nerd Fonts uses, e.g.
        "CaskaydiaCove NF Bold"), before the "(TrueType)"/"(OpenType)" suffix.
    .PARAMETER Name
        The registry value name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $bare = $Name -replace '\s*\((TrueType|OpenType)\)\s*$', ''
    if (($bare -replace '\s', '') -match 'NerdFont') { return $true }
    $bare -match '(^|[\s-])NF[MP]?(\s|-|$)'
}

function ConvertTo-DFFontFaceName {
    <#
    .SYNOPSIS
        The family name a terminal lists for a Fonts registry value name or font file name.
    .DESCRIPTION
        Drops the "(TrueType)" suffix, a file extension and the style ("Regular",
        "BoldItalic", ...), and spaces a compact Nerd Font name: "HackNerdFontMono-Bold"
        becomes "Hack Nerd Font Mono".
    .PARAMETER Name
        A registry value name or a font file name.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $face = $Name -replace '\s*\((TrueType|OpenType)\)\s*$', '' -replace '\.(ttf|otf)$', ''
    # A file-style name: the style follows the last '-'.
    if ($face -notmatch '\s' -and $face -match '^(.+)-[^-]+$') { $face = $Matches[1] }
    $face = $face -creplace '(?<=\S)NerdFont(?=Mono|Propo|$)', ' Nerd Font' -creplace 'Nerd Font(Mono|Propo)$', 'Nerd Font $1'
    $styles = 'Regular|Bold|Italic|BoldItalic|Light|LightItalic|Medium|MediumItalic|SemiBold|SemiBoldItalic|ExtraLight|ExtraLightItalic|ExtraBold|ExtraBoldItalic|Thin|ThinItalic|Black|BlackItalic|SemiLight|SemiLightItalic|Retina|Book|Oblique'
    ($face -replace "(\s+($styles))+$", '').Trim()
}

# ---- Shared/DFInstallSource.ps1
#Requires -Version 7.2

function Get-DFSourceManager {
    <#
    .SYNOPSIS
        Returns the managers that install from one source, best first.
    .DESCRIPTION
        A manager is any tool record whose installs.from names the source.
        A system manager (scoop) is its own only manager; a registry (npm)
        can have several (npm, pnpm, bun). Order: a manager the user named in
        Defaults (for any role), then the highest priority among its roles,
        then name.
    .PARAMETER Source
        The source name, e.g. 'scoop' or 'npm'.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        PSCustomObject[]. Manager records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][hashtable]$ToolDb)
    $chosen = @((Get-DFConfig Defaults -Default @{}).Values)
    $topPriority = { param($m) (@($m.roles.PSObject.Properties.Value | ForEach-Object { $_.priority }) + 0 | Measure-Object -Maximum).Maximum }
    @($ToolDb.Values | Where-Object { $_.installs -and @($_.installs | Where-Object { $_.from -eq $Source }).Count } |
        Sort-Object @{ Expression = { $_.name -in $chosen }; Descending = $true },
                    @{ Expression = { & $topPriority $_ }; Descending = $true },
                    name)
}

function Get-DFBuiltInSourceOrder {
    <#
    .SYNOPSIS
        DotForge's fallback source order: system managers by package-manager priority, then every other source by name.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$ToolDb)
    $managers = @($ToolDb.Values | Where-Object installs)
    $system = @(Get-DFRoleMember -Role 'package-manager' -Tools $managers |
        Sort-Object @{ Expression = { $_.roles.'package-manager'.priority }; Descending = $true }, name |
        ForEach-Object { $_.installs[0].from })
    $other = @($managers | ForEach-Object { $_.installs | ForEach-Object { $_.from } } | Where-Object { $_ -notin $system } | Sort-Object -Unique)
    [string[]]@($system + $other | Select-Object -Unique)
}

function Test-DFSourceAllowed {
    <#
    .SYNOPSIS
        Whether the user's IncludeSources and ExcludeSources allow a source (before any per-tool InstallVia).
    .PARAMETER Source
        The source name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Source)
    $included = @(Get-DFConfig IncludeSources | Where-Object { $_ })
    ($Source -notin @(Get-DFConfig ExcludeSources)) -and (-not $included -or $Source -in $included)
}

function Get-DFToolInstallPreference {
    <#
    .SYNOPSIS
        Reads a tool record's install.prefer and install.avoid, StrictMode-safe even for a hand-built record without them.
    .PARAMETER Tool
        The tool record.
    .OUTPUTS
        PSCustomObject: Prefer (string[]), Avoid (hashtable source -> reason).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $install = $Tool.PSObject.Properties['install']?.Value
    $prefer = if ($install) { $install.PSObject.Properties['prefer']?.Value }
    $avoidObject = if ($install) { $install.PSObject.Properties['avoid']?.Value }
    $avoid = @{}
    if ($avoidObject) { foreach ($entry in $avoidObject.PSObject.Properties) { $avoid[$entry.Name] = $entry.Value } }
    [pscustomobject]@{ Prefer = [string[]]@($prefer | Where-Object { $_ }); Avoid = $avoid }
}

function Get-DFInstallSourceOrder {
    <#
    .SYNOPSIS
        Orders one tool's candidate sources: -Via, InstallVia, the tool's install.prefer, InstallOrder, then DotForge's order.
    .DESCRIPTION
        Only sources the tool has a package for are returned. When
        IncludeSources is set, only the sources it lists are used, registries
        included; ExcludeSources removes the sources it lists. -Via or
        InstallVia naming a source for this tool beats both. An InstallVia
        source the tool has no package for warns and is ignored, so it never
        loosens either list. An IncludeSources entry DotForge doesn't know
        warns. Sources the record avoids (install.avoid) go last, unless -Via
        or InstallVia names them.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via); beats the InstallVia setting.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][hashtable]$ToolDb, [hashtable]$Via = @{})
    $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties | Where-Object { Get-DFPackageRef $_.Value } | ForEach-Object { $_.Name } })
    # (A local named $via would be the $Via parameter: names are case-insensitive.)
    $pinned = $Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]
    if ($pinned -and $pinned -notin $have) {
        Write-DFInstallWarning "DotForge: InstallVia for $($Tool.name) names '$pinned', which has no package for it; ignoring that."
        $pinned = $null
    }
    $known = Get-DFBuiltInSourceOrder -ToolDb $ToolDb
    foreach ($unknown in @(Get-DFConfig IncludeSources) | Where-Object { $_ -and $_ -notin $known }) {
        Write-DFInstallWarning "DotForge: IncludeSources lists '$unknown', which no package manager installs from; ignoring that entry."
    }
    $preference = Get-DFToolInstallPreference -Tool $Tool
    $ordered = @(@($pinned) + $preference.Prefer + @(Get-DFConfig InstallOrder) + $known + $have |
        Where-Object { $_ -and $_ -in $have } | Select-Object -Unique)
    $ordered = @($ordered | Where-Object { $_ -eq $pinned -or (Test-DFSourceAllowed -Source $_) })
    # Sources the record avoids go last, unless the user named one for this tool.
    $avoided = @($preference.Avoid.Keys)
    [string[]]@(@($ordered | Where-Object { $_ -eq $pinned -or $_ -notin $avoided }) + @($ordered | Where-Object { $_ -ne $pinned -and $_ -in $avoided }))
}

function Resolve-DFInstallSource {
    <#
    .SYNOPSIS
        Picks the source and manager that will install one tool, or says why none can.
    .DESCRIPTION
        Walks Get-DFInstallSourceOrder. For each source, the manager is the
        user's -Choice for that source if given, else the first of
        Get-DFSourceManager that is available or -Planned (an earlier stage
        installs it). The first source with a manager wins. Otherwise Gap
        explains why, and Options lists the managers that could serve the
        first source, for the interactive question.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that manager is installed now.
    .PARAMETER Planned
        Manager names an earlier stage installs.
    .PARAMETER Choice
        Source -> manager name the user picked for it.
    .PARAMETER Via
        Tool -> source for this call; passed to Get-DFInstallSourceOrder.
    .PARAMETER CanElevate
        Whether a manager that needs admin rights (installs.elevate) can run:
        the shell is elevated, or an elevator is installed or planned. When
        not, such a manager is passed over like an unavailable one.
    .OUTPUTS
        PSCustomObject: Tool, Source, Manager, Block (the manager's installs
        block for Source), Ref, Gap, Options, Sources (the candidate order it
        walked), and AvoidReason (why the record avoids Source, when it does).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [AllowEmptyCollection()][string[]]$Planned = @(),
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{},
        [bool]$CanElevate = $true
    )
    $sources = @(Get-DFInstallSourceOrder -Tool $Tool -ToolDb $ToolDb -Via $Via)
    $result = [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Ref = $null; Gap = $null; Options = @(); Sources = [string[]]$sources; AvoidReason = $null }
    if (-not $sources) {
        $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties.Name })
        if (-not $have) { $result.Gap = 'no package in any source'; return $result }
        $one = $have.Count -eq 1
        $them = if ($one) { 'it' } else { 'them' }
        $included = @(Get-DFConfig IncludeSources | Where-Object { $_ })
        $byInclude = $included -and @($have | Where-Object { $_ -notin $included }).Count
        $byExclude = @($have | Where-Object { $_ -in @(Get-DFConfig ExcludeSources) }).Count
        $why = if ($byInclude -and $byExclude) { "IncludeSources and ExcludeSources rule $them out" }
               elseif ($byInclude) { "IncludeSources doesn't list $them" }
               else { "ExcludeSources removes $them" }
        $result.Gap = "no source left (only $($have -join ', ') $(if ($one) { 'has' } else { 'have' }) it, and $why)"
        return $result
    }
    foreach ($s in $sources) {
        $managers = @(Get-DFSourceManager -Source $s -ToolDb $ToolDb | Where-Object { $CanElevate -or -not (Get-DFInstallBlock -Manager $_ -Source $s).elevate })
        $pick = if ($Choice[$s]) { $managers | Where-Object name -eq $Choice[$s] | Select-Object -First 1 }
                else { $managers | Where-Object { $_.name -in $Planned -or (& $IsAvailable $_) } | Select-Object -First 1 }
        if ($pick) {
            $pinned = $Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]
            if ($pinned -and $pinned -ne $s -and $pinned -in $sources) {
                Write-DFInstallWarning "DotForge: InstallVia for $($Tool.name) names '$pinned', whose manager is not installed or requested; installing from $s instead."
            }
            $result.Source = $s
            $result.Manager = $pick
            $result.Block = Get-DFInstallBlock -Manager $pick -Source $s
            $result.Ref = Get-DFPackageRef $Tool.packages.$s
            $result.AvoidReason = (Get-DFToolInstallPreference -Tool $Tool).Avoid[$s]
            return $result
        }
    }
    $first = $sources[0]
    $result.Options = [string[]]@(Get-DFSourceManager -Source $first -ToolDb $ToolDb | ForEach-Object { $_.name })
    $result.Gap = "needs a manager for $first ($(if ($result.Options) { $result.Options -join ', ' } else { 'none known' })), and none is installed or requested"
    $result
}

function Write-DFInstallWarning {
    <#
    .SYNOPSIS
        Writes a planning warning once per Install-DFTool call (its question loop re-plans after every answer).
    .PARAMETER Message
        The warning.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    if ($script:DFInstallWarned -and -not $script:DFInstallWarned.Add($Message)) { return }
    Write-Warning $Message
}

function Get-DFInstallBlock {
    <#
    .SYNOPSIS
        Returns a manager's installs block for one source (uv has one for PyPI tools and one for Python).
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER Source
        The source. Omitted: the first block.
    .OUTPUTS
        PSCustomObject, or nothing when the manager doesn't install from Source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$Source)
    $blocks = @($Manager.installs | Where-Object { $_ })
    if (-not $Source) { return $blocks | Select-Object -First 1 }
    $blocks | Where-Object { $_.from -eq $Source } | Select-Object -First 1
}

# ---- Shared/DFInteractiveHost.ps1
#Requires -Version 7.2

# Shared: Install-DFTool, the banner and Install-DFNerdFont (DotForge.Helpers) all ask it.

function Test-DFInteractiveHost {
    <#
    .SYNOPSIS
        Whether there is a person to ask: an interactive console host whose input isn't redirected, not started with -NonInteractive.
    .DESCRIPTION
        A scheduled task or CI step started as `pwsh -NonInteractive -File x.ps1`
        has a real console, but Read-Host throws there, so the command line is
        checked too (-NonInteractive, or any prefix of it such as -noni).
    .PARAMETER CommandLine
        The process's arguments. Default: [Environment]::GetCommandLineArgs().
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$CommandLine = [Environment]::GetCommandLineArgs())
    $nonInteractive = @($CommandLine | Where-Object { $_ -match '^[-/]noni' -and 'nonInteractive'.StartsWith($_.Substring(1), [StringComparison]::OrdinalIgnoreCase) })
    if ($nonInteractive) { return $false }
    [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected
}

# ---- Shared/DFToolOwnership.ps1
#Requires -Version 7.2

# Config ownership: DotForge points a requested tool at XDG locations only
# once it owns that tool's config, so a user's existing config is never
# silently hidden. Stateless: the startup core and Resolve-DFToolConflict
# (DotForge.Helpers) both read the ownership file through these functions.
# See docs/superpowers/specs/2026-10-11-config-ownership-design.md.

function Get-DFNativeRoot {
    <#
    .SYNOPSIS
        The folder a ${HOME}, ${APPDATA} or ${LOCALAPPDATA} template names, or $null when it's unset.
    .DESCRIPTION
        The one place those roots are read. The test suite's loader sets the
        script variable DFTestNativeRoot (tests/TestSupport.ps1), so no test
        looks in the developer's real home. It is a script variable, never an
        environment variable, so it can't outlive a test run in a live shell.
    .PARAMETER Name
        HOME, APPDATA or LOCALAPPDATA.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('HOME', 'APPDATA', 'LOCALAPPDATA')][string]$Name)
    $testRoot = Get-Variable -Name DFTestNativeRoot -Scope Script -ValueOnly -ErrorAction Ignore
    if ($testRoot) { return Join-Path $testRoot $Name }
    switch ($Name) {
        'HOME' { $HOME }
        'APPDATA' { $Env:APPDATA }
        'LOCALAPPDATA' { $Env:LOCALAPPDATA }
    }
}

function Expand-DFNativePath {
    <#
    .SYNOPSIS
        Expands an xdg.native path template, or returns $null when a root it names is unset.
    .PARAMETER Template
        e.g. '${APPDATA}/bat/config'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)
    $path = $Template
    foreach ($root in 'HOME', 'APPDATA', 'LOCALAPPDATA') {
        $token = '${' + $root + '}'
        if (-not $path.Contains($token)) { continue }
        $value = Get-DFNativeRoot -Name $root
        if (-not $value) { return $null }
        $path = $path.Replace($token, $value)
    }
    if ($path -cmatch '\$\{XDG_') { return Expand-DFXdgPath $path }
    ConvertTo-DFPath $path
}

function Get-DFToolRelocation {
    <#
    .SYNOPSIS
        The config, data and state paths DotForge points a tool at: its xdg.vars, seeds and native target keys.
    .DESCRIPTION
        Caches are left out: losing one costs nothing. Each result carries the
        key's xdg.native entry, or $null when the record declares none. When
        that entry names a setting (fastfetch's configPath) and the record's
        settings set it, that value is the target.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        pscustomobject: Key, Target (canonical path), Native.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Tool)
    $keep = '^\$\{XDG_(CONFIG|DATA|STATE)_HOME\}'
    $native = $Tool.xdg?.native
    $seen = @{}
    $emit = {
        param([string]$Key, [string]$Template)
        if ($seen.ContainsKey($Key)) { return }
        $seen[$Key] = $true
        $entry = if ($native) { $native.PSObject.Properties[$Key]?.Value }
        $override = if ($entry -and $entry.setting -and $Tool.settings) { $Tool.settings.PSObject.Properties[$entry.setting]?.Value }
        $target = if ($override) { ConvertTo-DFPath (Expand-DFXdgPath $override) } else { Expand-DFXdgPath $Template }
        [pscustomobject]@{ Key = $Key; Target = $target; Native = $entry }
    }
    if ($Tool.xdg?.method -eq 'env' -and $Tool.xdg.vars) {
        foreach ($p in $Tool.xdg.vars.PSObject.Properties) { if ($p.Value -cmatch $keep) { & $emit $p.Name $p.Value } }
    }
    $seed = if ($Tool.setup) { $Tool.setup.PSObject.Properties['seed']?.Value }
    if ($seed) { foreach ($p in $seed.PSObject.Properties) { & $emit $p.Name $p.Name } }
    if ($native) { foreach ($p in $native.PSObject.Properties) { if ($p.Name -cmatch $keep) { & $emit $p.Name $p.Name } } }
}

function Test-DFPathHasContent {
    <#
    .SYNOPSIS
        True for a file, or a folder with at least one file anywhere below it.
    .PARAMETER Path
        The path to check.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    [bool](Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Ignore | Select-Object -First 1)
}

function Get-DFToolOwnershipPath {
    <#
    .SYNOPSIS
        The ownership state file: $XDG_STATE_HOME\dotforge\ownership.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath State) 'dotforge' 'ownership.json'
}

function Read-DFToolOwnership {
    <#
    .SYNOPSIS
        Reads which tools DotForge owns the config of, keyed by tool name.
    .DESCRIPTION
        A missing file is an empty table. A file that can't be read (in use,
        no access) or isn't a JSON object warns and returns $null: callers
        then record nothing, so the file is never overwritten with less than
        it held.
    .OUTPUTS
        System.Collections.Hashtable (name -> entry with since, how and an
        optional pending list), or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFToolOwnershipPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -isnot [System.Collections.IDictionary]) { throw 'it holds no JSON object' }
    } catch {
        Write-Warning "DotForge: $path can't be read ($($_.Exception.Message)), so tool ownership can't be read or recorded. Fix or delete it."
        return $null
    }
    $table = @{}
    foreach ($name in @($data.Keys)) { $table[$name] = [pscustomobject]$data[$name] }
    $table
}

function Save-DFToolOwnership {
    <#
    .SYNOPSIS
        Writes the ownership table atomically; with -Name, merges only those tools' entries into the file as it is now.
    .DESCRIPTION
        Two shells can load at once, and Resolve-DFToolConflict can run while a
        shell loads. With -Name, the file is read again just before writing and
        only the named tools' entries are taken from Ownership (a name missing
        from it is removed), so another shell's records are kept. A file that
        can't be read then is left alone. Without -Name, Ownership replaces the
        whole file.
    .PARAMETER Ownership
        Tool name -> entry.
    .PARAMETER Name
        The tools whose entries this caller changed.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership,
        [string[]]$Name
    )
    $table = $Ownership
    if ($PSBoundParameters.ContainsKey('Name')) {
        $table = Read-DFToolOwnership
        if ($null -eq $table) { return }
        foreach ($toolName in $Name) {
            if ($Ownership.ContainsKey($toolName)) { $table[$toolName] = $Ownership[$toolName] } else { $table.Remove($toolName) }
        }
    }
    Write-DFFileAtomic -Path (Get-DFToolOwnershipPath) -Value ($table | ConvertTo-Json -Depth 10)
}
function Find-DFToolConflict {
    <#
    .SYNOPSIS
        Finds a requested tool's old locations that hold content DotForge would hide.
    .DESCRIPTION
        An owned tool is not checked (no file-system calls). For each relocated
        path (Get-DFToolRelocation), an old location with content is a conflict
        unless it is the target or inside it. A variable already set in the
        process is the user's choice, which DotForge leaves alone, so it is
        skipped and Complete is false: the tool can't be recorded as owned on
        that check.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .OUTPUTS
        pscustomobject: Conflicts (each with Tool, Key, OldPaths, Target,
        TargetHasContent, Move, Guide, Block) and Complete. A conflict with
        Block false (xdg.native block: false) doesn't hold the tool back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership
    )
    if ($Ownership.ContainsKey($Tool.name)) { return [pscustomobject]@{ Conflicts = @(); Complete = $true } }
    $complete = $true
    $sep = [IO.Path]::DirectorySeparatorChar
    $conflicts = foreach ($reloc in @(Get-DFToolRelocation -Tool $Tool)) {
        if ($reloc.Key -cnotmatch '^\$\{' -and [Environment]::GetEnvironmentVariable($reloc.Key, 'Process')) { $complete = $false; continue }
        if (-not $reloc.Native) { continue }
        $found = @(foreach ($template in $reloc.Native.paths) {
            $old = Expand-DFNativePath $template
            if (-not $old) { continue }
            if ($old -eq $reloc.Target -or $old.StartsWith($reloc.Target + $sep, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-DFPathHasContent -Path $old) { $old }
        })
        if ($found) {
            [pscustomobject]@{
                Tool = $Tool.name; Key = $reloc.Key; OldPaths = [string[]]$found; Target = $reloc.Target
                TargetHasContent = Test-DFPathHasContent -Path $reloc.Target
                Move = $reloc.Native.move; Guide = $reloc.Native.guide; Block = $reloc.Native.block
            }
        }
    }
    [pscustomobject]@{ Conflicts = @($conflicts); Complete = $complete }
}

function Invoke-DFPendingRemoval {
    <#
    .SYNOPSIS
        Retries moving a moved tool's old copies aside, once the new location still holds every moved file.
    .DESCRIPTION
        Checks sizes only (hashes were checked when the files moved; hashing a
        large folder on every load would be too slow). A changed or missing
        file keeps that old copy and warns: the user checks it, deletes the old
        copy themselves, and runs Resolve-DFToolConflict <tool> -Done. A copy
        that can't be renamed yet (in use) warns, with the reason, and is
        retried on the next load. A renamed copy is never deleted.
    .PARAMETER Name
        The tool.
    .PARAMETER Ownership
        Read-DFToolOwnership result; the tool's pending list is updated in it.
    .OUTPUTS
        System.Boolean: whether the tool's entry changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Ownership)
    $entry = $Ownership[$Name]
    $before = @($entry.pending)
    $left = @(foreach ($item in $before) {
        $changed = @(foreach ($file in @($item.Files)) {
            $path = if ($file.Path) { Join-Path $item.Target $file.Path } else { $item.Target }
            $info = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
            if (-not $info -or $info.Length -ne $file.Length) { $path }
        })
        if ($changed) {
            Write-Warning "DotForge: $Name's moved config changed since the move ($($changed -join ', ')), so $($item.OldPath) was kept. Check it, delete $($item.OldPath) yourself, then run Resolve-DFToolConflict $Name -Done."
            $item
            continue
        }
        try {
            $aside = Rename-DFOldCopy -Path $item.OldPath
            Write-Host "DotForge: $Name's old copy is now $aside; delete it when you're satisfied."
        } catch {
            Write-Warning "DotForge: couldn't move $($item.OldPath) aside ($($_.Exception.Message)), so DotForge tries again on the next load. To stop this, move it yourself and run Resolve-DFToolConflict $Name -Done."
            $item
        }
    })
    # Items only ever leave the list, so an unchanged count means nothing changed.
    if ($left.Count -eq $before.Count) { return $false }
    if ($left) { $entry.pending = $left } else { $entry.PSObject.Properties.Remove('pending') }
    $true
}

function Get-DFConflictAdvice {
    <#
    .SYNOPSIS
        What to do about a tool whose old config location holds the user's config: one rule, used by the status detail and Resolve-DFToolConflict.
    .DESCRIPTION
        A location DotForge must not move (move: false) needs the tool's own
        instructions, then -Adopt. When the XDG location already has files,
        DotForge has been using that copy, so -Adopt. Otherwise -Move.
        Each instruction is given once, even when several paths share it.
    .PARAMETER Name
        The tool.
    .PARAMETER Conflicts
        Find-DFToolConflict's Conflicts.
    .OUTPUTS
        pscustomobject: Action (Manual, Adopt or Move) and Text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Conflicts)
    $guides = @($Conflicts | Where-Object { -not $_.Move } | ForEach-Object Guide | Where-Object { $_ } | Select-Object -Unique)
    $inUse = @($Conflicts | Where-Object TargetHasContent | ForEach-Object Target | Select-Object -Unique)
    $leave = "or remove $Name from Tools."
    if (@($Conflicts | Where-Object { -not $_.Move })) {
        return [pscustomobject]@{ Action = 'Manual'; Text = "$($guides -join ' ') Then run Resolve-DFToolConflict $Name -Adopt, $leave" }
    }
    if ($inUse) {
        return [pscustomobject]@{ Action = 'Adopt'; Text = "$($inUse -join ', ') has config too: if that is the copy you use, copy anything you need from the old one into it and run Resolve-DFToolConflict $Name -Adopt, $leave" }
    }
    [pscustomobject]@{ Action = 'Move'; Text = "Run Resolve-DFToolConflict $Name -Move (or -Adopt), $leave" }
}

# ---- Shared/DFToolReference.ps1
function ConvertFrom-DFToolReference {
    <#
    .SYNOPSIS
        Reads one entry of a tool record's requires or after list: a tool name, or role:<name>.
    .DESCRIPTION
        The one definition of the reference syntax. A name starts with a letter or
        digit and continues with letters, digits, '.', '_' or '-'. The role: prefix
        is case-insensitive, as it always was.
    .PARAMETER Reference
        The entry, e.g. 'fzf' or 'role:js-runtime'.
    .EXAMPLE
        ConvertFrom-DFToolReference -Reference 'role:js-runtime'

        Returns Kind 'Role', Name 'js-runtime'.
    .OUTPUTS
        pscustomobject with Kind ('Tool' or 'Role') and Name; nothing when the entry is malformed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][AllowNull()][string]$Reference)
    if ($Reference -notmatch '^(?<role>role:)?(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)$') { return }
    [pscustomobject]@{
        Kind = if ($Matches['role']) { 'Role' } else { 'Tool' }
        Name = $Matches['name']
    }
}

function Get-DFRoleMember {
    <#
    .SYNOPSIS
        Returns the tool records, of those given, that join a role.
    .DESCRIPTION
        The one home for "the members of a role" among a set of records (the
        requested tools, the active ones, or every record). Sorted by name.
    .PARAMETER Role
        The role name, e.g. 'js-runtime'.
    .PARAMETER Tools
        The tool records to look through.
    .EXAMPLE
        Get-DFRoleMember -Role 'pager' -Tools $toolDb.Values

        The requested tools that can be the pager.
    .OUTPUTS
        The member records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tools
    )
    @($Tools | Where-Object { $_ -and $_.roles -and $_.roles.PSObject.Properties[$Role] }) | Sort-Object name
}

# ---- Shared/Expand-DFXdgPath.ps1
#Requires -Version 7.2

function Expand-DFXdgPath {
    <#
    .SYNOPSIS
        Expands ${XDG_*} placeholder tokens in a template string to their
        actual environment variable values.
    .DESCRIPTION
        Replaces ${XDG_CONFIG_HOME}, ${XDG_DATA_HOME}, ${XDG_STATE_HOME} and
        ${XDG_CACHE_HOME} (case-sensitive) with the current env var values.
        A template that contained a token is a path, so the result is
        canonicalized with ConvertTo-DFPath. A template with no token (flag
        strings like LESS or FZF_DEFAULT_OPTS) is returned byte-for-byte.
        Used for every value in a tool's xdg.vars and env blocks.
    .PARAMETER Template
        The string to expand, e.g. '${XDG_CONFIG_HOME}/bat'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)

    $expanded = $Template `
        -creplace '\$\{XDG_CONFIG_HOME\}', { Get-DFXdgPath Config } `
        -creplace '\$\{XDG_DATA_HOME\}',   { Get-DFXdgPath Data } `
        -creplace '\$\{XDG_STATE_HOME\}',  { Get-DFXdgPath State } `
        -creplace '\$\{XDG_CACHE_HOME\}',  { Get-DFXdgPath Cache }

    # Normalize ONLY when an XDG token was present: a token-bearing value is always a
    # filesystem path. Token-less values are literal flag strings (LESS, FZF_*, ...)
    # and must pass through byte-for-byte. See docs/external-dependencies.md.
    if ($Template -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') {
        return ConvertTo-DFPath $expanded
    }
    $expanded
}

# ---- Shared/Format-DFInstallCommand.ps1
#Requires -Version 7.2

function Format-DFInstallCommand {
    <#
    .SYNOPSIS
        A manager's install command as one line of text, for a picker, a catalog hint, or the plan.
    .PARAMETER Manager
        The manager's tool record (has installs).
    .PARAMETER Id
        The package id. Omitted: {0} stands in for it (a format string).
    .PARAMETER Feed
        A feed name; the id is then formed by installs.feeds.id.
    .PARAMETER Source
        Which installs block to use, for a manager with several. Default: the first.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$Id, [string]$Feed, [string]$Source)
    $i = Get-DFInstallBlock -Manager $Manager -Source $Source
    if (-not $i) { return }
    $idText = if ($Id) { $Id } else { '{0}' }
    if ($Feed -and $i.feeds) { $idText = $i.feeds.id.Replace('{feed}', $Feed).Replace('{id}', $idText) }
    if ($i.function) {
        # A [bool] argument is a switch: -TrustRepository.
        $fnArgs = @(foreach ($p in $i.args.PSObject.Properties) {
            if ($p.Value -is [bool]) { if ($p.Value) { "-$($p.Name)" } }
            elseif ($p.Value -eq '{id}') { "-$($p.Name) $idText" }
            else { "-$($p.Name) $($p.Value)" }
        })
        # Shown to the user: the command name without its module qualifier.
        return (@($i.function -replace '^[\w.]+\\', '') + $fnArgs) -join ' '
    }
    (@($i.install | ForEach-Object { if ($_ -eq '{id}') { $idText } else { $_ } })) -join ' '
}

function Get-DFInstallHint {
    <#
    .SYNOPSIS
        The command that installs one catalog package, from the best manager for its source.
    .PARAMETER Source
        The catalog source (scoop, winget, choco, npm, crates, psgallery).
    .PARAMETER Id
        The package id.
    .PARAMETER Feed
        The feed (e.g. a scoop bucket), when the id needs one.
    .OUTPUTS
        System.String, or nothing when no manager installs from the source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Id, [string]$Feed)
    $m = Get-DFSourceManager -Source $Source -ToolDb (Import-DFToolDb) | Select-Object -First 1
    if ($m) { Format-DFInstallCommand -Manager $m -Id $Id -Feed $Feed -Source $Source }
}

# ---- Shared/Get-DFFingerprintCache.ps1
#Requires -Version 7.2

function Get-DFFingerprintCache {
    <#
    .SYNOPSIS
        Returns text cached under $XDG_CACHE_HOME\dotforge\<Name>.txt while its fingerprint still matches, otherwise regenerates it.
    .DESCRIPTION
        The one implementation of DotForge's "text plus .key fingerprint" cache,
        used for cached tool init scripts (Get-DFCachedCommandOutput), the help
        topic list and LS_COLORS. The caller decides what invalidates the
        cache by passing a fingerprint string: an executable's identity, the
        installed module set, a theme name.

        A hit needs both files and a key equal to -Fingerprint. On a miss the
        result of -Generate is joined with newlines, trimmed and returned; it
        is written only when non-empty (an empty result is never cached, so a
        transient failure retries next time). Writes go through
        Write-DFFileAtomic, content first and key second: a crash between the
        two leaves an old key, which only costs a regeneration.
    .PARAMETER Name
        Cache entry name; the files are <Name>.txt and <Name>.key. Keep
        existing names stable, since renaming one discards users' caches.
    .PARAMETER Fingerprint
        What the cached text depends on. Must be cheap to compute: callers
        build it on every call.
    .PARAMETER Generate
        Produces the text on a miss. May return a string or lines; $null or
        whitespace means "nothing to cache".
    .PARAMETER Force
        Regenerate even when the fingerprint matches.
    .OUTPUTS
        System.String. The cached or generated text, or $null when -Generate
        produced nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(Mandatory)][scriptblock]$Generate,
        [switch]$Force
    )

    $dir       = Join-Path (Get-DFXdgPath Cache) 'dotforge'
    $cacheFile = Join-Path $dir "$Name.txt"
    $keyFile   = Join-Path $dir "$Name.key"

    if (-not $Force -and (Test-Path $cacheFile -PathType Leaf) -and (Test-Path $keyFile -PathType Leaf) -and
        (Get-Content $keyFile -Raw).Trim() -eq $Fingerprint) {
        return (Get-Content $cacheFile -Raw).Trim()
    }

    $value = (@(& $Generate) -join "`n").Trim()
    if (-not $value) { return $null }
    Write-DFFileAtomic -Path $cacheFile -Value $value
    Write-DFFileAtomic -Path $keyFile   -Value $Fingerprint
    $value
}

# ---- Shared/Get-DFPackageRef.ps1
#Requires -Version 7.2

function Get-DFPackageRef {
    <#
    .SYNOPSIS
        Reads one packages value: a plain id, or { id, feed }.
    .DESCRIPTION
        A tool's packages map is keyed by source (a system manager or a
        registry). Each value is the package id in that source's default feed,
        or an object naming a feed the manager may have to add first:
        { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://..." } }.
        Every reader of packages goes through this, so a feed object is never
        stringified.
    .PARAMETER Value
        The packages value.
    .OUTPUTS
        PSCustomObject with Id and Feed ($null, or { name; url }); nothing for an empty value.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return }
    if ($Value -is [string]) { return [pscustomobject]@{ Id = $Value; Feed = $null } }
    [pscustomobject]@{
        Id   = [string]$Value.PSObject.Properties['id']?.Value
        Feed = $Value.PSObject.Properties['feed']?.Value
    }
}

# ---- Shared/Get-DFToolRegistry.ps1
#Requires -Version 7.2

$script:DFToolRegistry = $null

function Get-DFToolRecordHash {
    <#
    .SYNOPSIS
        The registry key for a tool record's JSON: SHA-256 of its text with line endings normalized to LF.
    .PARAMETER Text
        The JSON text.
    .OUTPUTS
        System.String. Lowercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n").TrimStart([char]0xFEFF))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-DFToolRegistry {
    <#
    .SYNOPSIS
        Returns the shipped tool registry: tool name -> { sha256; record }, loaded once.
    .DESCRIPTION
        data/tool-registry.json (built by build/Build-DFToolRegistry.ps1) holds
        every shipped tool record already validated and normalized, so loading
        a tool skips parsing, validating and normalizing its JSON. An entry is
        used only when the hash of the JSON being read matches, so an edited
        record (or a user's own) always takes the slow path. A missing or
        unreadable registry is an empty one.
    .PARAMETER Path
        The registry file. Default: data/tool-registry.json in the module.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    if (-not $Path -and $null -ne $script:DFToolRegistry) { return $script:DFToolRegistry }
    $file = if ($Path) { $Path } else { Join-Path $PSScriptRoot '..' 'data' 'tool-registry.json' }
    $reg = @{}
    try {
        if ([IO.File]::Exists($file)) {
            $doc = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            foreach ($p in $doc.tools.PSObject.Properties) { $reg[$p.Name] = $p.Value }
        }
    } catch {
        Write-Verbose "DotForge: couldn't read the tool registry ($file): $($_.Exception.Message)"
        $reg = @{}
    }
    if (-not $Path) { $script:DFToolRegistry = $reg }
    $reg
}

# ---- Shared/Import-DFToolDb.ps1
#Requires -Version 7.2

$script:DFToolDb = $null

function Get-DFUserToolsPath {
    <#
    .SYNOPSIS
        Returns the user's own tools folder: dotforge\tools under XDG_CONFIG_HOME.
    .DESCRIPTION
        Records there load with the shipped ones (Import-DFToolDb); a user
        record replaces the shipped record of the same name. The folder may
        not exist.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    ConvertTo-DFPath (Join-Path (Get-DFXdgPath Config) 'dotforge' 'tools')
}

function Import-DFToolDb {
    <#
    .SYNOPSIS
        Loads Tools/*.json files into a cached hashtable keyed by tool name.
        Validates each file with Test-DFToolSchema; invalid files are skipped with a warning.
        Valid records are normalized with ConvertTo-DFToolRecord, so every known
        field exists and callers use plain property access.
    .DESCRIPTION
        At the default location, the user's own folder (Get-DFUserToolsPath)
        is read after the shipped one, and a valid user record replaces the
        shipped record of the same name. Each record's folder and source
        ('builtin' or 'user') say where its JSON, and so its companion files,
        came from.
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
        Supplying this parameter always forces a fresh, uncached read and never
        populates the shared cache -- only calls using the default location
        participate in caching, so a caller with its own directory never sees
        (or clobbers) another caller's registry. It also leaves the user's
        folder out.
    .PARAMETER Force
        Clears the cache and reloads from disk. Has no effect when -ToolsPath is also
        supplied -- that call is always uncached regardless of -Force.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
        [string[]]$Name,
        [switch]$Force
    )

    $explicitToolsPath = $PSBoundParameters.ContainsKey('ToolsPath')
    $userTools = if (-not $explicitToolsPath) { Get-DFUserToolsPath }
    if ($userTools -and -not (Test-Path $userTools -PathType Container)) { $userTools = $null }

    if ($Name) {
        # Only the requested records: one file read each (record name = file name,
        # enforced by tests). Default-location records are cached per name.
        $db = @{}
        foreach ($n in $Name) {
            $record = $null
            if (-not $explicitToolsPath -and -not $Force) {
                if ($script:DFToolDb -and $script:DFToolDb.ContainsKey($n)) { $record = $script:DFToolDb[$n] }
                elseif ($script:DFToolRecordCache.ContainsKey($n)) { $record = $script:DFToolRecordCache[$n] }
            }
            if (-not $record) {
                if ($userTools) {
                    $userFile = Join-Path $userTools "$n.json"
                    if (Test-Path $userFile -PathType Leaf) { $record = Read-DFToolRecordFile -Path $userFile -Source user }
                }
                if (-not $record) {
                    $file = Join-Path $ToolsPath "$n.json"
                    if (-not (Test-Path $file -PathType Leaf)) {
                        Write-Warning "DotForge: no tool record for '$n' ($file)."
                        continue
                    }
                    $record = Read-DFToolRecordFile -Path $file
                }
                if (-not $record) { continue }
                if (-not $explicitToolsPath) {
                    $script:DFToolRecordCache[$record.name] = $record
                    # A fresh read (-Force) also replaces the full load's copy, which lookups prefer.
                    if ($script:DFToolDb) { $script:DFToolDb[$record.name] = $record }
                }
            }
            $db[$record.name] = $record
        }
        return $db
    }

    if (-not $explicitToolsPath -and -not $Force -and $script:DFToolDb) { return $script:DFToolDb }

    $db = @{}

    if (Test-Path $ToolsPath -PathType Container) {
        foreach ($file in Get-ChildItem $ToolsPath -Filter '*.json' -ErrorAction Ignore) {
            $record = Read-DFToolRecordFile -Path $file.FullName
            if ($record) { $db[$record.name] = $record }
        }
    }
    if ($userTools) {
        foreach ($file in Get-ChildItem $userTools -Filter '*.json' -File -ErrorAction Ignore) {
            $record = Read-DFToolRecordFile -Path $file.FullName -Source user
            if ($record) { $db[$record.name] = $record }
        }
    }

    if (-not $explicitToolsPath) { $script:DFToolDb = $db }
    return $db
}

$script:DFToolRecordCache = @{}

function Read-DFToolRecordFile {
    <#
    .SYNOPSIS
        Reads, validates and normalizes one tool JSON file; warns and returns $null when it's invalid.
    .PARAMETER Path
        The tool JSON file.
    .PARAMETER Source
        builtin (default) or user: stored on the record, with the file's folder.
    .OUTPUTS
        pscustomobject (a ConvertTo-DFToolRecord record), or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('builtin', 'user')][string]$Source = 'builtin')
    $leaf = Split-Path $Path -Leaf
    $record = $null
    try {
        $text = [IO.File]::ReadAllText($Path)
        # Unchanged shipped record: already validated and normalized at build time.
        # A copy, so setting folder and source never changes the shared registry object.
        $entry = (Get-DFToolRegistry)[[IO.Path]::GetFileNameWithoutExtension($Path)]
        if ($entry -and $entry.sha256 -eq (Get-DFToolRecordHash -Text $text)) { $record = $entry.record.PSObject.Copy() }
        else { $tool = $text | ConvertFrom-Json }
    } catch {
        Write-Warning "DotForge: Failed to parse $leaf`: $($_.Exception.Message)"
        return $null
    }
    if (-not $record) {
        $schema = Test-DFToolSchema -Tool $tool
        if (-not $schema.Valid) {
            Write-Warning "DotForge: $leaf schema errors: $($schema.Errors -join '; ')"
            return $null
        }
        foreach ($w in $schema.Warnings) { Write-Warning "DotForge: $leaf`: $w" }
        $record = ConvertTo-DFToolRecord $tool
    }
    # Records are looked up by file name (Import-DFToolDb -Name), so a user record named
    # differently would load only some of the time, or stand in for another tool.
    if ($Source -eq 'user' -and $record.name -ne [IO.Path]::GetFileNameWithoutExtension($Path)) {
        Write-Warning "DotForge: $leaf names its tool '$($record.name)', so it is skipped; name the file $($record.name).json."
        return $null
    }
    $record.folder = ConvertTo-DFPath (Split-Path $Path -Parent)
    $record.source = $Source
    $record
}

function Get-DFToolFolder {
    <#
    .SYNOPSIS
        The folder holding a tool's companion, setup, manage and seed files: the folder its record was read from.
    .DESCRIPTION
        A user record's files sit next to it in the user's folder, a shipped
        record's in Tools/. A record built without the loader (tests) has no
        folder, and gets -Default.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Default
        The folder for a record with none.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [string]$Default)
    $Tool.PSObject.Properties['folder']?.Value ?? $Default
}

function Get-DFToolNames {
    <#
    .SYNOPSIS
        Lists the names of every tool DotForge has a record for, from file names alone.
    .DESCRIPTION
        Reads no file: a record's name equals its file name (tests enforce it),
        so request resolution can validate names without loading records.
    .PARAMETER ToolsPath
        The tools folder. Default: the module's Tools/, plus the user's own
        folder (Get-DFUserToolsPath).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    $folders = @($ToolsPath)
    if (-not $PSBoundParameters.ContainsKey('ToolsPath')) { $folders += Get-DFUserToolsPath }
    @(Get-ChildItem $folders -Filter '*.json' -File -ErrorAction Ignore | ForEach-Object BaseName | Sort-Object -Unique)
}

function Get-DFToolRecordProperty {
    <#
    .SYNOPSIS
        Reads a property of a parsed JSON object, or a default when it is absent (StrictMode-safe).
    .PARAMETER Object
        See the synopsis.
    .PARAMETER Name
        See the synopsis.
    .PARAMETER Default
        See the synopsis.
    #>
    param($Object, [string]$Name, $Default)

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $Default }
}

function ConvertTo-DFXdgBlock {
    <#
    .SYNOPSIS
        Normalizes a tool record's xdg block: every field present.
    .PARAMETER RawXdg
        See the synopsis.
    #>
    param($RawXdg)

    if (-not $RawXdg) { return $null }

    [pscustomobject]@{
        method       = Get-DFToolRecordProperty $RawXdg 'method' $null
        vars         = Get-DFToolRecordProperty $RawXdg 'vars' $null
        dirs         = @(Get-DFToolRecordProperty $RawXdg 'dirs' @())
        instructions = Get-DFToolRecordProperty $RawXdg 'instructions' $null
        compliance   = Get-DFToolRecordProperty $RawXdg 'compliance' $null
        native       = ConvertTo-DFNativeMap (Get-DFToolRecordProperty $RawXdg 'native' $null)
    }
}

function ConvertTo-DFBannerField {
    <#
    .SYNOPSIS
        Normalizes a record's banner part: { script, body, fills }.
    .PARAMETER RawBanner
        See the synopsis.
    #>
    param($RawBanner)

    if (-not $RawBanner) { return $null }
    [pscustomobject]@{
        script = Get-DFToolRecordProperty $RawBanner 'script' $null
        body   = [bool](Get-DFToolRecordProperty $RawBanner 'body' $false)
        fills  = [string[]]@(Get-DFToolRecordProperty $RawBanner 'fills' @())
    }
}

function ConvertTo-DFNativeMap {
    <#
    .SYNOPSIS
        Normalizes xdg.native: each key's old locations as { paths, move, guide, setting }.
    .PARAMETER RawNative
        See the synopsis.
    #>
    param($RawNative)

    if (-not $RawNative) { return $null }
    $map = [ordered]@{}
    foreach ($p in $RawNative.PSObject.Properties) {
        $map[$p.Name] = if ($p.Value -is [pscustomobject]) {
            [pscustomobject]@{
                paths = [string[]]@(Get-DFToolRecordProperty $p.Value 'paths' @())
                move  = [bool](Get-DFToolRecordProperty $p.Value 'move' $true)
                guide = Get-DFToolRecordProperty $p.Value 'guide' $null
                setting = Get-DFToolRecordProperty $p.Value 'setting' $null
                block = [bool](Get-DFToolRecordProperty $p.Value 'block' $true)
            }
        } else { [pscustomobject]@{ paths = [string[]]@($p.Value); move = $true; guide = $null; setting = $null; block = $true } }
    }
    [pscustomobject]$map
}

function ConvertTo-DFAliasMap {
    <#
    .SYNOPSIS
        Normalizes an aliases map (top level or a role block's): command and args per alias.
    .PARAMETER RawAliases
        See the synopsis.
    #>
    param($RawAliases)

    if (-not $RawAliases) { return $null }

    $normalized = [ordered]@{}
    foreach ($alias in $RawAliases.PSObject.Properties) {
        $rawArgs = Get-DFToolRecordProperty $alias.Value 'args' $null
        $normalized[$alias.Name] = [pscustomobject]@{
            command = Get-DFToolRecordProperty $alias.Value 'command' $null
            # @() around the whole if: a one-element array assigned from an
            # if-expression would otherwise unwrap to a bare string.
            args    = [object[]]@(if ($null -ne $rawArgs) { $rawArgs })
        }
    }
    [pscustomobject]$normalized
}

function ConvertTo-DFRoleArgv {
    <#
    .SYNOPSIS
        A role block's argv field as a string array (a one-element array stays an array), or $null.
    .PARAMETER Block
        The raw role block.
    .PARAMETER Field
        The field name.
    #>
    param([pscustomobject]$Block, [string]$Field)
    $property = $Block.PSObject.Properties[$Field]
    if (-not $property -or $null -eq $property.Value) { return $null }
    , [string[]]@($property.Value)
}

function ConvertTo-DFRoleMap {
    <#
    .SYNOPSIS
        Normalizes a tool's roles, reading the legacy v1 role string as a priority-0 membership.
    .PARAMETER Tool
        See the synopsis.
    #>
    param([pscustomobject]$Tool)

    $roles = [ordered]@{}
    $rawRoles = Get-DFToolRecordProperty $Tool 'roles' $null
    if ($rawRoles) {
        foreach ($role in $rawRoles.PSObject.Properties) {
            $roles[$role.Name] = [pscustomobject]@{
                priority = [int](Get-DFToolRecordProperty $role.Value 'priority' 0)
                optIn    = [bool](Get-DFToolRecordProperty $role.Value 'optIn' $false)
                aliases  = ConvertTo-DFAliasMap (Get-DFToolRecordProperty $role.Value 'aliases' $null)
                env      = Get-DFToolRecordProperty $role.Value 'env' $null
                flags    = ConvertTo-DFRoleFlags (Get-DFToolRecordProperty $role.Value 'flags' $null)
                # Folder sources for Alt+C (directory-jump), read with Get-DFRoleDeclaration.
                directories   = ConvertTo-DFRoleArgv $role.Value 'directories'
                directoriesScored = [bool](Get-DFToolRecordProperty $role.Value 'directoriesScored' $false)
                enter         = Get-DFToolRecordProperty $role.Value 'enter' $null
                directoryScan = ConvertTo-DFRoleArgv $role.Value 'directoryScan'
                legacy   = $false
            }
        }
    }

    # Role v1 declared a single "role" string; read it as a priority-0 membership.
    # legacy marks it so registration keeps v1 behavior: no hook expected, and a
    # loser's top-level aliases that the role reserves are left out.
    $legacyRole = Get-DFToolRecordProperty $Tool 'role' $null
    if ($legacyRole -and -not $roles.Contains($legacyRole)) {
        $roles[$legacyRole] = [pscustomobject]@{ priority = 0; optIn = $false; aliases = $null; env = $null; flags = $null; directories = $null; directoriesScored = $false; enter = $null; directoryScan = $null; legacy = $true }
    }

    [pscustomobject]$roles
}

function ConvertTo-DFPickerBlock {
    <#
    .SYNOPSIS
        Normalizes declarative pickers (one object or a list) to a list; null and "custom" pass through.
    .PARAMETER RawPicker
        See the synopsis.
    #>
    param($RawPicker)

    if ($null -eq $RawPicker -or $RawPicker -is [string]) { return $RawPicker }
    # The comma keeps a one-element list from unrolling into its element.
    , [object[]]@(foreach ($picker in @($RawPicker)) { ConvertTo-DFPickerEntry $picker })
}

function ConvertTo-DFPickerEntry {
    <#
    .SYNOPSIS
        Normalizes one declarative picker object: every field exists, with its default.
    .PARAMETER RawPicker
        See the synopsis.
    #>
    param($RawPicker)

    if ($RawPicker -isnot [pscustomobject]) { return $RawPicker }

    [pscustomobject]@{
        function          = Get-DFToolRecordProperty $RawPicker 'function' $null
        alias             = Get-DFToolRecordProperty $RawPicker 'alias' $null
        list              = Get-DFToolRecordProperty $RawPicker 'list' $null
        list_accepts_path = [bool](Get-DFToolRecordProperty $RawPicker 'list_accepts_path' $false)
        preview           = Get-DFToolRecordProperty $RawPicker 'preview' ''
        preview_plain     = Get-DFToolRecordProperty $RawPicker 'preview_plain' ''
        preview_window    = Get-DFToolRecordProperty $RawPicker 'preview_window' 'right:60%'
        ansi              = [bool](Get-DFToolRecordProperty $RawPicker 'ansi' $false)
        header            = Get-DFToolRecordProperty $RawPicker 'header' ''
        action            = Get-DFToolRecordProperty $RawPicker 'action' $null
        parse             = Get-DFToolRecordProperty $RawPicker 'parse' $null
    }
}

function ConvertTo-DFSetupBlock {
    <#
    .SYNOPSIS
        Normalizes a tool record's setup block.
    .PARAMETER RawSetup
        See the synopsis.
    #>
    param($RawSetup)

    if (-not $RawSetup) { return $null }

    [pscustomobject]@{
        seed  = Get-DFToolRecordProperty $RawSetup 'seed' $null
        notes = @(Get-DFToolRecordProperty $RawSetup 'notes' @())
    }
}

function ConvertTo-DFInstallsBlock {
    <#
    .SYNOPSIS
        Normalizes a package manager's installs blocks into a list (one object or several).
    .PARAMETER RawInstalls
        See the synopsis.
    #>
    param($RawInstalls)

    if ($null -eq $RawInstalls) { return $null }

    # A package manager's installs blocks (install spec section 1): one object,
    # or a list when it installs from several sources (uv: PyPI tools and Python).
    $normalized = [object[]]@(foreach ($block in @($RawInstalls)) {
        $feeds = Get-DFToolRecordProperty $block 'feeds' $null
        if ($feeds) {
            $feeds = [pscustomobject]@{
                list = [string[]]@(Get-DFToolRecordProperty $feeds 'list' @())
                add  = [string[]]@(Get-DFToolRecordProperty $feeds 'add' @())
                id   = Get-DFToolRecordProperty $feeds 'id' '{feed}/{id}'
            }
        }
        $install = Get-DFToolRecordProperty $block 'install' $null
        [pscustomobject]@{
            from       = Get-DFToolRecordProperty $block 'from' $null
            install    = $(if ($null -ne $install) { [string[]]@($install) })
            update     = ConvertTo-DFManagerOperation (Get-DFToolRecordProperty $block 'update' $null)
            remove     = ConvertTo-DFManagerOperation (Get-DFToolRecordProperty $block 'remove' $null)
            list       = Get-DFToolRecordProperty $block 'list' $null
            outdated   = Get-DFToolRecordProperty $block 'outdated' $null
            function   = Get-DFToolRecordProperty $block 'function' $null
            args       = Get-DFToolRecordProperty $block 'args' $null
            batch      = [bool](Get-DFToolRecordProperty $block 'batch' $false)
            elevate    = [bool](Get-DFToolRecordProperty $block 'elevate' $false)
            reactivate = [bool](Get-DFToolRecordProperty $block 'reactivate' $false)
            feeds      = $feeds
        }
    })
    Write-Output -NoEnumerate $normalized
}

function ConvertTo-DFManagerOperation {
    <#
    .SYNOPSIS
        Normalizes an installs block's update or remove: $null, an argv (string[]), or { function; args }.
    .PARAMETER RawOperation
        See the synopsis.
    #>
    param($RawOperation)
    if ($null -eq $RawOperation) { return $null }
    if ($RawOperation -is [array]) { return ,[string[]]@($RawOperation) }
    [pscustomobject]@{
        function = Get-DFToolRecordProperty $RawOperation 'function' $null
        args     = Get-DFToolRecordProperty $RawOperation 'args' $null
    }
}

function ConvertTo-DFInstallBlock {
    <#
    .SYNOPSIS
        Normalizes a tool record's install block: prefer (its preferred sources) and avoid (source -> why it's bad for this tool).
    .DESCRIPTION
        Always returns the block, empty when the record has none, so install.prefer and install.avoid read without checks.
    .PARAMETER RawInstall
        See the synopsis.
    #>
    param($RawInstall)

    if (-not $RawInstall) { return [pscustomobject]@{ prefer = [string[]]@(); avoid = [pscustomobject]@{} } }
    $avoid = Get-DFToolRecordProperty $RawInstall 'avoid' $null
    [pscustomobject]@{
        prefer = [string[]]@(Get-DFToolRecordProperty $RawInstall 'prefer' @())
        avoid  = if ($avoid -is [pscustomobject]) { $avoid } else { [pscustomobject]@{} }
    }
}

function ConvertTo-DFThemeBlock {
    <#
    .SYNOPSIS
        Normalizes a tool's theme block: every field present, valid a string array, map defaulting to the legacy top-level themeMap.
    .PARAMETER RawTheme
        The parsed theme object, or $null.
    .PARAMETER LegacyMap
        The tool's top-level themeMap, or $null.
    .OUTPUTS
        PSCustomObject, or $null when there is no theme block.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RawTheme, [AllowNull()][object]$LegacyMap)
    if ($null -eq $RawTheme) { return $null }
    [pscustomobject]@{
        key      = Get-DFToolRecordProperty $RawTheme 'key' $null
        default  = Get-DFToolRecordProperty $RawTheme 'default' $null
        map      = Get-DFToolRecordProperty $RawTheme 'map' $LegacyMap
        files    = Get-DFToolRecordProperty $RawTheme 'files' $null
        valid    = [string[]]@(Get-DFToolRecordProperty $RawTheme 'valid' @())
        fallback = Get-DFToolRecordProperty $RawTheme 'fallback' $null
        env      = Get-DFToolRecordProperty $RawTheme 'env' $null
        command  = Get-DFToolRecordProperty $RawTheme 'command' $null
        apply    = Get-DFToolRecordProperty $RawTheme 'apply' $null
    }
}

function ConvertTo-DFWrapperBlock {
    <#
    .SYNOPSIS
        Normalizes a tool's wrapper block: args becomes a list of { ifFile; unlessFile; unlessArg; args } groups, custom a boolean.
    .PARAMETER RawWrapper
        The parsed wrapper object, or $null.
    .OUTPUTS
        PSCustomObject, or $null when there is no wrapper block.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RawWrapper)
    if ($null -eq $RawWrapper) { return $null }
    $groups = foreach ($entry in @($RawWrapper.PSObject.Properties['args']?.Value)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { [pscustomobject]@{ ifFile = $null; unlessFile = $null; unlessArg = [string[]]@(); args = [string[]]@($entry) }; continue }
        [pscustomobject]@{
            ifFile     = Get-DFToolRecordProperty $entry 'ifFile' $null
            unlessFile = Get-DFToolRecordProperty $entry 'unlessFile' $null
            unlessArg  = [string[]]@($entry.PSObject.Properties['unlessArg']?.Value | Where-Object { $_ })
            args       = [string[]]@($entry.PSObject.Properties['args']?.Value)
        }
    }
    [pscustomobject]@{ args = [object[]]@($groups); custom = [bool](Get-DFToolRecordProperty $RawWrapper 'custom' $false) }
}

function ConvertTo-DFToolRecord {
    <#
    .SYNOPSIS
        Returns a tool record (parsed Tools/<name>.json) with every known field
        present and defaulted, so callers can use plain property access.
    .DESCRIPTION
        The boundary between the loosely shaped JSON a tool author writes and
        the record the rest of DotForge reads. Every known top-level field
        exists on the result; absent ones get their default:

            type 'exe', description '', tags @(), after @(), requires @(), prewarm $true,
            nerdFont $null ('required': the tool only draws icons, so it isn't loaded while icons are off),
            packages / xdg / env / aliases / picker / themeMap / theme / wrapper /
            settings / setup $null, roles an empty object, executableExclude @(),
            folder / source $null (the loader sets them: where the JSON was
            read from, and 'builtin' or 'user')

        theme, when present, has key, default, map (falling back to the legacy
        top-level themeMap), files, valid (string[]), fallback, env, command and apply.

        wrapper, when present, has args (a list of { ifFile; args } groups; a
        plain string is its own group) and custom.

        roles is an object keyed by role name; each value is { priority
        (default 0); optIn (default $false); aliases (same shape as top-level
        aliases, or $null); env; legacy }. An opt-in member is considered only
        when $DFConfig.Defaults selects it for that role. A legacy "role": "x"
        string becomes roles.x with priority 0 and legacy $true.

        Nested shapes are normalized too: xdg always has method, vars, dirs,
        instructions and compliance; setup, when present, has seed (an object
        mapping destination path template to a file under Tools/, or $null);
        installs, when present, is a list of blocks (a single object in the
        JSON becomes a one-block list), each with from, install (string[] or
        $null), function, args, batch, elevate and reactivate ($false by
        default) and feeds ($null, or { list; add; id = '{feed}/{id}' }); install, when
        present, has prefer (string[]); each alias is
        { command; args[] } with a missing args meaning none; an object picker
        has every field, with preview '', preview_plain '' (the preview used
        while icons are off), preview_window 'right:60%',
        header '', ansi and list_accepts_path $false. A non-object picker (the
        "custom" marker) is kept as is, and so is the free-form settings
        object, whose shape each tool's companion owns. Unknown fields are
        kept. Reading any known field of the result is safe under
        Set-StrictMode -Version Latest.

        Validation (required fields, allowed values) is Test-DFToolSchema's
        job and happens before this.
    .PARAMETER Tool
        The parsed JSON object.
    .OUTPUTS
        PSCustomObject. A new object; the input is not modified.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][pscustomobject]$Tool)

    $xdg = ConvertTo-DFXdgBlock (Get-DFToolRecordProperty $Tool 'xdg' $null)
    $aliases = ConvertTo-DFAliasMap (Get-DFToolRecordProperty $Tool 'aliases' $null)
    $roles = ConvertTo-DFRoleMap $Tool
    $picker = ConvertTo-DFPickerBlock (Get-DFToolRecordProperty $Tool 'picker' $null)
    $setup = ConvertTo-DFSetupBlock (Get-DFToolRecordProperty $Tool 'setup' $null)
    $installs = ConvertTo-DFInstallsBlock (Get-DFToolRecordProperty $Tool 'installs' $null)
    $install = ConvertTo-DFInstallBlock (Get-DFToolRecordProperty $Tool 'install' $null)

    $record = [ordered]@{
        name              = $Tool.name
        executable        = $Tool.executable
        type              = Get-DFToolRecordProperty $Tool 'type' 'exe'
        description       = Get-DFToolRecordProperty $Tool 'description' ''
        tags              = [object[]]@(Get-DFToolRecordProperty $Tool 'tags' @())
        packages          = Get-DFToolRecordProperty $Tool 'packages' $null
        xdg               = $xdg
        env               = Get-DFToolRecordProperty $Tool 'env' $null
        aliases           = $aliases
        picker            = $picker
        after             = [object[]]@(Get-DFToolRecordProperty $Tool 'after' @())
        requires          = [object[]]@(Get-DFToolRecordProperty $Tool 'requires' @())
        roles             = $roles
        themeMap          = Get-DFToolRecordProperty $Tool 'themeMap' $null
        theme             = ConvertTo-DFThemeBlock (Get-DFToolRecordProperty $Tool 'theme' $null) (Get-DFToolRecordProperty $Tool 'themeMap' $null)
        wrapper           = ConvertTo-DFWrapperBlock (Get-DFToolRecordProperty $Tool 'wrapper' $null)
        settings          = Get-DFToolRecordProperty $Tool 'settings' $null
        executableExclude = [object[]]@(Get-DFToolRecordProperty $Tool 'executableExclude' @())
        prewarm           = [bool](Get-DFToolRecordProperty $Tool 'prewarm' $true)
        nerdFont          = Get-DFToolRecordProperty $Tool 'nerdFont' $null
        setup             = $setup
        banner            = ConvertTo-DFBannerField (Get-DFToolRecordProperty $Tool 'banner' $null)
        installs          = $installs
        install           = $install
        # Set by the loader (Read-DFToolRecordFile) from where the JSON was read, never by the JSON.
        folder            = $null
        source            = $null
    }

    # Keep fields DotForge doesn't model, so tool authors can carry extra data.
    foreach ($property in $Tool.PSObject.Properties) {
        if (-not $record.Contains($property.Name) -and $property.Name -ne 'role') {
            $record[$property.Name] = $property.Value
        }
    }
    [pscustomobject]$record
}

function ConvertTo-DFRoleFlags {
    <#
    .SYNOPSIS
        Normalizes a role block's flags: word -> array of arguments and groups ($null when absent).
    .PARAMETER Flags
        The parsed flags object.
    .OUTPUTS
        PSCustomObject, or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Flags)
    if ($Flags -isnot [pscustomobject]) { return $null }
    $map = [ordered]@{}
    # An item is an argument, or a { ifFile, unlessFile, args } group (Resolve-DFRoleFlagGroup).
    foreach ($p in $Flags.PSObject.Properties) { $map[$p.Name] = @($p.Value | ForEach-Object { if ($_ -is [string]) { [string]$_ } elseif ($_ -is [pscustomobject]) { $_ } else { [string]$_ } }) }
    [pscustomobject]$map
}

# ---- Shared/Invoke-DFBoundedProcess.ps1
#Requires -Version 7.2

function Invoke-DFBoundedProcess {
    <#
    .SYNOPSIS
        Runs an executable with a time limit and returns its output lines and exit code.
    .DESCRIPTION
        For outside programs that can hang (winget waiting on a source update or
        a stuck network call). Standard output is captured and split into lines
        the way PowerShell splits a native command's output; standard error is
        discarded unless -IncludeStandardError is set. A process still running after -TimeoutSeconds is killed with
        its child processes, and the call throws, naming the command.
        Output is decoded with [Console]::OutputEncoding, as `& exe` would.
    .PARAMETER FilePath
        The executable's full path.
    .PARAMETER ArgumentList
        Arguments, each passed as one argument (no quoting needed).
    .PARAMETER TimeoutSeconds
        How long to wait before killing the process.
    .PARAMETER IncludeStandardError
        Include standard error lines after the standard output lines. The
        original interleaving of the two streams is not preserved.
    .OUTPUTS
        pscustomobject: Lines (string[]), ExitCode (int).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSeconds,
        [switch]$IncludeStandardError
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Console]::OutputEncoding
    $startInfo.StandardErrorEncoding = [Console]::OutputEncoding

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        # Read both streams asynchronously: a full, unread pipe would block the child.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Verbose "DotForge: couldn't kill '$FilePath': $($_.Exception.Message)" }
            $command = (@([System.IO.Path]::GetFileName($FilePath)) + $ArgumentList) -join ' '
            throw "DotForge: '$command' did not finish within $TimeoutSeconds s and was stopped."
        }
        $process.WaitForExit()   # lets the redirected streams drain
        $text = $stdout.GetAwaiter().GetResult()
        $lines = @($text -split '\r?\n')
        if ($lines.Count -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
        if ($IncludeStandardError) {
            $errorText = $stderr.GetAwaiter().GetResult()
            $errorLines = @($errorText -split '\r?\n')
            if ($errorLines.Count -and $errorLines[-1] -eq '') { $errorLines = @($errorLines | Select-Object -SkipLast 1) }
            $lines = @($lines) + @($errorLines)
        }
        [pscustomobject]@{ Lines = [string[]]$lines; ExitCode = $process.ExitCode }
    } finally {
        $process.Dispose()
    }
}

# ---- Shared/Invoke-DFFzf.ps1
#Requires -Version 7.2

function Invoke-DFFzf {
    <#
    .SYNOPSIS
        Thin wrapper around fzf (or the picker named in $Env:Picker).
        Exists as a separate function so tests can mock it without spawning fzf.
        Set $Env:Picker = 'skim' (or any fzf-compatible picker) to override the default.
    .PARAMETER InputItems
        Items to pipe into the picker.
    .PARAMETER FzfArgs
        Arguments array forwarded to the picker.
    #>
    [CmdletBinding()]
    param(
        [string[]]$InputItems,
        [string[]]$FzfArgs
    )

    [string] $picker = if ($Env:Picker) { $Env:Picker } else { 'fzf' }
    if (-not (Get-Command $picker -ErrorAction Ignore)) {
        Write-Error "DotForge: '$picker' is not on PATH. Install fzf or set `$Env:Picker to your picker's executable name." -ErrorAction Stop
    }
    $InputItems | & $picker @FzfArgs
}

# ---- Shared/Invoke-DFPagerExe.ps1
#Requires -Version 7.2

function Invoke-DFPagerExe {
    <#
    .SYNOPSIS
        Thin wrapper around an external pager command.
        Exists as a separate function so tests can mock it without spawning a real pager.
    .PARAMETER Lines
        Lines of text to pipe into the pager.
    .PARAMETER Pager
        The pager command string (e.g. 'less', 'less -R', 'bat --paging=always').
        A double-quoted program path may come first (a path with spaces).
        Quoted arguments (e.g. --theme "Dracula") are not supported; use
        --key=value form instead (e.g. --theme=Dracula).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Pager
    )
    # A leading double-quoted program path (what ${DF_TOOL_EXE} produces for a
    # path with spaces) is the program; the rest splits on whitespace.
    if ($Pager -match '^\s*"([^"]+)"\s*(.*)$') {
        $program = $Matches[1]
        $rest    = $Matches[2]
    } else {
        $parts   = $Pager.Trim() -split '\s+', 2
        $program = $parts[0]
        $rest    = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }
    # A double-quoted argument stays whole (DotForge quotes a path with a space, such as
    # ov's --config); single quotes aren't understood.
    if ($rest -match "\x27") {
        Write-Warning "DotForge: Single-quoted arguments in `$Env:Pager are not supported. Use double quotes or --key=value form (e.g. bat --theme=Dracula)."
    }
    [string[]] $pagerArgs = @([regex]::Matches($rest, '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
    $Lines | & $program @pagerArgs
}

# ---- Shared/Rename-DFOldCopy.ps1
#Requires -Version 7.2

function Rename-DFOldCopy {
    <#
    .SYNOPSIS
        Moves a moved tool's old config out of the tool's way by renaming it next to where it was.
    .DESCRIPTION
        Renames it to <name>.dotforge-moved, or <name>.dotforge-moved-2, -3, ...
        when an earlier copy holds that name. Nothing is deleted and no window
        opens: the user deletes the renamed copy when satisfied. The rename
        fails cleanly when anything inside is in use.
    .PARAMETER Path
        The old location.
    .OUTPUTS
        System.String: the renamed copy's path. Throws when the rename fails.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $parent = Split-Path $Path
    $name = (Split-Path $Path -Leaf) + '.dotforge-moved'
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $parent $name)) {
        $n++
        $name = (Split-Path $Path -Leaf) + ".dotforge-moved-$n"
    }
    Rename-Item -LiteralPath $Path -NewName $name -ErrorAction Stop
    Join-Path $parent $name
}

# ---- Shared/Test-DFOutputPiped.ps1
#Requires -Version 7.2

function Test-DFOutputPiped {
    <#
    .SYNOPSIS
        Reports whether a function's output is being piped or redirected rather than
        going straight to an interactive terminal.
    .DESCRIPTION
        Returns $true when either of the following holds for the supplied caller
        invocation:
          * the caller is not the last element of its pipeline
            (PipelinePosition -lt PipelineLength) — e.g. `Get-DFEnv | Where-Object`; or
          * the process's stdout is redirected ([Console]::IsOutputRedirected) —
            e.g. `Get-DFEnv > out.txt` or piping to an external program.

        Display helpers use this to suppress ANSI color when their output is being
        consumed by another command, so downstream string matching and captured
        files stay free of escape sequences. It exists as a private wrapper so tests
        can mock the decision without manipulating the real pipeline or stdout.
    .PARAMETER Invocation
        The caller's $MyInvocation. The pipeline position/length are read from this
        object, so it must be the caller's own invocation, not this function's.
    .EXAMPLE
        if (-not (Test-DFOutputPiped -Invocation $MyInvocation)) { <emit color> }
        Colorizes only when output is bound for an interactive terminal.
    .OUTPUTS
        System.Boolean — $true when output is piped or redirected.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.InvocationInfo]$Invocation
    )
    ($Invocation.PipelinePosition -lt $Invocation.PipelineLength) -or
        [Console]::IsOutputRedirected
}

function Test-DFColorOutput {
    <#
    .SYNOPSIS
        Decides whether a display command should emit ANSI color.
    .DESCRIPTION
        Color is used only when $Env:NO_COLOR is unset, the host supports
        virtual-terminal sequences, and (when -Invocation is given) the
        caller's output isn't being piped or redirected. The one place every
        colorizing command makes this decision.
    .PARAMETER Invocation
        The caller's $MyInvocation, to also turn color off when output is piped.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([System.Management.Automation.InvocationInfo]$Invocation)
    if ($Env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal) { return $false }
    -not ($Invocation -and (Test-DFOutputPiped -Invocation $Invocation))
}

function Get-DFAnsiPalette {
    <#
    .SYNOPSIS
        Returns DotForge's ANSI styles, or empty strings for every style when color is off.
    .DESCRIPTION
        Formatters interpolate these unconditionally, so plain output needs no
        separate code path. Title is bold cyan, Accent bold yellow, Faint dim
        (it adapts to the terminal's theme), Green green, Reset resets.
    .PARAMETER Color
        Whether to return real escape sequences (usually Test-DFColorOutput).
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][bool]$Color)
    if (-not $Color) { return @{ Title = ''; Accent = ''; Faint = ''; Green = ''; Reset = '' } }
    @{ Title = "`e[1;36m"; Accent = "`e[1;33m"; Faint = "`e[2m"; Green = "`e[32m"; Reset = "`e[0m" }
}

# ---- Shared/Test-DFToolSchema.ps1
#Requires -Version 7.2

# Helper: safely read a property from a PSCustomObject without throwing under StrictMode
function Get-DFSchemaProperty ([PSCustomObject]$obj, [string]$key) {
    <#
    .SYNOPSIS
        StrictMode-safe property read: $obj.<key>, or $null when $obj or the property is absent.
    .PARAMETER obj
        The object to read from; may be $null.
    .PARAMETER key
        The property name.
    #>
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$key]
    if ($p) { return $p.Value } else { return $null }
}

function Get-DFCoreFieldSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in the required fields, type, xdg.method and executableExclude.
    #>
    # Required fields
    if (-not (Get-DFSchemaProperty $Tool 'name'))       { "Missing required field: name" }
    if (-not (Get-DFSchemaProperty $Tool 'executable')) { "Missing required field: executable" }

    # type valid values
    $validToolTypes = @('exe', 'module')
    $toolType = Get-DFSchemaProperty $Tool 'type'
    if ($toolType -and $toolType -notin $validToolTypes) {
        "Invalid type '$toolType'. Valid: $($validToolTypes -join ', ')"
    }

    # xdg.method valid values
    $validMethods = @('default', 'env', 'wrapper', 'manual')
    $xdgMethod = Get-DFSchemaProperty (Get-DFSchemaProperty $Tool 'xdg') 'method'
    if ($xdgMethod -and $xdgMethod -notin $validMethods) {
        "Invalid xdg.method '$xdgMethod'. Valid: $($validMethods -join ', ')$(if ($xdgMethod -eq 'config') { ". Seed a default config file with setup.seed instead" })"
    }

    # executableExclude: glob patterns of install locations to skip.
    # Read the property directly: returning it through Get-DFSchemaProperty would unroll a
    # one-element array into a bare string and fail the array check.
    $exclude = $Tool.PSObject.Properties['executableExclude']?.Value
    if ($null -ne $exclude -and ($exclude -isnot [array] -or @($exclude | Where-Object { $_ -isnot [string] }).Count)) {
        'executableExclude must be an array of strings'
    }
}

function Get-DFPackagesSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in packages, and the replaced scoopBucket field.
    #>
    # packages: source -> an id, or { id, feed: { name, url } } for a third-party feed.
    $pk = Get-DFSchemaProperty $Tool 'packages'
    if ($pk -is [pscustomobject]) {
        foreach ($p in $pk.PSObject.Properties) {
            $v = $p.Value
            $feed = if ($v -is [pscustomobject]) { Get-DFSchemaProperty $v 'feed' }
            $ok = ($v -is [string]) -or ($v -is [pscustomobject] -and (Get-DFSchemaProperty $v 'id') -is [string] -and (Get-DFSchemaProperty $v 'id') -and
                  ($null -eq $feed -or ((Get-DFSchemaProperty $feed 'name') -and (Get-DFSchemaProperty $feed 'url'))))
            if (-not $ok) { "packages.$($p.Name) must be an id, or { id, feed: { name, url } }" }
        }
    }
    if ($Tool.PSObject.Properties['scoopBucket']) {
        'scoopBucket was replaced: put { id, feed: { name, url } } in packages.scoop'
    }
}

function Get-DFRolesSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in the shape of roles (a role block's aliases and env are checked separately).
    #>
    # roles: an object keyed by role name; priority is an integer and optIn is a boolean when present.
    $roles = Get-DFSchemaProperty $Tool 'roles'
    if ($null -ne $roles) {
        if ($roles -isnot [pscustomobject]) {
            'roles must be an object keyed by role name'
        } else {
            foreach ($r in $roles.PSObject.Properties) {
                $priority = Get-DFSchemaProperty $r.Value 'priority'
                if ($null -ne $priority -and $priority -isnot [int] -and $priority -isnot [long]) {
                    "roles.$($r.Name).priority must be an integer"
                }
                $optIn = Get-DFSchemaProperty $r.Value 'optIn'
                if ($null -ne $optIn -and $optIn -isnot [bool]) {
                    "roles.$($r.Name).optIn must be a boolean"
                }
                # Folder sources for Alt+C (directory-jump): argv lists and a command name.
                foreach ($field in 'directories', 'directoryScan') {
                    $present = $r.Value.PSObject.Properties[$field]
                    if (-not $present) { continue }
                    $argv = $present.Value
                    # (An empty array would make "$null -ne $argv" false, so presence is checked instead.)
                    if (($argv -isnot [System.Collections.IList] -or -not @($argv).Count -or
                            @($argv | Where-Object { $_ -isnot [string] -or -not $_ }).Count)) {
                        "roles.$($r.Name).$field must be a non-empty array of strings"
                    }
                }
                $scored = $r.Value.PSObject.Properties['directoriesScored']
                if ($scored -and $scored.Value -isnot [bool]) {
                    "roles.$($r.Name).directoriesScored must be a boolean"
                }
                $enter = $r.Value.PSObject.Properties['enter']
                if ($enter -and ($enter.Value -isnot [string] -or -not $enter.Value)) {
                    "roles.$($r.Name).enter must be a non-empty string"
                }
            }
        }
    }
}

function Get-DFAliasesSchemaError ($aliases, [string]$path) {
    <#
    .SYNOPSIS
        Schema errors in an aliases block; -path names it in the messages.
    #>
    # aliases (top level and in role blocks): name -> { command: string; args: [string] }
    if ($null -eq $aliases) { return }
    if ($aliases -isnot [pscustomobject]) { "$path must be an object keyed by alias name"; return }
    foreach ($a in $aliases.PSObject.Properties) {
        if ($a.Value -isnot [pscustomobject] -or (Get-DFSchemaProperty $a.Value 'command') -isnot [string] -or -not (Get-DFSchemaProperty $a.Value 'command')) {
            "$path.$($a.Name) must be an object with a string command"; continue
        }
        $args_ = $a.Value.PSObject.Properties['args']?.Value
        if ($null -ne $args_ -and @($args_ | Where-Object { $_ -isnot [string] }).Count) {
            "$path.$($a.Name).args must be strings"
        }
    }
}

function Get-DFMapSchemaError ($map, [string]$path, [switch]$StringsOnly) {
    <#
    .SYNOPSIS
        Schema errors in an env or themeMap block; -path names it in the messages.
    #>
    # env and themeMap: name -> plain value
    if ($null -eq $map) { return }
    if ($map -isnot [pscustomobject]) { "$path must be an object"; return }
    foreach ($p in $map.PSObject.Properties) {
        $v = $p.Value
        $ok = if ($StringsOnly) { $v -is [string] } else { $v -is [string] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [bool] }
        if (-not $ok) { "$path.$($p.Name) must be a $(if ($StringsOnly) { 'string' } else { 'string, number or boolean' })" }
    }
}

function Get-DFThemeSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in theme: key names a *Theme config key; default, files, fallback and command are strings; valid is strings; map and env map names to strings.
    #>
    $theme = Get-DFSchemaProperty $Tool 'theme'
    if ($null -eq $theme) { return }
    if ($theme -isnot [pscustomobject]) { return 'theme must be an object' }
    $key = Get-DFSchemaProperty $theme 'key'
    if ($key -isnot [string] -or $key -cnotmatch '^[A-Z][A-Za-z0-9]*Theme$') { "theme.key must name the tool's config key, e.g. 'BatTheme'" }
    foreach ($field in 'default', 'files', 'fallback', 'command', 'apply') {
        $v = $theme.PSObject.Properties[$field]?.Value   # read directly: a helper would unroll ["x"]
        if ($null -ne $v -and ($v -isnot [string] -or -not $v)) { "theme.$field must be a non-empty string" }
    }
    $valid = $theme.PSObject.Properties['valid']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $valid -and ($valid -isnot [array] -or @($valid | Where-Object { $_ -isnot [string] }).Count)) { 'theme.valid must be an array of strings' }
    $v = Get-DFSchemaProperty $theme 'map'; if ($null -ne $v) { Get-DFMapSchemaError $v 'theme.map' -StringsOnly }
    $v = Get-DFSchemaProperty $theme 'env'; if ($null -ne $v) { Get-DFMapSchemaError $v 'theme.env' -StringsOnly }
}

function Get-DFWrapperSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in wrapper: args is an array of strings and { ifFile?, unlessFile?, unlessArg?, args } groups; {theme} needs a theme that always has a value.
    #>
    $wrapper = Get-DFSchemaProperty $Tool 'wrapper'
    if ($null -eq $wrapper) { return }
    if ($wrapper -isnot [pscustomobject]) { return 'wrapper must be an object' }
    $custom = Get-DFSchemaProperty $wrapper 'custom'
    if ($null -ne $custom -and $custom -isnot [bool]) { 'wrapper.custom must be true or false' }
    $entries = $wrapper.PSObject.Properties['args']?.Value   # read directly: a helper would unroll ["x"]
    if ($entries -isnot [array]) { return 'wrapper.args must be an array' }
    $usesTheme = $false
    for ($n = 0; $n -lt $entries.Count; $n++) {
        $entry = $entries[$n]
        if ($entry -is [string]) { if ($entry.Contains('{theme}')) { $usesTheme = $true }; continue }
        $inner = if ($entry -is [pscustomobject]) { $entry.PSObject.Properties['args']?.Value }
        # Assigned directly: an if-expression would unroll a one-element unlessArg array.
        $ifFile = $entry.PSObject.Properties['ifFile']?.Value
        $unlessFile = $entry.PSObject.Properties['unlessFile']?.Value
        $unlessArg = $entry.PSObject.Properties['unlessArg']?.Value
        $badCondition = ($null -ne $ifFile -and ($ifFile -isnot [string] -or -not $ifFile)) -or
            ($null -ne $unlessFile -and ($unlessFile -isnot [string] -or -not $unlessFile)) -or
            ($null -ne $unlessArg -and ($unlessArg -isnot [array] -or @($unlessArg | Where-Object { $_ -isnot [string] -or -not $_ }).Count))
        $noCondition = $null -eq $ifFile -and $null -eq $unlessFile -and $null -eq $unlessArg
        if ($badCondition -or $noCondition -or $inner -isnot [array] -or @($inner | Where-Object { $_ -isnot [string] }).Count) {
            "wrapper.args[$n] must be a string or { ifFile?, unlessFile?, unlessArg?: [strings], args: [strings] } with at least one condition"; continue
        }
        if (@($inner | Where-Object { $_.Contains('{theme}') }).Count) { $usesTheme = $true }
    }
    if (-not $usesTheme) { return }
    $theme = Get-DFSchemaProperty $Tool 'theme'
    if ($null -eq $theme) { return 'wrapper.args uses {theme}, but the tool has no theme block' }
    $canReject = (Get-DFSchemaProperty $theme 'files') -or $theme.PSObject.Properties['valid']
    if ($canReject -and -not (Get-DFSchemaProperty $theme 'fallback')) {
        'wrapper.args uses {theme}, so theme needs a fallback (valid or files can reject a name)'
    }
}

function Get-DFAliasAndMapSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in aliases, env and themeMap, at the top level and in role blocks.
    #>
    $roles = Get-DFSchemaProperty $Tool 'roles'
    # Startup cost matters (this runs for every tool on every shell start), so the
    # checkers are only invoked when there is something to check.
    $v = Get-DFSchemaProperty $Tool 'aliases';  if ($null -ne $v -and ($v -isnot [pscustomobject] -or @($v.PSObject.Properties).Count)) { Get-DFAliasesSchemaError $v 'aliases' }
    $v = Get-DFSchemaProperty $Tool 'env';      if ($null -ne $v) { Get-DFMapSchemaError $v 'env' }
    $v = Get-DFSchemaProperty $Tool 'themeMap'; if ($null -ne $v) { Get-DFMapSchemaError $v 'themeMap' -StringsOnly }
    if ($roles -is [pscustomobject]) {
        foreach ($r in $roles.PSObject.Properties) {
            $v = Get-DFSchemaProperty $r.Value 'aliases'; if ($null -ne $v) { Get-DFAliasesSchemaError $v "roles.$($r.Name).aliases" }
            $v = Get-DFSchemaProperty $r.Value 'env';     if ($null -ne $v) { Get-DFMapSchemaError $v "roles.$($r.Name).env" }
            $v = Get-DFSchemaProperty $r.Value 'flags'
            if ($null -ne $v -and ($v -isnot [pscustomobject] -or @($v.PSObject.Properties | Where-Object {
                    $_.Value -isnot [array] -or @($_.Value | Where-Object { -not (Test-DFRoleFlagItem $_) }).Count }).Count)) {
                "roles.$($r.Name).flags must map words to arrays of strings or { ifFile, unlessFile, args } groups"
            }
        }
    }
}

function Get-DFOrderingSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in after, and the replaced dependsOn field.
    #>
    if ($Tool.PSObject.Properties['dependsOn']) {
        'dependsOn was replaced: use after (ordering only) or requires (the tool cannot work without it)'
    }
    $after = $Tool.PSObject.Properties['after']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $after -and ($after -isnot [array] -or @($after | Where-Object { $_ -isnot [string] -or -not (ConvertFrom-DFToolReference -Reference $_) }).Count)) {
        'after must be an array of tool names or role:<role> entries'
    }
}

function Get-DFSetupSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in setup, setup.seed and setup.notes.
    #>
    $setup = $Tool.PSObject.Properties['setup']?.Value
    if ($null -ne $setup) {
        $seed = $setup.PSObject.Properties['seed']?.Value
        if ($setup -isnot [pscustomobject]) {
            'setup must be an object'
        } elseif ($null -ne $seed -and ($seed -isnot [pscustomobject] -or @($seed.PSObject.Properties | Where-Object { $_.Value -isnot [string] -or -not $_.Value }).Count)) {
            'setup.seed must map destination paths to files under Tools/'
        }
        # Assigned directly: an if-statement's output would unroll a one-note array.
        $notes = $null
        if ($setup -is [pscustomobject]) { $notes = $setup.PSObject.Properties['notes']?.Value }
        if ($null -ne $notes) {
            $bad = $notes -isnot [array] -or @($notes | Where-Object {
                $note = $_
                $note -isnot [pscustomobject] -or -not ($note.PSObject.Properties['text']?.Value -is [string]) -or -not $note.text -or
                @('ifFile', 'unlessFile' | Where-Object { $null -ne $note.PSObject.Properties[$_]?.Value -and $note.$_ -isnot [string] }).Count
            }).Count
            if ($bad) { 'setup.notes must be an array of { text, ifFile?, unlessFile? } objects with string values' }
        }
    }
}

function Get-DFActivationSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in requires, prewarm and nerdFont.
    #>
    $requires = $Tool.PSObject.Properties['requires']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $requires -and ($requires -isnot [array] -or @($requires | Where-Object { $_ -isnot [string] -or -not (ConvertFrom-DFToolReference -Reference $_) }).Count)) {
        'requires must be an array of tool names or role:<role> entries'
    }
    $prewarm = Get-DFSchemaProperty $Tool 'prewarm'
    if ($null -ne $prewarm -and $prewarm -isnot [bool]) { 'prewarm must be a boolean (true/false, not a string)' }
    $nerdFont = Get-DFSchemaProperty $Tool 'nerdFont'
    if ($null -ne $nerdFont -and $nerdFont -ne 'required') { "nerdFont must be ""required"" (the tool only draws icons), not '$nerdFont'" }
}

function Get-DFInstallsSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in installs (one block or a list), install.prefer and install.avoid.
    #>
    # installs: a package manager's install recipe; install.prefer: this tool's preferred sources.
    $insRaw = $Tool.PSObject.Properties['installs']?.Value   # read directly: a helper would unroll [ ... ]
    if ($null -ne $insRaw) {
        $isList = $insRaw -is [array]
        $blocks = @($insRaw)
        for ($n = 0; $n -lt $blocks.Count; $n++) {
            $ins = $blocks[$n]
            $at = if ($isList) { "installs[$n]" } else { 'installs' }
            if ($ins -isnot [pscustomobject]) { "$at must be an object"; continue }
            if (-not ((Get-DFSchemaProperty $ins 'from') -is [string] -and (Get-DFSchemaProperty $ins 'from'))) { "$at.from must name the source this manager installs from" }
            $renamed = [bool]$ins.PSObject.Properties['command']
            if ($renamed) { "$at.command was renamed to $at.install" }
            $install = $ins.PSObject.Properties['install']?.Value   # read directly: a helper would unroll ["x"]
            $hasInstall = $null -ne $install
            $hasFn = $null -ne (Get-DFSchemaProperty $ins 'function')
            if ($hasInstall -eq $hasFn -and -not $renamed) { "$at needs exactly one of install or function" }
            if ($hasInstall -and $install -isnot [array]) { "$at.install must be an array (argv)" }
            foreach ($op in 'update', 'remove') {
                $value = $ins.PSObject.Properties[$op]?.Value
                if ($null -eq $value -or $value -is [array]) { continue }
                $isFunction = $value -is [pscustomobject] -and (Get-DFSchemaProperty $value 'function') -is [string]
                if (-not $isFunction) { "$at.$op must be an array (argv) or { function, args }" }
            }
            foreach ($op in 'list', 'outdated') {
                $value = $ins.PSObject.Properties[$op]?.Value
                if ($null -ne $value -and $value -isnot [string]) { "$at.$op must be a function name" }
            }
        }
    }
    $inst = Get-DFSchemaProperty $Tool 'install'
    if ($null -ne $inst) {
        $have = @((Get-DFSchemaProperty $Tool 'packages')?.PSObject.Properties.Name)
        $prefer = @($inst.PSObject.Properties['prefer']?.Value)
        $bad = @($prefer | Where-Object { $_ -and $_ -notin $have })
        if ($bad) { "install.prefer names sources the tool has no package for: $($bad -join ', ')" }
        $avoid = $inst.PSObject.Properties['avoid']?.Value
        if ($null -ne $avoid -and $avoid -isnot [pscustomobject]) { 'install.avoid must be an object: source -> why it is bad for this tool' }
        elseif ($null -ne $avoid) {
            foreach ($entry in $avoid.PSObject.Properties) {
                if ($entry.Value -isnot [string] -or -not $entry.Value) { "install.avoid.$($entry.Name) must be a reason (text)" }
            }
            $avoided = @($avoid.PSObject.Properties | ForEach-Object Name)
            $bad = @($avoided | Where-Object { $_ -notin $have })
            if ($bad) { "install.avoid names sources the tool has no package for: $($bad -join ', ')" }
            $both = @($avoided | Where-Object { $_ -in $prefer })
            if ($both) { "install.prefer and install.avoid both name: $($both -join ', ')" }
        }
    }
}

function Get-DFPickerSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in picker, including action and parse code that does not compile.
    #>
    # picker: null, "custom" (the companion defines its own), a declarative object, or a list of them.
    # Read directly: a function's output would unroll a one-element list into its object.
    $picker = $Tool.PSObject.Properties['picker']?.Value
    if ($null -eq $picker) { return }
    $shape = 'picker must be null, "custom", an object or a list of objects'
    if ($picker -is [string]) {
        if ($picker -ne 'custom') { "$shape (got ""$picker"")" }
        return
    }
    $isList = $picker -is [System.Collections.IList]
    if (-not $isList -and $picker -isnot [pscustomobject]) { return $shape }
    $entries = @($picker)
    for ($n = 0; $n -lt $entries.Count; $n++) {
        $prefix = if ($isList) { "picker[$n]" } else { 'picker' }
        if ($entries[$n] -isnot [pscustomobject]) { "$prefix must be an object"; continue }
        Get-DFPickerEntryError -Picker $entries[$n] -Prefix $prefix
    }
}

function Get-DFPickerEntryError ([PSCustomObject]$Picker, [string]$Prefix) {
    <#
    .SYNOPSIS
        Schema errors in one declarative picker, each starting with Prefix (picker or picker[n]).
    #>
    foreach ($req in 'function', 'list') {
        $v = Get-DFSchemaProperty $Picker $req
        if ($v -isnot [string] -or -not $v) { "$Prefix.$req is required (a string)" }
    }
    foreach ($b in 'ansi', 'list_accepts_path') {
        $v = Get-DFSchemaProperty $Picker $b
        if ($null -ne $v -and $v -isnot [bool]) { "$Prefix.$b must be a boolean (true/false, not a string)" }
    }
    # These become scriptblocks when the picker is built; catch a syntax error
    # here, at load, instead of when the profile runs.
    $action = Get-DFSchemaProperty $Picker 'action'
    if ($action -is [string] -and $action -and $action -ne 'output') {
        try { $null = [scriptblock]::Create('param($v) ' + $action.Replace('{}', '$v')) }
        catch { "$Prefix.action is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
    }
    $parse = Get-DFSchemaProperty $Picker 'parse'
    if ($parse -is [string] -and $parse) {
        try { $null = [scriptblock]::Create($parse) }
        catch { "$Prefix.parse is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
    }
}

function Get-DFBannerSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in banner: a .banner.ps1 script, a boolean body, and placeholder names for fills.
    #>
    $banner = Get-DFSchemaProperty $Tool 'banner'
    if ($null -eq $banner) { return }
    if ($banner -isnot [pscustomobject]) { return 'banner must be an object' }
    $script = Get-DFSchemaProperty $banner 'script'
    if ($script -isnot [string] -or $script -notmatch '^[\w.-]+\.banner\.ps1$') { 'banner.script must name a <file>.banner.ps1 next to the record' }
    $body = Get-DFSchemaProperty $banner 'body'
    if ($null -ne $body -and $body -isnot [bool]) { 'banner.body must be true or false' }
    foreach ($fill in @(Get-DFSchemaProperty $banner 'fills')) {
        if ($null -ne $fill -and ($fill -isnot [string] -or $fill -notmatch '^[\w-]+$')) { "banner.fills entry '$fill' must be a placeholder name (letters, digits, _ or -)" }
    }
}

function Get-DFNativeSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in xdg.native: each key names something DotForge relocates; move is a boolean; move false needs a guide.
    #>
    $xdg = Get-DFSchemaProperty $Tool 'xdg'
    $native = Get-DFSchemaProperty $xdg 'native'
    if ($null -eq $native) { return }
    if ($native -isnot [pscustomobject]) { return 'xdg.native must be an object' }
    $vars = @((Get-DFSchemaProperty $xdg 'vars')?.PSObject.Properties.Name)
    $seeds = @((Get-DFSchemaProperty (Get-DFSchemaProperty $Tool 'setup') 'seed')?.PSObject.Properties.Name)
    foreach ($p in $native.PSObject.Properties) {
        if ($p.Name -cnotin $vars -and $p.Name -cnotin $seeds -and $p.Name -cnotmatch '^\$\{XDG_(CONFIG|DATA|STATE)_HOME\}') {
            "xdg.native key '$($p.Name)' must name an xdg.vars variable, a setup.seed target, or start with `${XDG_CONFIG_HOME}, `${XDG_DATA_HOME} or `${XDG_STATE_HOME}"
        }
        $entry = $p.Value
        if ($entry -is [pscustomobject]) {
            $move = Get-DFSchemaProperty $entry 'move'
            if ($null -ne $move -and $move -isnot [bool]) { "xdg.native.$($p.Name).move must be true or false" }
            $block = Get-DFSchemaProperty $entry 'block'
            if ($null -ne $block -and $block -isnot [bool]) { "xdg.native.$($p.Name).block must be true or false" }
            if ($move -eq $false -and -not (Get-DFSchemaProperty $entry 'guide')) { "xdg.native.$($p.Name) has move false, so it needs a guide" }
            if (@(Get-DFSchemaProperty $entry 'paths' | Where-Object { $_ -isnot [string] })) { "xdg.native.$($p.Name).paths must be strings" }
            $setting = Get-DFSchemaProperty $entry 'setting'
            if ($null -ne $setting -and $setting -isnot [string]) { "xdg.native.$($p.Name).setting must name a settings field" }
        } elseif (@($entry | Where-Object { $_ -isnot [string] })) { "xdg.native.$($p.Name) must be a list of paths or an object" }
    }
}

function Get-DFFieldTypoWarning ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Warnings for field names that look like misspellings of known fields.
    #>
    $picker = Get-DFSchemaProperty $Tool 'picker'
    $roles = Get-DFSchemaProperty $Tool 'roles'

    # Typo warnings. Unknown fields are allowed (tool authors may carry extra
    # data), so only a name that looks like a misspelling of a known one warns.
    $known = @{
        ''     = 'name', 'executable', 'type', 'description', 'tags', 'packages', 'xdg', 'env', 'aliases',
                 'picker', 'after', 'roles', 'themeMap', 'settings', 'executableExclude',
                 'prewarm', 'role', 'requires', 'setup', 'installs', 'install', 'banner', 'theme', 'wrapper', 'nerdFont'
        picker = 'function', 'alias', 'list', 'list_accepts_path', 'preview', 'preview_plain', 'preview_window', 'ansi',
                 'header', 'action', 'parse'
        xdg    = 'method', 'vars', 'dirs', 'instructions', 'compliance', 'native'
        setup  = 'seed'
        banner = 'script', 'body', 'fills'
        theme  = 'key', 'default', 'map', 'files', 'valid', 'fallback', 'env', 'command', 'apply'
        wrapper = 'args', 'custom'
        installs = 'from', 'install', 'update', 'remove', 'list', 'outdated', 'function', 'args', 'batch', 'elevate', 'reactivate', 'feeds'
        install = 'prefer', 'avoid'
        role   = 'priority', 'optIn', 'aliases', 'env', 'flags', 'directories', 'directoriesScored', 'enter', 'directoryScan'
    }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add(@('', $Tool, ''))
    $picker = $Tool.PSObject.Properties['picker']?.Value
    if ($picker -is [pscustomobject]) { $sections.Add(@('picker', $picker, 'picker.')) }
    elseif ($picker -is [System.Collections.IList]) {
        $entries = @($picker)
        for ($n = 0; $n -lt $entries.Count; $n++) {
            if ($entries[$n] -is [pscustomobject]) { $sections.Add(@('picker', $entries[$n], "picker[$n].")) }
        }
    }
    $xdg = Get-DFSchemaProperty $Tool 'xdg'
    if ($xdg -is [pscustomobject]) { $sections.Add(@('xdg', $xdg, 'xdg.')) }
    $setupObj = Get-DFSchemaProperty $Tool 'setup'
    if ($setupObj -is [pscustomobject]) { $sections.Add(@('setup', $setupObj, 'setup.')) }
    $bannerObj = Get-DFSchemaProperty $Tool 'banner'
    if ($bannerObj -is [pscustomobject]) { $sections.Add(@('banner', $bannerObj, 'banner.')) }
    $themeObj = Get-DFSchemaProperty $Tool 'theme'
    if ($themeObj -is [pscustomobject]) { $sections.Add(@('theme', $themeObj, 'theme.')) }
    $wrapperObj = Get-DFSchemaProperty $Tool 'wrapper'
    if ($wrapperObj -is [pscustomobject]) { $sections.Add(@('wrapper', $wrapperObj, 'wrapper.')) }
    foreach ($o in @($Tool.PSObject.Properties['installs']?.Value)) {
        if ($o -is [pscustomobject]) { $sections.Add(@('installs', $o, 'installs.')) }
    }
    $o = Get-DFSchemaProperty $Tool 'install'
    if ($o -is [pscustomobject]) { $sections.Add(@('install', $o, 'install.')) }
    if ($roles -is [pscustomobject]) {
        foreach ($r in $roles.PSObject.Properties) {
            if ($r.Value -is [pscustomobject]) { $sections.Add(@('role', $r.Value, "roles.$($r.Name).")) }
        }
    }
    foreach ($s in $sections) {
        $names = $known[$s[0]]
        foreach ($p in $s[1].PSObject.Properties) {
            if ($p.Name -cin $names) { continue }
            $suggestion = Get-DFFieldSuggestion -Name $p.Name -Known $names
            if ($suggestion) { "unknown field '$($s[2])$($p.Name)' — did you mean '$($s[2])$suggestion'?" }
        }
    }
}

function Test-DFToolSchema {
    <#
    .SYNOPSIS
        Validates a tool PSCustomObject against the DotForge tool schema.
        Returns a result object: Valid, Errors and Warnings.
    .DESCRIPTION
        Private validator for tool JSON records: required fields, enum values, and the
        shapes of picker, aliases, env, themeMap, theme, wrapper, after, requires, setup, prewarm, nerdFont and role blocks.
        Each section is checked by its own step; their error messages are collected, in
        order, into the result's Errors. Field names that look like misspellings of known
        fields go into Warnings: a tool with only warnings is still valid.
    .PARAMETER Tool
        The tool PSCustomObject to validate (typically parsed from JSON).
    .EXAMPLE
        $result = Test-DFToolSchema -Tool $record
        if (-not $result.Valid) { $result.Errors | Write-Warning }

        Validates a record and reports its violations.
    .OUTPUTS
        [pscustomobject] with Valid ([bool], $true when there are no errors), Errors
        ([string[]], the violation messages, empty when valid) and Warnings ([string[]],
        the likely misspelled field names).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )

    [string[]]$errs = @(
        Get-DFCoreFieldSchemaError $Tool
        Get-DFPackagesSchemaError $Tool
        Get-DFRolesSchemaError $Tool
        Get-DFAliasAndMapSchemaError $Tool
        Get-DFThemeSchemaError $Tool
        Get-DFWrapperSchemaError $Tool
        Get-DFOrderingSchemaError $Tool
        Get-DFSetupSchemaError $Tool
        Get-DFNativeSchemaError $Tool
        Get-DFBannerSchemaError $Tool
        Get-DFInstallsSchemaError $Tool
        Get-DFActivationSchemaError $Tool
        Get-DFPickerSchemaError $Tool
    )
    [string[]]$warns = @(Get-DFFieldTypoWarning $Tool)

    [pscustomobject]@{ Valid = $errs.Count -eq 0; Errors = $errs; Warnings = $warns }
}

function Get-DFFieldSuggestion {
    <#
    .SYNOPSIS
        Returns the known field name that -Name most likely misspells, or $null.
    .DESCRIPTION
        A case-insensitive match is a likely typo, as is an edit distance (insert,
        delete, substitute, swap two adjacent letters) of at most 1 for names of up
        to five letters and 2 for longer ones. Names unlike any known field return
        $null, so deliberate extra data never warns.
    .PARAMETER Name
        The unknown field name.
    .PARAMETER Known
        The valid names at that level.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Known)
    foreach ($k in $Known) { if ($k -ieq $Name) { return $k } }
    $a = $Name.ToLowerInvariant()
    $limit = if ($a.Length -le 5) { 1 } else { 2 }
    $best = $null; $bestDist = $limit + 1
    foreach ($k in $Known) {
        $b = $k.ToLowerInvariant()
        if ([Math]::Abs($a.Length - $b.Length) -gt $limit) { continue }
        # Optimal string alignment distance.
        $d = [int[,]]::new($a.Length + 1, $b.Length + 1)
        for ($i = 0; $i -le $a.Length; $i++) { $d[$i, 0] = $i }
        for ($j = 0; $j -le $b.Length; $j++) { $d[0, $j] = $j }
        for ($i = 1; $i -le $a.Length; $i++) {
            for ($j = 1; $j -le $b.Length; $j++) {
                $cost = [int]($a[$i - 1] -ne $b[$j - 1])
                $v = [Math]::Min([Math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $cost)
                if ($i -gt 1 -and $j -gt 1 -and $a[$i - 1] -eq $b[$j - 2] -and $a[$i - 2] -eq $b[$j - 1]) {
                    $v = [Math]::Min($v, $d[($i - 2), ($j - 2)] + 1)
                }
                $d[$i, $j] = $v
            }
        }
        if ($d[$a.Length, $b.Length] -lt $bestDist) { $bestDist = $d[$a.Length, $b.Length]; $best = $k }
    }
    $best
}

function Test-DFRoleFlagItem ([object]$Item) {
    <#
    .SYNOPSIS
        Whether one role flag item is valid: a string, or a group whose args is an array of strings and whose ifFile/unlessFile are strings.
    #>
    if ($Item -is [string]) { return $true }
    if ($Item -isnot [pscustomobject]) { return $false }
    $argsValue = $Item.PSObject.Properties['args']?.Value
    if ($argsValue -isnot [array] -or @($argsValue | Where-Object { $_ -isnot [string] }).Count) { return $false }
    foreach ($key in 'ifFile', 'unlessFile') {
        $v = $Item.PSObject.Properties[$key]?.Value
        if ($null -ne $v -and $v -isnot [string]) { return $false }
    }
    $true
}

# ---- Shared/Write-DFFileAtomic.ps1
#Requires -Version 7.2

function Write-DFFileAtomic {
    <#
    .SYNOPSIS
        Writes text to a file atomically: to a temp file beside it, then renamed over it.
    .DESCRIPTION
        Readers never see a half-written file, and two writers (an interactive
        session and Update-DFPackageCache, say) can't interleave: the last
        rename wins and both results are valid files. Creates the parent folder
        if needed. Used for every cache and state file DotForge writes.
    .PARAMETER Path
        The destination file.
    .PARAMETER Value
        The text to write (UTF-8).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    New-DFDirectory (Split-Path $Path -Parent)
    $tmp = "$Path.tmp.$PID"
    Set-Content -Path $tmp -Value $Value -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

# ---- Private/ConvertTo-DFColorOption.ps1
#Requires -Version 7.2

function ConvertTo-DFColorOption {
    <#
    .SYNOPSIS
        Builds a --color=name:value,... option from a theme file's "colors" object, skipping invalid entries.
    .DESCRIPTION
        fzf and skim share this grammar. The option becomes a raw token in
        FZF_DEFAULT_OPTS / SKIM_DEFAULT_OPTIONS, which the tool splits into
        options, so only the documented color grammar is accepted (hex, -1,
        0-255, default, or a color name, each optionally followed by :bold and
        similar); anything else is skipped with a warning, so a theme file can't
        inject an option such as --bind=execute(...).
    .PARAMETER Path
        The theme file.
    .PARAMETER Tool
        The tool name, for the warning.
    .OUTPUTS
        System.String, or $null when the file has no valid colors.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tool)
    $theme = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $colors = $theme.PSObject.Properties['colors']?.Value
    if (-not $colors) { return $null }
    $validKey   = '^[A-Za-z][A-Za-z0-9_-]*\+?$'
    $validValue = '^(#[0-9A-Fa-f]{3,8}|-1|[0-9]{1,3}|default|[A-Za-z]+(:(bold|underline|reverse|italic|dim|strikethrough))*)$'
    $pairs = @(foreach ($entry in $colors.PSObject.Properties) {
        if ($entry.Name -cmatch $validKey -and [string]$entry.Value -cmatch $validValue) {
            "$($entry.Name):$($entry.Value)"
        } else {
            Write-Warning "DotForge: invalid $Tool color entry '$($entry.Name)':'$($entry.Value)' — skipping"
        }
    })
    if ($pairs.Count -eq 0) { return $null }
    '--color=' + ($pairs -join ',')
}

# ---- Private/DFBanner.ps1
#Requires -Version 7.2

# The startup banner's coordinator (ShowBanner). Core never names a tool: parts
# come from requested, installed tools whose records have a banner field. A
# part script (Tools/<tool>.banner.ps1) is dot-sourced here, so its script
# blocks can call DotForge's private helpers; it outputs one object:
#   Style    { param($Context) }           -> @{ KeyColor; OutputColor; Separator } (optional)
#   Work     { param($Context) }           -> background jobs: @{ Name; ScriptBlock; ArgumentList }
#   Complete { param($Results, $Context) } -> @{ Body = lines or $null; Fills = @{ name = items } }
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

$script:DFBannerShown = $false
# Set when a Start-DFSession finishes: a later call in the same shell (say, one
# that turns ShowBanner on) never clears the screen of a shell already in use.
$script:DFSessionStarted = $false

function Test-DFBannerHost {
    <#
    .SYNOPSIS
        Whether the banner may print: an interactive console shell (not one started to run a command or script) whose output isn't redirected.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    (Test-DFInteractiveHost) -and -not [Console]::IsOutputRedirected -and (Test-DFReplStart)
}

function Test-DFReplStart {
    <#
    .SYNOPSIS
        Whether pwsh was started as an interactive shell, not to run a command or a script.
    .DESCRIPTION
        `pwsh -c ...`, `pwsh -File x.ps1`, `pwsh x.ps1` and `pwsh -EncodedCommand ...`
        run something and exit, so they get no banner (and don't clear the
        screen of the shell they were typed in), unless -NoExit keeps them
        open. Parameter names may be shortened, as pwsh allows.
    .PARAMETER CommandLine
        The process's arguments, the program first. Default: [Environment]::GetCommandLineArgs().
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$CommandLine = [Environment]::GetCommandLineArgs())
    $isPrefix = { param([string]$Arg, [string]$Name, [int]$Min) $Arg.Length -ge $Min -and $Name.StartsWith($Arg, [StringComparison]::OrdinalIgnoreCase) }
    $runs = $false
    $noExit = $false
    $skipValue = $false
    foreach ($arg in @($CommandLine | Select-Object -Skip 1)) {
        if ($skipValue) { $skipValue = $false; continue }
        if ($arg -notmatch '^[-/](.+)$') { $runs = $true; break }   # a script path
        $name = $Matches[1] -replace ':.*$', ''
        if (& $isPrefix $name 'noexit' 3) { $noExit = $true; continue }
        if ($name -ieq 'c' -or (& $isPrefix $name 'command' 3) -or $name -ieq 'f' -or (& $isPrefix $name 'file' 2) -or
            $name -ieq 'e' -or $name -ieq 'ec' -or (& $isPrefix $name 'encodedcommand' 3)) { $runs = $true; break }
        # Options that take a value: skip the value, so it isn't read as a script path.
        foreach ($valued in 'executionpolicy', 'ep', 'workingdirectory', 'wd', 'windowstyle', 'settingsfile', 'configurationname', 'custompipename', 'inputformat', 'outputformat') {
            if ($name -ieq $valued -or ($valued.Length -gt 3 -and (& $isPrefix $name $valued 3))) { $skipValue = $true; break }
        }
    }
    -not $runs -or $noExit
}

function Get-DFBannerCachePath {
    <#
    .SYNOPSIS
        The banner's last known fills: $XDG_CACHE_HOME\dotforge\banner.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath Cache) 'dotforge' 'banner.json'
}

function Start-DFBanner {
    <#
    .SYNOPSIS
        With ShowBanner on, clears the screen, prints the first line, and starts every banner part's background work.
    .DESCRIPTION
        Returns the state Show-DFBanner needs, or $null when the banner is
        off, the host isn't interactive, or it was already shown in this
        shell. Never throws.
    .PARAMETER Tools
        The requested tool names.
    .OUTPUTS
        pscustomobject (Parts, Style, Handle), or $null.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Tools)
    if (-not (Get-DFConfig ShowBanner -Default $false) -or $script:DFBannerShown -or $script:DFSessionStarted -or -not (Test-DFBannerHost)) { return }
    $script:DFBannerShown = $true
    try {
        if (Get-DFConfig BannerClear -Default $true) { Clear-Host }
        $parts = @(Get-DFBannerPart -Tools $Tools)
        $style = Get-DFBannerPartStyle -Parts $parts
        $module = $ExecutionContext.SessionState.Module
        $version = if ($module) { $module.Version }
        $firstLine = Format-DFBannerLine -Key 'DotForge' -Value "$(if ($version) { "$version · " })loading $(@($Tools).Count) tools…" -Style $style
        Write-DFBannerLines -Lines @($firstLine) -DelayMs 0
        $work = @(foreach ($part in @(Select-DFBannerWorkPart -Parts $parts)) {
            try { & $part.Script.Work $part.Context }
            catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed to start: $($_.Exception.Message)" }
        })
        [pscustomobject]@{ Parts = $parts; Style = $style; Handle = (Start-DFBannerWork -Work $work) }
    } catch {
        Write-Warning "DotForge: the banner failed to start: $($_.Exception.Message)"
    }
}

function Get-DFBannerPart {
    <#
    .SYNOPSIS
        Loads the banner parts of the requested, installed tools with a banner field; the body part first.
    .PARAMETER Tools
        The requested tool names.
    .OUTPUTS
        pscustomobject per part: Tool, Context, Script (Style, Work, Complete).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Tools)
    if (-not $Tools) { return }
    $db = Import-DFToolDb -Name $Tools 3>$null
    $shipped = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
    foreach ($tool in @($db.Values | Where-Object { $_.banner } | Sort-Object { -not $_.banner.body }, name)) {
        if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type)) { continue }
        $path = Join-Path (Get-DFToolFolder -Tool $tool -Default $shipped) $tool.banner.script
        try {
            $script = . $path
            [pscustomobject]@{ Tool = $tool; Context = [pscustomobject]@{ Tool = $tool }; Script = $script }
        } catch { Write-Warning "DotForge: banner part $($tool.name) didn't load: $($_.Exception.Message)" }
    }
}

function Select-DFBannerWorkPart {
    <#
    .SYNOPSIS
        The parts whose background work something will show: none without a body part; otherwise the body part and the parts filling a placeholder it uses.
    .DESCRIPTION
        A body part may say which placeholders its body has (Uses); without
        Uses every fill counts as used.
    .PARAMETER Parts
        Get-DFBannerPart result.
    .OUTPUTS
        The parts to start.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Parts)
    $body = @($Parts | Where-Object { $_.Tool.banner.body })
    if (-not $body) { return }
    $used = $null
    foreach ($part in $body) {
        if (-not $part.Script.PSObject.Properties['Uses']) { continue }
        try { $used = @($used) + @(& $part.Script.Uses $part.Context) | Where-Object { $_ } } catch { $used = $null; break }
    }
    foreach ($part in $Parts) {
        if ($part.Tool.banner.body -or $null -eq $used) { $part; continue }
        if (@($part.Tool.banner.fills | Where-Object { $_ -in $used })) { $part }
    }
}

function Set-DFBannerSessionStarted {
    <#
    .SYNOPSIS
        Records that this shell's first Start-DFSession has run, so no later call shows a banner.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $script:DFSessionStarted = $true
}

function Stop-DFBanner {
    <#
    .SYNOPSIS
        Lets the banner's background work end without showing it (the load failed or was stopped).
    .PARAMETER State
        Start-DFBanner result; $null does nothing.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param($State)
    if (-not $State -or -not $State.PSObject.Properties['Handle'] -or -not $State.Handle.Pool) { return }
    try { $null = $State.Handle.Pool.BeginClose($null, $null) } catch { Write-Verbose "DotForge: $($_.Exception.Message)" }
}

function ConvertTo-DFBannerFillItem {
    <#
    .SYNOPSIS
        The well-formed fill items (Key, Value, Alert) among what a part or the cache gave; the rest are dropped.
    .PARAMETER Items
        Candidate items.
    .OUTPUTS
        pscustomobject per item: Key, Value, Alert.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Items)
    foreach ($item in @($Items)) {
        $get = if ($item -is [System.Collections.IDictionary]) { { param($n) if ($item.Contains($n)) { $item[$n] } } }
               elseif ($item -is [psobject] -and $item -isnot [string] -and $item -isnot [ValueType]) { { param($n) $item.PSObject.Properties[$n]?.Value } }
               else { $null }
        if (-not $get) { continue }
        $value = & $get 'Value'
        if ($null -eq $value) { continue }
        [pscustomobject]@{ Key = (& $get 'Key'); Value = "$value"; Alert = [bool](& $get 'Alert') }
    }
}

function Get-DFBannerPartStyle {
    <#
    .SYNOPSIS
        The banner style from the first part that has one; plain otherwise.
    .PARAMETER Parts
        Get-DFBannerPart result.
    .OUTPUTS
        New-DFBannerStyle result.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Parts)
    foreach ($part in $Parts) {
        if (-not $part.Script.PSObject.Properties['Style']) { continue }
        try {
            $values = & $part.Script.Style $part.Context
            if ($values) { return New-DFBannerStyle @values }
        } catch { Write-Verbose "DotForge: banner part $($part.Tool.name) has no style: $($_.Exception.Message)" }
    }
    New-DFBannerStyle
}

function Show-DFBanner {
    <#
    .SYNOPSIS
        Collects the banner parts' results, fills placeholders (from the cache when a part isn't back in time), caches, and prints.
    .PARAMETER State
        Start-DFBanner result; $null does nothing.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param($State)
    if (-not $State) { return }
    try {
        $results = Receive-DFBannerWork -Handle $State.Handle -WaitMs (Get-DFConfig BannerWait -Default 300)
        $body = $null
        $fills = @{}
        foreach ($part in $State.Parts) {
            try {
                $done = & $part.Script.Complete $results $part.Context
                $doneBody = if ($done -is [psobject]) { $done.PSObject.Properties['Body']?.Value }
                $doneFills = if ($done -is [psobject]) { $done.PSObject.Properties['Fills']?.Value }
                if ($part.Tool.banner.body -and $doneBody) { $body = @($doneBody | ForEach-Object { "$_" }) }
                if ($doneFills -is [System.Collections.IDictionary]) {
                    foreach ($name in @($doneFills.Keys)) {
                        $items = @(ConvertTo-DFBannerFillItem -Items @($doneFills[$name]))
                        if ($items) { $fills[$name] = $items }
                    }
                }
            } catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed: $($_.Exception.Message)" }
        }
        $fills = Merge-DFBannerCache -Fills $fills -Names @($State.Parts | ForEach-Object { $_.Tool.banner.fills })
        if ($body) {
            Write-DFBannerLines -Lines @(Merge-DFBannerBody -Body $body -Fills $fills -Style $State.Style) -DelayMs (Get-DFConfig BannerLineDelay -Default 8)
        } else {
            $late = @($State.Parts | Where-Object { $_.Tool.banner.body } | ForEach-Object { $_.Tool.name })
            if ($late) {
                $wait = Get-DFConfig BannerWait -Default 300
                Write-DFBannerLines -Lines @(Format-DFBannerLine -Key 'DotForge' -Value "$($late -join ', ') wasn't ready within BannerWait ($wait ms); raise BannerWait or make it faster" -Style $State.Style) -DelayMs 0
            }
        }
    } catch {
        Write-Warning "DotForge: the banner failed: $($_.Exception.Message)"
    }
}

function Merge-DFBannerCache {
    <#
    .SYNOPSIS
        Saves fresh fills to the cache and fills the missing ones from it, marked "(cached)".
    .PARAMETER Fills
        Fresh fills.
    .PARAMETER Names
        Every fill name the loaded parts declare.
    .OUTPUTS
        System.Collections.Hashtable: name -> fill items.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Fills, [AllowEmptyCollection()][string[]]$Names)
    $cache = Read-DFBannerCache
    $all = @{}
    foreach ($name in $Fills.Keys) {
        $all[$name] = $Fills[$name]
        $cache[$name] = @{ at = [DateTime]::UtcNow.ToString('o'); items = @($Fills[$name]) }
    }
    foreach ($name in $Names) {
        if ($all.ContainsKey($name) -or -not $cache.ContainsKey($name)) { continue }
        $entry = $cache[$name]
        $cached = if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('items') -and $entry['items'] -is [System.Collections.IList]) { @(ConvertTo-DFBannerFillItem -Items @($entry['items'])) }
        if (-not $cached) { continue }
        $all[$name] = @(foreach ($item in $cached) { [pscustomobject]@{ Key = $item.Key; Value = "$($item.Value) (cached)"; Alert = $item.Alert } })
    }
    if ($Fills.Count) { Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value ($cache | ConvertTo-Json -Depth 6) }
    $all
}

function Complete-DFBannerBody {
    <#
    .SYNOPSIS
        Fills a body's @DF:<name>@ placeholders from the banner cache (values marked "(cached)") and removes the rest.
    .DESCRIPTION
        For a banner-style body printed outside the startup banner, such as
        fastfetch run by hand, so placeholder text never shows.
    .PARAMETER Body
        The lines.
    .PARAMETER StyleValues
        KeyColor, OutputColor and Separator for New-DFBannerStyle.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Body, [hashtable]$StyleValues = @{})
    $names = @(foreach ($line in $Body) { if ($line -match '@DF:([\w-]+)@') { $Matches[1] } })
    if (-not $names) { return $Body }
    $fills = Merge-DFBannerCache -Fills @{} -Names $names
    Merge-DFBannerBody -Body $Body -Fills $fills -Style (New-DFBannerStyle @StyleValues)
}

function Read-DFBannerCache {
    <#
    .SYNOPSIS
        The banner's cached fills (name -> @{ at; items }); empty when there are none or the file can't be read.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFBannerCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $cache = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($cache -is [System.Collections.IDictionary]) { return $cache }
    } catch { Write-Verbose "DotForge: the banner cache can't be read: $($_.Exception.Message)" }
    @{}
}

# ---- Private/DFBanner.Render.ps1
#Requires -Version 7.2

# Pure rendering for the startup banner (Private/DFBanner.ps1).
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

function ConvertTo-DFAnsiColor {
    <#
    .SYNOPSIS
        A fastfetch color (#rrggbb, or ANSI codes like "35") as an escape prefix; '' for anything else.
    .PARAMETER Color
        The color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Color)
    $e = [char]27
    if ($Color -match '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        return "$e[38;2;$([Convert]::ToInt32($Matches[1], 16));$([Convert]::ToInt32($Matches[2], 16));$([Convert]::ToInt32($Matches[3], 16))m"
    }
    if ($Color -match '^\d+(;\d+)*$') { return "$e[${Color}m" }
    # fastfetch's color names: the 8 standard colors, their bright_ forms, and default.
    $names = @{ black = 30; red = 31; green = 32; yellow = 33; blue = 34; magenta = 35; cyan = 36; white = 37; default = 39 }
    $name = "$Color".ToLowerInvariant()
    if ($names.ContainsKey($name)) { return "$e[$($names[$name])m" }
    if ($name -match '^bright_(\w+)$' -and $names.ContainsKey($Matches[1]) -and $Matches[1] -ne 'default') { return "$e[$($names[$Matches[1]] + 60)m" }
    ''
}

function New-DFBannerStyle {
    <#
    .SYNOPSIS
        The banner's colors and separator, as escape prefixes.
    .PARAMETER KeyColor
        Key color (fastfetch's display.color.keys).
    .PARAMETER OutputColor
        Value color (display.color.output).
    .PARAMETER Separator
        Text between key and value (display.separator).
    .OUTPUTS
        pscustomobject: Key, Output, Alert, Separator.
    #>
    [CmdletBinding()]
    param([string]$KeyColor, [string]$OutputColor, [string]$Separator = '  ')
    [pscustomobject]@{
        # Bold colored keys, as fastfetch prints them; no codes at all without a color.
        Key       = $(if ($keyColor = ConvertTo-DFAnsiColor $KeyColor) { "$([char]27)[1m$keyColor" } else { '' })
        Output    = ConvertTo-DFAnsiColor $OutputColor
        # catppuccin red: a failing drive line.
        Alert     = ConvertTo-DFAnsiColor '#f38ba8'
        Separator = $Separator
    }
}

function Format-DFBannerLine {
    <#
    .SYNOPSIS
        One banner line: colored key, separator, colored value.
    .PARAMETER Key
        The key.
    .PARAMETER Value
        The value.
    .PARAMETER Style
        New-DFBannerStyle result.
    .PARAMETER Alert
        Color the value with the alert color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Key, [AllowEmptyString()][string]$Value, [Parameter(Mandatory)]$Style, [switch]$Alert)
    $reset = "$([char]27)[0m"
    $paint = { param($prefix, $text) if ($prefix) { "$prefix$text$reset" } else { $text } }
    $valueColor = if ($Alert) { $Style.Alert } else { $Style.Output }
    "$(& $paint $Style.Key $Key)$($Style.Separator)$(& $paint $valueColor $Value)"
}

function Merge-DFBannerBody {
    <#
    .SYNOPSIS
        Replaces each @DF:<name>@ placeholder line in the body with that name's fill lines, or removes it.
    .DESCRIPTION
        A fill item has Key, Value and Alert; a $null Key takes the
        placeholder line's own key (its text before the separator, colors
        stripped). A name with no fill removes its line, so placeholder text
        never shows.
    .PARAMETER Body
        The body lines (fastfetch's output).
    .PARAMETER Fills
        Name -> fill items.
    .PARAMETER Style
        New-DFBannerStyle result.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Body, [Parameter(Mandatory)][hashtable]$Fills, [Parameter(Mandatory)]$Style)
    $ansi = "$([char]27)\[[0-9;]*m"
    foreach ($line in $Body) {
        if ($line -notmatch '@DF:([\w-]+)@') { $line; continue }
        $name = $Matches[1]
        if (-not $Fills.ContainsKey($name)) { continue }
        $plain = $line -replace $ansi, ''
        $separatorAt = $plain.IndexOf($Style.Separator)
        $ownKey = if ($separatorAt -gt 0) { $plain.Substring(0, $separatorAt) } else { '' }
        foreach ($item in @($Fills[$name])) {
            $key = if ($null -ne $item.Key) { $item.Key } else { $ownKey }
            Format-DFBannerLine -Key $key -Value $item.Value -Style $Style -Alert:([bool]$item.Alert)
        }
    }
}

function Write-DFBannerLines {
    <#
    .SYNOPSIS
        Prints banner lines one at a time, like a printer.
    .PARAMETER Lines
        The lines.
    .PARAMETER DelayMs
        Pause between lines; 0 prints at once.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Lines, [int]$DelayMs)
    # A console that isn't UTF-8 shows the banner's ·, ° and … as garbage.
    $plain = [Console]::OutputEncoding.CodePage -ne 65001
    $first = $true
    foreach ($line in $Lines) {
        if (-not $first -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        if ($plain) { $line = $line.Replace('·', '-').Replace('°', '').Replace('…', '...') }
        [Console]::WriteLine($line)
        $first = $false
    }
}

# ---- Private/DFBanner.Work.ps1
#Requires -Version 7.2

# The startup banner's background jobs: one runspace pool, started before tools
# load and collected when Start-DFSession ends. A runspace pool needs no module
# import (ThreadJob would add to startup). See
# docs/superpowers/specs/2026-10-11-startup-banner-design.md.

function Start-DFBannerWork {
    <#
    .SYNOPSIS
        Starts the banner parts' background jobs in one runspace pool, so they run while tools load.
    .PARAMETER Work
        Items with Name, ScriptBlock and ArgumentList, and optionally Partial
        ($true: what the job has output so far is used when it isn't done in
        time). A script block runs in a fresh runspace: it sees its arguments,
        not the caller's variables.
    .OUTPUTS
        A handle for Receive-DFBannerWork.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Work)
    $count = @($Work).Count
    if (-not $count) { return [pscustomobject]@{ Pool = $null; Jobs = @() } }
    $pool = [runspacefactory]::CreateRunspacePool(1, $count)
    $pool.Open()
    $jobs = foreach ($item in $Work) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        $null = $shell.AddScript($item.ScriptBlock.ToString())
        foreach ($argument in @($item.ArgumentList)) { $null = $shell.AddArgument($argument) }
        $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $partial = [bool]($item -is [System.Collections.IDictionary] -and $item['Partial'])
        [pscustomobject]@{
            Name = $item.Name; PowerShell = $shell; Output = $output; Partial = $partial
            Async = $shell.BeginInvoke([System.Management.Automation.PSDataCollection[psobject]]$null, $output)
        }
    }
    [pscustomobject]@{ Pool = $pool; Jobs = @($jobs) }
}

function Receive-DFBannerWork {
    <#
    .SYNOPSIS
        Collects the background jobs that finish within WaitMs; stops the rest without waiting for them.
    .PARAMETER Handle
        Start-DFBannerWork result.
    .PARAMETER WaitMs
        Longest total wait.
    .OUTPUTS
        System.Collections.Hashtable: job name -> its output. A job that threw
        is left out; so is one not done in time, unless it is marked Partial
        and has output something.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Handle, [int]$WaitMs)
    $results = @{}
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    foreach ($job in $Handle.Jobs) {
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($job.Async.AsyncWaitHandle.WaitOne($left)) {
            try {
                $job.PowerShell.EndInvoke($job.Async) | Out-Null
                if ($job.PowerShell.HadErrors) { Write-Verbose "DotForge: banner job $($job.Name) failed: $($job.PowerShell.Streams.Error | Select-Object -First 1)" }
                else { $results[$job.Name] = @($job.Output) }
            } catch {
                Write-Verbose "DotForge: banner job $($job.Name) failed: $($_.Exception.Message)"
            }
            $job.PowerShell.Dispose()
        } else {
            # Not done: keep what a Partial job has output so far, and leave the
            # job running (it stops itself; see the part). Never wait for it here.
            if ($job.Partial -and $job.Output.Count) { $results[$job.Name] = @($job.Output.ReadAll()) }
        }
    }
    # Closing the pool lets unfinished jobs end on their own; it never blocks here.
    if ($Handle.Pool) { $null = $Handle.Pool.BeginClose($null, $null) }
    $results
}

# ---- Private/DFCdFile.ps1
#Requires -Version 7.2

# Navigators that browse folders and, when you quit, write where you ended up to
# a file (broot's --outcmd, a file manager's cwd file). DotForge reads only the
# folder from that file and moves the shell there itself; it never runs the
# file. Design: docs/superpowers/specs/2026-10-17-directory-jump-design.md.

function ConvertFrom-DFShellCdLine {
    <#
    .SYNOPSIS
        Reads the folder from one POSIX-quoted cd line (cd 'C:\a b', with ' written as '"'"'); nothing else.
    .DESCRIPTION
        Accepts exactly one line of the form cd '<path>', where a single quote
        inside the path is written '"'"' as a POSIX shell would. Anything else
        (more lines, more words, another command, an unterminated quote)
        returns nothing, so the file's content is never treated as code.
    .PARAMETER Text
        The file's content.
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $line = $Text.TrimEnd("`r", "`n")
    if ($line -cnotmatch "^cd ((?:'[^']*'|`"'`")+)$") { return }
    $quoted = $Matches[1]
    $path = -join @([regex]::Matches($quoted, "'([^']*)'|`"'`"") | ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } else { "'" }
        })
    if ($path) { $path }
}

function Invoke-DFCdFileCommand {
    <#
    .SYNOPSIS
        Runs a navigator that writes the folder you quit in to a file, then moves the shell there.
    .DESCRIPTION
        {file} in -Arguments is replaced by a new temporary file. After the
        navigator exits with 0, the file is read as -Format ShellCd (one
        POSIX-quoted cd line, ConvertFrom-DFShellCdLine) or Path (the folder on
        its first line), and the shell moves there through Enter-DFDirectory.
        The file is always removed; its content is never run.
    .PARAMETER Executable
        The navigator.
    .PARAMETER Arguments
        Its arguments, with {file} where the cd file goes.
    .PARAMETER Format
        ShellCd or Path.
    .PARAMETER Run
        Runs the navigator and returns its exit code; for tests. Default: call it in this console.
    .OUTPUTS
        System.Boolean. Whether the shell moved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [ValidateSet('ShellCd', 'Path')][string]$Format = 'Path',
        [scriptblock]$Run = { param($Executable, $Arguments) & $Executable @Arguments; $LASTEXITCODE }
    )
    $file = New-TemporaryFile
    try {
        $argv = [string[]]@($Arguments | ForEach-Object { ([string]$_).Replace('{file}', $file.FullName) })
        $exitCode = & $Run $Executable $argv | Select-Object -Last 1
        if ($exitCode -ne 0) {
            Write-DFKeyMessage "DotForge: $([System.IO.Path]::GetFileName($Executable)) exited with code $exitCode"
            return $false
        }
        $text = [string](Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Ignore)
        $target = if ($Format -eq 'ShellCd') { ConvertFrom-DFShellCdLine -Text $text } else { ($text -split "`r?`n")[0].Trim() }
        if (-not $target) { return $false }
        Enter-DFDirectory -Path $target
    } finally {
        Remove-Item -LiteralPath $file.FullName -ErrorAction Ignore
    }
}

# ---- Private/DFDirectoryJump.ps1
#Requires -Version 7.2

# Alt+C (directory-jump): the folder list a picker shows, and the move to the
# picked folder. The sources are what the session's tools declare in their role
# blocks (navigation: directories, enter; file-search: directoryScan), so nothing
# here names a tool. Design: docs/superpowers/specs/2026-10-17-directory-jump-design.md.

function Get-DFDirectoryJumpCandidate {
    <#
    .SYNOPSIS
        Streams the folders Alt+C offers: ranked folders first, then a breadth-first scan of the current folder.
    .DESCRIPTION
        First the navigation winner's ranked folders (its "directories"
        command), shown as full paths and marked Ranked: those scoring at least
        DirectoryJumpMinScore (default 3) when the tool declares scores
        (directoriesScored), at most DirectoryJumpRanked (default 10). Then the folders under
        the current folder, one depth at a time up to -Depth, shown relative to
        it: through the file-search tool's "directoryScan" command when one is
        declared, else Get-ChildItem (hidden folders skipped). A folder already
        listed is not listed again (full path, case-insensitive). Items are
        written as they are found, so a picker can show them before the scan
        ends. Outside the file system only the ranked folders are listed.
    .PARAMETER Depth
        How deep to scan. Default: the DirectoryJumpDepth setting, else 6.
    .PARAMETER StopWhen
        Checked between folders, and every 100 ms while a scan command is
        silent; once it returns $true the list ends and a running scan process
        is stopped (the picker has closed).
    .OUTPUTS
        pscustomobject: Shown (the text to show), Path (the folder's full path), Ranked (from the ranked list).
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 64)][int]$Depth = (Get-DFConfig -Key DirectoryJumpDepth -Default 6), [scriptblock]$StopWhen = { $false })
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in Get-DFRankedDirectory -StopWhen $StopWhen) {
        if (& $StopWhen) { return }
        if ($seen.Add($path)) { [pscustomobject]@{ Shown = $path; Path = $path; Ranked = $true } }
    }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    # A pipeline, not foreach: foreach would collect the whole scan before the first folder.
    Get-DFScannedDirectory -Root $location.ProviderPath -Depth $Depth -StopWhen $StopWhen | ForEach-Object {
        if ($seen.Add($_.Path)) { [pscustomobject]@{ Shown = $_.Shown; Path = $_.Path; Ranked = $false } }
    }
}

function Invoke-DFStoppableCommand {
    <#
    .SYNOPSIS
        Runs an argv and writes its output lines as they come; a program is stopped once -StopWhen returns $true.
    .DESCRIPTION
        A program (an Application) runs as a process whose output is read line
        by line, checking -StopWhen between lines and every 100 ms while it is
        silent, and is killed when told to stop. Anything else (a function, as
        in tests) is called in the pipeline. Errors write a verbose message and
        end the output.
    .PARAMETER Argv
        The command and its arguments.
    .PARAMETER WorkingDirectory
        Where the program runs.
    .PARAMETER StopWhen
        The stop check.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Argv, [string]$WorkingDirectory, [scriptblock]$StopWhen = { $false })
    $application = Get-Command -Name $Argv[0] -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    # Splatted from a variable: an inline @(...) reaches a function as one argument.
    $rest = @($Argv | Select-Object -Skip 1)
    if (-not $application) {
        try { & $Argv[0] @rest 2>$null } catch { Write-Verbose "DotForge: Alt+C: '$($Argv[0])' failed: $($_.Exception.Message)" }
        return
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($application.Source)
    foreach ($argument in $rest) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try { $process = [System.Diagnostics.Process]::Start($startInfo) } catch { Write-Verbose "DotForge: Alt+C: couldn't start '$($Argv[0])': $($_.Exception.Message)"; return }
    try {
        $null = $process.StandardError.ReadToEndAsync()
        $next = $process.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($next.Wait(100)) {
                $line = $next.Result
                if ($null -eq $line) { break }
                $line
                $next = $process.StandardOutput.ReadLineAsync()
            }
            if (& $StopWhen) { break }
        }
    } finally {
        if (-not $process.HasExited) { try { $process.Kill($true) } catch { Write-Verbose "DotForge: Alt+C: couldn't stop '$($Argv[0])'" } }
        $process.Dispose()
    }
}

function Get-DFRankedDirectory {
    <#
    .SYNOPSIS
        The navigation winner's ranked folders (its declared "directories" command), as full paths; nothing on failure.
    .DESCRIPTION
        At most DirectoryJumpRanked (default 10), in the tool's order. When
        the tool declares directoriesScored, each line is "<score> <path>" and
        folders scoring below DirectoryJumpMinScore (default 3) are left out.
    .PARAMETER StopWhen
        The stop check (see Get-DFDirectoryJumpCandidate).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock]$StopWhen = { $false })
    $argv = @(Get-DFRoleDeclaration -Role navigation -Field directories)
    if (-not $argv.Count) { return }
    $scored = [bool](Get-DFRoleDeclaration -Role navigation -Field directoriesScored)
    $limit = Get-DFDirectoryJumpNumber -Key DirectoryJumpRanked -Default 10
    $minScore = Get-DFDirectoryJumpNumber -Key DirectoryJumpMinScore -Default 3
    Invoke-DFStoppableCommand -Argv $argv -StopWhen $StopWhen | ForEach-Object {
        $line = ([string]$_).Trim()
        if ($scored) {
            if ($line -notmatch '^(\d+(?:\.\d+)?)\s+(.+)$' -or [double]$Matches[1] -lt $minScore) { return }
            $line = $Matches[2]
        }
        # Canonical, so a root stays a root (C:\, not the drive-relative C:).
        if ($line -and [System.IO.Path]::IsPathRooted($line)) { ConvertTo-DFPath $line }
    } | Select-Object -First ([int]$limit)
}

function Get-DFDirectoryJumpNumber {
    <#
    .SYNOPSIS
        A numeric Alt+C setting, or its default when it's missing or isn't a non-negative number.
    .PARAMETER Key
        The setting.
    .PARAMETER Default
        Its default.
    .OUTPUTS
        System.Double.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][double]$Default)
    $value = Get-DFConfig -Key $Key -Default $Default
    $number = 0.0
    if ([double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge 0) { return $number }
    Write-Verbose "DotForge: $Key '$value' isn't a number of 0 or more; using $Default"
    $Default
}

function Get-DFScannedDirectory {
    <#
    .SYNOPSIS
        The folders under -Root, one depth at a time (all of depth 1, then 2, ...), as Shown/Path items.
    .PARAMETER Root
        The folder to scan (a file-system path).
    .PARAMETER Depth
        The deepest level to list.
    .PARAMETER StopWhen
        The stop check (see Get-DFDirectoryJumpCandidate).
    .OUTPUTS
        pscustomobject: Shown (relative to Root), Path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Depth, [scriptblock]$StopWhen = { $false })
    $scan = @(Get-DFRoleDeclaration -Role file-search -Field directoryScan)
    if ($scan.Count) {
        foreach ($level in 1..$Depth) {
            if (& $StopWhen) { return }
            $argv = @($scan | ForEach-Object { ([string]$_).Replace('{depth}', [string]$level) })
            Invoke-DFStoppableCommand -Argv $argv -WorkingDirectory $Root -StopWhen $StopWhen | ForEach-Object {
                $relative = ([string]$_).Trim().TrimEnd('\', '/')
                if ($relative) { [pscustomobject]@{ Shown = $relative; Path = (ConvertTo-DFPath (Join-Path $Root $relative)) } }
            }
        }
        return
    }
    $frontier = @(Get-Item -LiteralPath $Root)
    foreach ($level in 1..$Depth) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($parent in $frontier) {
            if (& $StopWhen) { return }
            foreach ($child in @(Get-ChildItem -LiteralPath $parent.FullName -Directory -ErrorAction Ignore)) {
                if ($child.Name.StartsWith('.') -or $child.Attributes.HasFlag([System.IO.FileAttributes]::Hidden)) { continue }
                $next.Add($child)
                [pscustomobject]@{ Shown = [System.IO.Path]::GetRelativePath($Root, $child.FullName); Path = $child.FullName }
            }
        }
        if (-not $next.Count) { return }
        $frontier = $next
    }
}

function Enter-DFDirectory {
    <#
    .SYNOPSIS
        Moves the shell to a folder: through the navigation winner's "enter" command, else Set-Location -LiteralPath.
    .DESCRIPTION
        The folder is passed as one argument value, never as command text. With
        zoxide that is its cd, so the folder also counts toward its ranking. A
        folder that no longer exists gets one line saying so.
    .PARAMETER Path
        The folder's full path.
    .OUTPUTS
        System.Boolean. Whether the shell moved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-DFKeyMessage "DotForge: $Path no longer exists"
        return $false
    }
    $enter = Get-DFRoleDeclaration -Role navigation -Field enter
    try {
        if ($enter) { & $enter $Path | Out-Null } else { Set-Location -LiteralPath $Path }
        $true
    } catch {
        Write-DFKeyMessage "DotForge: couldn't change to ${Path}: $($_.Exception.Message)"
        $false
    }
}

# ---- Private/DFInstallHost.ps1
#Requires -Version 7.2

function Test-DFElevated {
    <#
    .SYNOPSIS
        Whether this shell runs elevated (as administrator).
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return (id -u 2>$null) -eq '0' }
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-DFInstallChoice {
    <#
    .SYNOPSIS
        Asks one install question, showing the default; Enter keeps it.
    .PARAMETER Prompt
        The question.
    .PARAMETER Options
        The allowed answers.
    .PARAMETER Default
        The answer Enter gives.
    .OUTPUTS
        System.String. One of -Options.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string[]]$Options, [Parameter(Mandatory)][string]$Default)
    while ($true) {
        $a = Read-Host "$Prompt [$($Options -join '/')] (Enter = $Default)"
        if (-not $a) { return $Default }
        $hit = $Options | Where-Object { $_ -eq $a.Trim() } | Select-Object -First 1
        if ($hit) { return $hit }
        Write-Host "  Choose one of: $($Options -join ', ')"
    }
}

# ---- Private/DFNerdFont.ps1
#Requires -Version 7.2

# Whether icons are on: the NerdFont setting, else whether a Nerd Font is installed.
# Design: docs/superpowers/specs/2026-10-23-fonts-design.md.
# Whether a Nerd Font is installed, read once per session ($null: not read yet).
$script:DFNerdFontPresent = $null
$script:DFNerdFontNoticed = $false
# Whether a tool left its icons out this session (Test-DFIconsOn said no): only then does the load say so.
$script:DFIconsWithheld = $false

function Get-DFFontRegistryEntry {
    <#
    .SYNOPSIS
        The fonts registered for this user and for the machine whose names match a pattern, with their files.
    .DESCRIPTION
        Reads the HKCU and HKLM "Windows NT\CurrentVersion\Fonts" keys, HKCU first.
        A per-user value holds the font file's full path; a machine value holds a
        file name under $Env:windir\Fonts. Only these keys say what survives a
        reboot (fonts loaded with AddFontResource alone are gone after it). A
        machine can list hundreds of fonts, so names are filtered before anything
        else is read, and entries stream (a caller may stop at the first). Nothing
        off Windows.
    .PARAMETER Pattern
        A regex the value name must match.
    .OUTPUTS
        PSCustomObject { Name; Path }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pattern)
    if (-not $IsWindows) { return }
    $fontsDir = Join-Path $Env:windir 'Fonts'
    foreach ($hive in [Microsoft.Win32.Registry]::CurrentUser, [Microsoft.Win32.Registry]::LocalMachine) {
        $key = $hive.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\Fonts')
        if (-not $key) { continue }
        try {
            foreach ($name in @($key.GetValueNames()) -match $Pattern) {
                $value = [string]$key.GetValue($name)
                if (-not $value) { continue }
                $path = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $fontsDir $value }
                [pscustomobject]@{ Name = $name; Path = $path }
            }
        } finally { $key.Dispose() }
    }
}

function Get-DFNerdFontFace {
    <#
    .SYNOPSIS
        The faces of the installed Nerd Fonts whose files exist.
    .DESCRIPTION
        Only Nerd Font names (Test-DFNerdFontName) have their file checked, so a
        font deleted by hand without its registry value doesn't count.
    .PARAMETER First
        Stop at the first one: enough to know a Nerd Font is installed.
    .OUTPUTS
        System.String[]: distinct face names, e.g. "Hack Nerd Font".
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$First)
    # A cheap regex narrows the names before Test-DFNerdFontName decides. One pipeline,
    # so Select-Object -First stops the registry read at the first installed one.
    $installed = { (Test-DFNerdFontName -Name $_.Name) -and [IO.File]::Exists($_.Path) }
    $entries = if ($First) {
        Get-DFFontRegistryEntry -Pattern '(?i)nerd|nf' | Where-Object $installed | Select-Object -First 1
    } else {
        Get-DFFontRegistryEntry -Pattern '(?i)nerd|nf' | Where-Object $installed
    }
    [string[]]@($entries | ForEach-Object { ConvertTo-DFFontFaceName -Name $_.Name } | Select-Object -Unique)
}

function Test-DFNerdFontPresent {
    <#
    .SYNOPSIS
        True when a Nerd Font is installed, read once per session; always true off Windows, where DotForge can't tell.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $true }
    if ($null -eq $script:DFNerdFontPresent) { $script:DFNerdFontPresent = [bool]@(Get-DFNerdFontFace -First).Count }
    $script:DFNerdFontPresent
}
function Test-DFIconsOn {
    <#
    .SYNOPSIS
        True when tools may draw Nerd Font icons: the NerdFont setting, else whether a Nerd Font is installed.
    .DESCRIPTION
        The one place that decides it. Role words, picker previews and records
        marked nerdFont: "required" all follow it.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $setting = Get-DFConfig NerdFont
    if ($null -ne $setting) { return [bool]$setting }
    # Asked only where icons would be drawn, so a "no" means something was left out.
    $on = Test-DFNerdFontPresent
    if (-not $on) { $script:DFIconsWithheld = $true }
    $on
}

function Reset-DFIconsOn {
    <#
    .SYNOPSIS
        Forgets this session's Nerd Font detection, so the next check reads the registry again.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $script:DFNerdFontPresent = $null
    $script:DFNerdFontNoticed = $false
    $script:DFIconsWithheld = $false
}

function Get-DFNerdFontChange {
    <#
    .SYNOPSIS
        Whether a Nerd Font is installed now, and whether it appeared since the last load.
    .DESCRIPTION
        Compares with $XDG_STATE_HOME\dotforge\nerd-font.json ({ "present": bool }),
        written only when the answer changes. With no file yet, this load is the
        baseline: NewlyPresent is $false, so a user who already had a Nerd Font
        never hears about it.
    .OUTPUTS
        PSCustomObject { Present; Faces; NewlyPresent }.
    #>
    [CmdletBinding()]
    param()
    $present = Test-DFNerdFontPresent
    $stateFile = Join-Path (Get-DFXdgPath State) 'dotforge' 'nerd-font.json'
    $previous = $null
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { $previous = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).PSObject.Properties['present']?.Value } catch { $previous = $null }
    }
    if ($previous -ne $present) { Write-DFFileAtomic -Path $stateFile -Value (@{ present = $present } | ConvertTo-Json -Compress) }
    [pscustomobject]@{
        Present      = $present
        # The face names only when they are shown: listing them all costs more than detecting one.
        Faces        = if ($present -and $previous -eq $false) { [string[]]@(Get-DFNerdFontFace) } else { [string[]]@() }
        NewlyPresent = $present -and $previous -eq $false
    }
}

function Write-DFNerdFontNotice {
    <#
    .SYNOPSIS
        At the end of a load, says why icons are off, or names a Nerd Font that has just appeared.
    .DESCRIPTION
        Once per session, Windows only. While no Nerd Font is installed, NerdFont
        isn't set and a requested tool left its icons out, every load warns that
        icons are off and how to fix it. When a Nerd
        Font has appeared since the last load (Get-DFNerdFontChange), a one-time note
        says to select it in the terminal, which DotForge can't do or see.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $IsWindows -or $script:DFNerdFontNoticed) { return }
    $script:DFNerdFontNoticed = $true
    $change = Get-DFNerdFontChange
    if ($change.NewlyPresent) {
        # A text font to select: not the symbols-only one, and the plain build before Mono or Propo.
        $faces = @($change.Faces)
        $face = @($faces | Where-Object { $_ -notmatch 'Symbols' -and $_ -notmatch '\b(Mono|Propo|NFM|NFP)$' }) + @($faces | Where-Object { $_ -notmatch 'Symbols' }) + $faces | Select-Object -First 1
        Write-Host "DotForge: Nerd Font installed: $face. Select it as your terminal's font to see icons." -ForegroundColor Cyan
    }
    if (-not $change.Present -and $script:DFIconsWithheld -and $null -eq (Get-DFConfig NerdFont)) {
        Write-Warning 'DotForge: No Nerd Font installed, so icons are off. Run Install-DFNerdFont, or set NerdFont = $true if your terminal already has one.'
    }
}

# ---- Private/DFSessionConfig.ps1
#Requires -Version 7.2

# The session's configuration: the hashtable passed to Start-DFSession -Config,
# stored here once and read only through Get-DFConfig. Nothing reads a global
# $DFConfig. Before Start-DFSession runs (e.g. a script importing DotForge only
# for its helpers), every read returns its default.
$script:DFSessionConfig = @{}

# Every key DotForge or a companion reads. tests/DFSessionConfig.Tests.ps1 fails
# when code reads a key that is missing here. Value: a one-line description.
$script:DFConfigKeys = [ordered]@{
    Tools              = 'Tools and +groups to configure (Start-DFSession)'
    ExcludeTools       = 'Tools and +groups removed from Tools'
    Defaults           = 'Role -> preferred tool'
    Theme              = 'Shared theme name'
    SkipSetup          = 'Tools whose one-time setup never runs'
    SkipConflictCheck  = 'Skip the coreutils shadowing check'
    IgnoreConflicts    = 'Command names left out of the shadowing check'
    ShimsPath          = 'Folder New-DFShim writes to'
    InstallVia          = 'Tool -> source to install it from (beats everything, including IncludeSources and ExcludeSources)'
    InstallOrder        = 'Preferred source order for Install-DFTool (ordering only)'
    IncludeSources      = 'The only sources Install-DFTool uses, registries included (unless InstallVia names another)'
    ExcludeSources      = 'Sources Install-DFTool never uses (unless InstallVia names one)'
    NerdFont           = 'Icons: $true on, $false off; unset detects an installed Nerd Font (Windows)'
    ShowBanner         = 'Show the startup banner (fastfetch, drive health, public IP)'
    BannerLineDelay    = 'Milliseconds between banner lines; 0 prints at once'
    BannerWait         = 'Longest wait, in ms, for an unfinished banner part'
    BannerClear        = 'Clear the screen before the banner; $false keeps scrollback'
    BatTheme           = 'bat theme'
    DeltaTheme         = 'delta theme'
    EzaTheme           = 'eza theme (dates, sizes, permissions)'
    FzfTheme           = 'fzf theme'
    GlowTheme          = 'glow theme'
    LsdTheme           = 'lsd theme (dates, sizes, permissions)'
    GumTheme           = 'gum theme (GUM_* colors)'
    MdcatTheme         = 'mdcat theme'
    MdvTheme           = 'mdv theme'
    MoorTheme          = 'moor theme'
    OvTheme            = 'ov theme (passed with --config unless you have your own ov config)'
    SkimTheme          = 'skim theme'
    DirectoryJumpMinScore = 'lowest zoxide score Alt+C lists (default 3)'
    DirectoryJumpRanked = 'most ranked (zoxide) folders Alt+C lists (default 10)'
    DirectoryJumpDepth = 'how deep Alt+C scans below the current folder (default 6)'
    BrootTheme         = 'broot skin (a catppuccin flavor, or a skin file of your own)'
    StarshipTheme      = 'starship palette (a catppuccin flavor; applied to a copy of your starship.toml)'
    OhMyPoshTheme      = 'oh-my-posh theme (a catppuccin flavor; used when you have no config of your own)'
    ProcsTheme         = 'procs color theme (dark or light, from Theme)'
    BtopTheme          = 'btop catppuccin flavor named in the setup note (btop.conf is yours)'
    DufTheme           = 'duf theme (dark or light, from Theme)'
    BottomTheme        = 'bottom built-in theme (default, default-light, gruvbox, nord, ...; from Theme)'
    PecoTheme          = 'peco theme (seeded into its config.json once)'
    TelevisionTheme    = 'television theme (seeded into its config.toml once; edit ui.theme there to change it)'
    VividTheme         = 'vivid (LS_COLORS) theme'
    PSReadLineTheme    = 'PSReadLine theme'
    PSReadLineEditMode = 'PSReadLine edit mode'
    DotenvSafeMode     = 'ps-dotenv safe mode'
    DotenvApprovedDirs = 'Folders ps-dotenv may load .env files from'
}

# Keys that existed before and what replaced them.
$script:DFRemovedConfigKeys = @{
    PackageManagerOrder = 'use InstallOrder (sources, ordering only) and ExcludeSources'
    SkipTools      = 'list the tools you want in Tools, and unwanted members of a +group in ExcludeTools'
    CompletionMode = "set Defaults['tab-completion'] = 'inshellisense' to use inshellisense"
}

function Set-DFSessionConfig {
    <#
    .SYNOPSIS
        Validates a configuration hashtable and stores a copy as the session's configuration.
    .DESCRIPTION
        Called by Start-DFSession. An unknown key warns, suggesting the known
        key it most likely misspells; a key that was removed warns with what
        replaced it. Warnings never stop the session. The stored copy is
        shallow: later changes to the caller's hashtable don't affect it.
    .PARAMETER Config
        The configuration passed to Start-DFSession -Config.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $known = [string[]]$script:DFConfigKeys.Keys
    foreach ($key in $Config.Keys) {
        if ($script:DFConfigKeys.Contains($key)) { continue }
        if ($script:DFRemovedConfigKeys.ContainsKey($key)) {
            Write-Warning "DotForge: config key '$key' was removed — $($script:DFRemovedConfigKeys[$key])."
            continue
        }
        $suggestion = Get-DFFieldSuggestion -Name $key -Known $known
        $hint = if ($suggestion) { " — did you mean '$suggestion'?" } else { ' (ignored)' }
        Write-Warning "DotForge: unknown config key '$key'$hint"
    }
    $script:DFSessionConfig = Copy-DFConfigValue $Config
    $script:DFSessionConfigured = $true
}

function Get-DFConfigFilePath {
    <#
    .SYNOPSIS
        Returns the path of the config file Start-DFSession reads without -Config.
    .DESCRIPTION
        $XDG_CONFIG_HOME/dotforge/config.psd1 (~/.config/dotforge/config.psd1
        when XDG_CONFIG_HOME is unset). The file needn't exist.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    param()
    ConvertTo-DFPath (Join-Path (Get-DFXdgPath Config) 'dotforge' 'config.psd1')
}

function Read-DFConfigFile {
    <#
    .SYNOPSIS
        Reads the config file, or returns an empty configuration with a warning when it is missing or unreadable.
    .DESCRIPTION
        The file is a PowerShell data file (Import-PowerShellDataFile): the same
        keys as Start-DFSession -Config, comments allowed, no code. A file that
        is missing, malformed or holds code warns, naming the file, and yields
        an empty configuration, so a typo never stops a shell from starting.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFConfigFilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Warning "DotForge: no config file at $path, so no tools are configured. Put your settings there (see Get-Help Start-DFSession)."
        return @{}
    }
    try {
        Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
    } catch {
        Write-Warning "DotForge: can't read $path, so no tools are configured: $($_.Exception.Message)"
        @{}
    }
}

function Copy-DFConfigValue {
    <#
    .SYNOPSIS
        Deep-copies a config value: dictionaries and lists are copied recursively, scalars returned as is.
    .DESCRIPTION
        The session snapshot must not share nested objects (the Defaults
        hashtable, list settings) with the caller's hashtable, or changing
        them after Start-DFSession would silently change the session.
    .PARAMETER Value
        The value to copy.
    .OUTPUTS
        System.Object. Dictionaries come back as hashtables, lists as object arrays.
    #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($k in $Value.Keys) { $copy[$k] = Copy-DFConfigValue $Value[$k] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , [object[]]@(foreach ($item in $Value) { Copy-DFConfigValue $item })
    }
    $Value
}

$script:DFSessionConfigured = $false
$script:DFLegacyConfigWarned = $false

function Assert-DFSessionConfigured {
    <#
    .SYNOPSIS
        Warns, once per session, when an old-style global $DFConfig exists but was never passed to Start-DFSession.
    .DESCRIPTION
        DotForge no longer reads a global $DFConfig. A profile that still sets
        one would otherwise lose its settings silently, including protective
        ones (SkipSetup keeps a tool's one-time setup from changing files such
        as your global git config; DotenvSafeMode and DotenvApprovedDirs limit
        which .env files load). Failing open silently is the wrong default, so
        this says so loudly. It only tests that the variable exists; it never
        reads its values.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if ($script:DFSessionConfigured -or $script:DFLegacyConfigWarned) { return }
    if (-not (Test-Path variable:global:DFConfig)) { return }
    $script:DFLegacyConfigWarned = $true
    Write-Warning ("DotForge: a global `$DFConfig was found but is no longer read, so none of its settings apply " +
        "(including SkipSetup, DotenvSafeMode and DotenvApprovedDirs). Pass it explicitly: Start-DFSession -Config `$DFConfig")
}

# ---- Private/DFSetupNote.ps1
#Requires -Version 7.2

# Setup notes: steps only the user can take. They are collected while a tool's
# one-time setup runs, recorded with its setup record by Complete-DFToolSetup,
# printed once at the end of the load and kept in Get-DFToolStatus.
# Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.
$script:DFPendingSetupNotes = @{}
$script:DFNewSetupNotes = [System.Collections.Generic.List[object]]::new()

function Add-DFToolSetupNote {
    <#
    .SYNOPSIS
        Adds a note for the user to a tool's running one-time setup.
    .DESCRIPTION
        A Tools/<name>.setup.ps1 calls it before Complete-DFToolSetup, which
        records the notes with the setup; they are printed once at the end of
        the load and stay in Get-DFToolStatus. A repeated note is kept once.
    .PARAMETER Name
        The tool name.
    .PARAMETER Text
        What the user should do.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
    if (-not $script:DFPendingSetupNotes.ContainsKey($Name)) { $script:DFPendingSetupNotes[$Name] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFPendingSetupNotes[$Name].Contains($Text)) { $script:DFPendingSetupNotes[$Name].Add($Text) }
}

function Add-DFDeclaredSetupNote {
    <#
    .SYNOPSIS
        Adds a tool's declared setup.notes whose file conditions hold now, before its seeds are copied.
    .DESCRIPTION
        A note's ifFile/unlessFile are read like a role flag group's
        (Resolve-DFRoleFlagGroup: {theme}, {settings.<name>}, ${XDG_*}), so
        "ifFile: the config file" means the user already had one. A file in
        -SeededPath was created by an earlier setup, so it doesn't count.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER SeededPath
        Files an earlier setup of this tool seeded (setup run again).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [AllowEmptyCollection()][string[]]$SeededPath = @())
    $setup = $Tool.setup
    if (-not $setup) { return }
    foreach ($note in @($setup.notes)) {
        if (-not $note) { continue }
        $ifFile = $note.PSObject.Properties['ifFile']?.Value
        # The second argument comes back as the expanded ifFile path ({file}).
        $group = [pscustomobject]@{
            ifFile     = $ifFile
            unlessFile = $note.PSObject.Properties['unlessFile']?.Value
            args       = @([string]$note.text, '{file}')
        }
        $resolved = @(Resolve-DFRoleFlagGroup -Group $group -Tool $Tool)
        if (-not $resolved.Count) { continue }
        if ($ifFile -and $resolved[1] -in $SeededPath) { continue }
        Add-DFToolSetupNote -Name $Tool.name -Text $resolved[0]
    }
}

function Get-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Returns the notes collected so far by a tool's running setup.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFPendingSetupNotes.ContainsKey($Name)) { [string[]]@($script:DFPendingSetupNotes[$Name]) }
}

function Clear-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Forgets a tool's collected notes (its setup failed, or they were recorded).
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $script:DFPendingSetupNotes.Remove($Name)
}

function Publish-DFSetupNote {
    <#
    .SYNOPSIS
        Moves a tool's recorded notes to this session's list to show at the end of the load.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($text in @(Get-DFPendingSetupNote -Name $Name)) { $script:DFNewSetupNotes.Add([pscustomobject]@{ Tool = $Name; Text = $text }) }
    Clear-DFPendingSetupNote -Name $Name
}

function Write-DFSetupNoteNotice {
    <#
    .SYNOPSIS
        Prints, once, the setup notes recorded since the last notice.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    foreach ($note in $script:DFNewSetupNotes) { Write-Host "DotForge: $($note.Tool): $($note.Text)" -ForegroundColor Cyan }
    $script:DFNewSetupNotes.Clear()
}

function Add-DFSetupNoteDetail {
    <#
    .SYNOPSIS
        Adds each tool's recorded setup notes to its status detail, once, when the status is read.
    .DESCRIPTION
        Reads the setup state only when Get-DFToolStatus runs, never at startup.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:DFSessionStatus) { return }
    $todo = @($script:DFSessionStatus.Values | Where-Object { -not $_.PSObject.Properties['SetupNoted'] })
    if (-not $todo) { return }
    $state = Get-DFToolSetupState
    foreach ($status in $todo) {
        $status | Add-Member -NotePropertyName SetupNoted -NotePropertyValue $true -Force
        $entry = $state.PSObject.Properties[$status.Name]?.Value
        $notes = if ($entry) { $entry.PSObject.Properties['notes']?.Value }
        foreach ($text in @($notes)) { if ($text) { Add-DFToolStatusDetail -Status $status -Text "setup note: $text" } }
    }
}

# ---- Private/DFToolNote.ps1
#Requires -Version 7.2

$script:DFToolNotes = @{}

function Add-DFToolNote {
    <#
    .SYNOPSIS
        Records a note for a tool's status (e.g. a role flag it lacks); a repeated note is kept once.
    .PARAMETER Tool
        The tool name.
    .PARAMETER Note
        The note.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Note)
    if (-not $script:DFToolNotes.ContainsKey($Tool)) { $script:DFToolNotes[$Tool] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFToolNotes[$Tool].Contains($Note)) { $script:DFToolNotes[$Tool].Add($Note) }
}

function Get-DFToolNote {
    <#
    .SYNOPSIS
        Returns a tool's status notes, in the order they were added.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    if ($script:DFToolNotes.ContainsKey($Tool)) { [string[]]@($script:DFToolNotes[$Tool]) }
}

function Clear-DFToolNote {
    <#
    .SYNOPSIS
        Forgets a tool's status notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    $script:DFToolNotes.Remove($Tool)
}

# ---- Private/Find-DFToolSource.ps1
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
        The Tools folder, for a record with no folder of its own; a loaded
        record's manage file is next to its JSON.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    $path = Join-Path (Get-DFToolFolder -Tool $Manager -Default $ToolsPath) "$($Manager.name).manage.ps1"
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
        order left out (IncludeSources, ExcludeSources), since a tool may have
        been installed through it before. Managers that aren't installed are skipped. The first
        manager whose list has the tool's id (or its feed-qualified id) wins,
        so a tool installed twice is reported under the first one found. A
        manager that declares no list (a version manager such as fnm) gets
        the tool only when no listing manager has it and the tool is installed.
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
    $unlisted = $null
    foreach ($source in $sources) {
        $ref = Get-DFPackageRef $Tool.packages.$source
        foreach ($manager in Get-DFSourceManager -Source $source -ToolDb $ToolDb) {
            if (-not (Test-DFToolAvailable -Executable $manager.executable -Type $manager.type)) { continue }
            $block = Get-DFInstallBlock -Manager $manager -Source $source
            if (-not $asked.Contains($manager.name)) { $asked.Add($manager.name) }
            if (-not $block.list) {
                if (-not $unlisted) { $unlisted = [pscustomobject]@{ Source = $source; Manager = $manager; Block = $block; Id = $ref.Id } }
                continue
            }
            Import-DFManagerOps -Manager $manager -ToolsPath $ToolsPath
            $ids = @($ref.Id) + @(if ($ref.Feed -and $block.feeds) { $block.feeds.id.Replace('{feed}', $ref.Feed.name).Replace('{id}', $ref.Id) })
            $row = Get-DFManagerInstalled -Manager $manager -Block $block -Cache $Cache | Where-Object { $_.Id -in $ids } | Select-Object -First 1
            if ($row) {
                return [pscustomobject]@{ Tool = $Tool.name; Source = $source; Manager = $manager; Block = $block; Id = $row.Id; Installed = $row.Installed; Detail = "via $($manager.name)" }
            }
        }
    }
    # A version manager (fnm, mise) can't list what it installed by the tool's
    # id (node's is "lts"), so an installed tool no listing manager claims is
    # credited to the first installed one, in precedence.
    if ($unlisted -and (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type)) {
        return [pscustomobject]@{ Tool = $Tool.name; Source = $unlisted.Source; Manager = $unlisted.Manager; Block = $unlisted.Block; Id = $unlisted.Id; Installed = $null; Detail = "via $($unlisted.Manager.name) (it can't list what it installed)" }
    }
    $detail = if (-not $sources) { 'its record lists no packages' } elseif ($asked.Count) { "not installed through any of: $($asked -join ', ')" } else { "no manager for $($sources -join ', ') is installed" }
    [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Id = $null; Installed = $null; Detail = $detail }
}

# ---- Private/Get-DFCachedCommandOutput.ps1
#Requires -Version 7.2

function Get-DFCachedCommandOutput {
    <#
    .SYNOPSIS
        Returns the cached stdout of a deterministic external command,
        regenerating only when the resolved executable itself has changed.
    .DESCRIPTION
        For companions like carapace/zoxide/mdcat/scoop-search whose init
        output is a pure function of the tool's own build -- verified
        byte-identical across repeated runs (see
        docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- with no
        session input to fingerprint on (unlike vivid's theme name, see
        Tools/vivid.ps1). The fingerprint is the resolved executable's path
        plus its LastWriteTimeUtc: a file stat, not a process spawn, so the
        cache-hit path never pays for a version check. A tool upgrade
        (which rewrites the file) or a switch to a differently-located
        binary both correctly invalidate the cache.

        Falls back to always calling -Generate, uncached, when
        -Executable does not resolve, or it
        resolves to something with no backing file (a function or alias
        stand-in, e.g. how tests/scoop.Tests.ps1 stubs scoop-search --
        Get-Command's .Source on a function is not a usable file path) --
        these companions register real functionality (completions, cd
        hooks), so degrading to "slower but correct" beats "skip it
        entirely" the way Tools/vivid.ps1's cosmetic LS_COLORS cache does.

        Never caches a falsy result (empty string or $null) -- a transient
        failure is retried next session rather than remembered.
    .PARAMETER Name
        Cache key, distinct per companion (e.g. 'carapace-init'). Backs the
        files $XDG_CACHE_HOME/dotforge/<Name>.txt and <Name>.key.
    .PARAMETER Executable
        The command name to resolve and fingerprint (e.g. 'carapace').
    .PARAMETER Generate
        Scriptblock producing the real output on a cache miss.
    .PARAMETER ExtraKey
        Optional text folded into the fingerprint, for output that also depends
        on something besides the executable (carapace's init also depends on the
        spec files in its specs folder). When it changes, the cache regenerates.
        Keep it cheap to compute: it runs on every call.
    .PARAMETER Force
        Bypass the cache and regenerate unconditionally.
    .EXAMPLE
        Get-DFCachedCommandOutput -Name 'carapace-init' -Executable 'carapace' -Generate {
            carapace _carapace powershell | Out-String
        }
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][scriptblock]$Generate,
        [string]$ExtraKey,
        [switch]$Force
    )

    $cmd = Get-Command $Executable -ErrorAction Ignore
    if (-not $cmd -or -not $cmd.Source -or -not (Test-Path $cmd.Source -PathType Leaf)) {
        return & $Generate
    }

    $target = Resolve-DFExecutableTarget -Path $cmd.Source
    $fingerprint = "$target|$((Get-Item $target).LastWriteTimeUtc.Ticks)"
    if ($ExtraKey) { $fingerprint += "|$ExtraKey" }
    Get-DFFingerprintCache -Name $Name -Fingerprint $fingerprint -Generate $Generate -Force:$Force
}

function Resolve-DFExecutableTarget {
    <#
    .SYNOPSIS
        Resolves a launcher (scoop shim or filesystem link) to the real
        executable it starts, so its file identity tracks tool upgrades.
    .DESCRIPTION
        A scoop shim (`shims\<name>.exe`) is a generic launcher that scoop
        never rewrites on upgrade -- the tool's identity lives in the sibling
        `<name>.shim` file's `path = "..."` line. Fingerprinting the shim
        itself would leave Get-DFCachedCommandOutput's cache stale across
        upgrades. Symlinks (e.g. winget's Links directory) are followed to
        their final target. Any failure -- unreadable or malformed shim,
        missing target -- degrades silently to the input path. Catalogued in
        docs/external-dependencies.md.
    .PARAMETER Path
        Absolute path of the resolved command (Get-Command's .Source).
    .EXAMPLE
        Resolve-DFExecutableTarget -Path (Get-Command carapace).Source
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $shim = [IO.Path]::ChangeExtension($Path, '.shim')
        if (Test-Path -LiteralPath $shim -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $shim) {
                if ($line -match '^\s*path\s*=\s*"?(.+?)"?\s*$') {
                    $target = ConvertTo-DFPath $Matches[1]
                    if (Test-Path -LiteralPath $target -PathType Leaf) { return $target }
                    break
                }
            }
            return $Path
        }
        $link = [IO.File]::ResolveLinkTarget($Path, $true)
        if ($link -and $link.Exists) { return $link.FullName }
    } catch {
        Write-Verbose "Resolve-DFExecutableTarget: falling back to '$Path': $_"
    }
    $Path
}

# ---- Private/Get-DFConfiguredTheme.ps1
#Requires -Version 7.2

function Get-DFConfiguredTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme name from the session config, honoring a per-tool key,
        then a shared 'Theme' key, then a caller default.
    .DESCRIPTION
        The fallback chain shared by every themed DotForge tool:
          1. Get-DFConfig $ToolKey   (e.g. 'GlowTheme', 'MdvTheme')
          2. Get-DFConfig Theme      (the cross-tool key)
          3. $Default                     (the tool's built-in default; may be $null)
        Family-name -> tool-dialect mapping (e.g. 'catppuccin' -> 'catppuccin-mocha')
        is deliberately NOT done here — it differs per tool and stays in each sidecar.
    .PARAMETER ToolKey
        The per-tool config key to check first (e.g. 'MdcatTheme').
    .PARAMETER Default
        Value returned when neither the per-tool key nor 'Theme' is set. Defaults to $null.
    .OUTPUTS
        [string] the resolved theme name, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolKey,
        [string]$Default
    )

    $perTool = Get-DFConfig $ToolKey
    if ($perTool) { return $perTool }
    $shared = Get-DFConfig Theme
    if ($shared) { return $shared }
    $Default
}

function Resolve-DFThemeFile {
    <#
    .SYNOPSIS
        Finds a tool's theme file: an absolute path, the user's themes folder, or the bundled copy.
    .DESCRIPTION
        Looks, in order, for -Name as an existing absolute path (file or folder);
        then <XDG config>\<Tool>\themes\<Name>.json or the folder <Name> there;
        then <BundledDir>\<Name>.json or the folder <BundledDir>\<Name>.
        Returns the first that exists, or $null. Used by the fzf, psreadline and
        glow companions, which capture it with ${function:Resolve-DFThemeFile}
        so their global functions can call it.
    .PARAMETER Tool
        The tool's folder name under XDG config (e.g. 'fzf').
    .PARAMETER Name
        A theme name or an absolute path to a theme file.
    .PARAMETER BundledDir
        The companion's bundled themes folder (e.g. Tools\fzf).
    .OUTPUTS
        System.String, or $null when nothing is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BundledDir
    )
    if ([System.IO.Path]::IsPathRooted($Name)) {
        return (Test-Path $Name) ? $Name : $null
    }
    # In each place a <Name>.json file, else a <Name> folder (for a tool that reads its theme from a folder).
    foreach ($dir in (Join-Path (Get-DFXdgPath Config) $Tool 'themes'), $BundledDir) {
        $file = Join-Path $dir "$Name.json"
        if (Test-Path $file -PathType Leaf) { return $file }
        $folder = Join-Path $dir $Name
        if (Test-Path $folder -PathType Container) { return $folder }
    }
    $null
}

# ---- Private/Get-DFCoreutilsShadowSet.ps1
#Requires -Version 7.2

function Get-DFCoreutilsShadowSet {
    <#
    .SYNOPSIS
        Returns the command names the coreutils readline hook rewrites in this host,
        or an empty array when no hook applies here.
    .PARAMETER ProfilePath
        Profile files to scan for a not-yet-loaded hook. Defaults to the two the
        coreutils installer targets. Tests pass an explicit path.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$ProfilePath)

    # Coreutils for Windows injects a PSConsoleHostReadLine override into a profile.
    # That hook rewrites matching command names to '<name>.cmd' BEFORE PowerShell
    # resolves them, so no alias, function, or -Force can win — the name is gone before
    # resolution starts. It also means Get-Command still reports DotForge's version, so
    # the conflict is invisible to normal probing.

    # 1. Authoritative: the hook has already run, so read the exact set it consults.
    #    O(1), in-memory, and true only where the hook actually loaded.
    $var = Get-Variable -Name '__COREUTILS__' -Scope Global -ErrorAction Ignore
    if ($var -and $var.Value) { return [string[]]@($var.Value) }

    # 2. The hook has not run YET. This is the normal case, not an edge case: profiles
    #    load CurrentUserAllHosts (where Start-DFSession typically lives) BEFORE
    #    CurrentUserCurrentHost (where the installer writes the hook). Relying on the
    #    variable alone makes this check dead code in a real profile.
    #
    #    Scanning $PROFILE.*CurrentHost keeps the host-accuracy that made the variable
    #    attractive: those paths are per-host, so a host the installer never touched
    #    (VS Code reads Microsoft.VSCode_profile.ps1) finds no marker and correctly
    #    reports no conflict. Reading the registry or shelling out to
    #    'coreutils-manager status' (~22ms) would report machine state instead and
    #    raise false conflicts in such hosts.
    if (-not $PSBoundParameters.ContainsKey('ProfilePath')) {
        $ProfilePath = @($PROFILE.CurrentUserCurrentHost, $PROFILE.AllUsersCurrentHost)
    }

    # Section marker written by the installer around its injected block.
    $marker = '60b36fc6-2d59-49df-be51-28dd2f4c3c9a'

    foreach ($path in @($ProfilePath | Where-Object { $_ })) {
        if (-not (Test-Path $path -PathType Leaf)) { continue }
        $text = Get-Content $path -Raw -ErrorAction Ignore
        if (-not $text -or $text -notmatch $marker) { continue }

        # Parse the enabled list out of the injected block. Do NOT match against the
        # hook function's own definition instead: the command array lives at profile
        # top level, outside PSConsoleHostReadLine, and the function body only holds
        # the 'ls'/'la' literals of its switch statement — matching there reports the
        # exact inverse of the truth.
        $m = [regex]::Match($text, "(?s)__COREUTILS__\s*=.*?@\((.*?)\)")
        if (-not $m.Success) { continue }

        $names = $m.Groups[1].Value -split ',' |
            ForEach-Object { $_.Trim().Trim("'", '"') } |
            Where-Object { $_ }
        if ($names) { return [string[]]@($names) }
    }

    # Nothing here recognises coreutils, or its generated shape changed. Either way the
    # conflict check silently disables itself — deliberate: this is a diagnostic, never
    # a correctness dependency.
    return @()
}

# ---- Private/Get-DFElevationMethod.ps1
#Requires -Version 7.2

function Test-DFWindowsSudoInline {
    <#
    .SYNOPSIS
        Whether Windows' built-in sudo is on in inline mode (Settings > System > For developers) and on PATH.
    .DESCRIPTION
        Windows' sudo is off until the user turns it on; only inline mode runs
        the command in this console, so its output can be read.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $enabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -Name Enabled -ErrorAction Ignore).Enabled
    $enabled -eq 3 -and [bool](Get-Command sudo.exe -CommandType Application -ErrorAction Ignore)
}

function Get-DFElevationMethod {
    <#
    .SYNOPSIS
        How a command that needs administrator rights gets them in this shell.
    .DESCRIPTION
        In order: the shell is already elevated (Direct); an elevator tool (the
        elevator role, e.g. gsudo) that is installed or installed earlier in the
        same plan (Elevator); Windows' sudo in inline mode (WindowsSudo); a
        separate administrator window through Start-Process -Verb RunAs (RunAs).
        The last two need a person to answer the admin prompt, so a
        non-interactive host gets Unavailable instead. An elevator is used
        even then, as installs always have.
    .PARAMETER ToolDb
        Name -> tool record; the elevator role's members come from it.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER Planned
        Tools installed earlier in the same plan.
    .OUTPUTS
        PSCustomObject: Method (Direct, Elevator, WindowsSudo, RunAs, Unavailable), Executable,
        Detail, and Tool (the elevator's name, for Elevator).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$ToolDb = @{},
        [scriptblock]$IsAvailable = { param($t) Test-DFToolAvailable -Executable $t.executable -Type $t.type },
        [string[]]$Planned = @()
    )
    $method = { param($name, $exe, $detail, $tool) [pscustomobject]@{ Method = $name; Executable = $exe; Detail = $detail; Tool = $tool } }
    if (Test-DFElevated) { return & $method 'Direct' $null 'already elevated' }
    $elevators = @(Get-DFRoleMember -Role 'elevator' -Tools @($ToolDb.Values))
    $elevator = @($elevators | Where-Object { & $IsAvailable $_ }) + @($elevators | Where-Object { $_.name -in $Planned }) | Select-Object -First 1
    if ($elevator) { return & $method 'Elevator' $elevator.executable "through $($elevator.name)" $elevator.name }
    if (-not (Test-DFInteractiveHost)) { return & $method 'Unavailable' $null 'no one to answer the admin prompt' }
    if (Test-DFWindowsSudoInline) { return & $method 'WindowsSudo' 'sudo' "through Windows' sudo" }
    & $method 'RunAs' $null 'in a separate administrator window (exit code only)'
}

# ---- Private/Get-DFGroupDb.ps1
#Requires -Version 7.2

function Get-DFGroupDb {
    <#
    .SYNOPSIS
        Loads the predefined tool groups (data/groups.json), cached for the session.
    .DESCRIPTION
        Groups are DotForge-owned lists users request as +name in
        Start-DFSession's Tools and ExcludeTools. They are curated data kept in
        one file, a deliberate exception to the plugin rule against central
        tool-keyed lists (docs/plugin-architecture.md). tests/Groups.Tests.ps1
        checks that members exist and that groups don't nest.
    .PARAMETER Path
        Read this file instead of the shipped one. Not cached.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary (case-insensitive):
        group name -> @{ Description; Tools }.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path -and $script:DFGroupDb) { return $script:DFGroupDb }
    $file = $Path ? $Path : (Join-Path $PSScriptRoot '..' 'data' 'groups.json')
    $db = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $raw = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($g in $raw.PSObject.Properties) {
        $db[$g.Name] = [pscustomobject]@{ Description = [string]$g.Value.description; Tools = [string[]]@($g.Value.tools) }
    }
    if (-not $Path) { $script:DFGroupDb = $db }
    $db
}

# ---- Private/Get-DFInstallEnvironment.ps1
#Requires -Version 7.2

function Get-DFInstallEnvironment {
    <#
    .SYNOPSIS
        Returns the location variables a package-manager command should see: its tools', its manager's, and those of the tools the manager requires.
    .DESCRIPTION
        An installer that reads a tool's location variables (rustup reads
        RUSTUP_HOME and CARGO_HOME) writes to its default folder unless they
        are set while it runs. The variables come, in this order, from:
          - each -Tool's xdg.vars (the tools being installed, updated or removed);
          - the -Manager's xdg.vars;
          - the xdg.vars of every tool the manager requires, following the
            chain (cargo -> rustup). Only tool references are followed: a
            role: requirement orders, it never names one tool. A name with no
            record is skipped.
        Only tools this session requested count, Active or Missing (not yet
        installed): those are the ones whose variables a session sets. A tool
        in Conflict keeps its data where the user has it, and one the session
        didn't request isn't relocated, so a cargo whose rustup lives in
        ~\.rustup isn't pointed at an empty folder. Without a session nothing
        is set. Only records whose xdg.method is env count, as at registration
        (Set-DFToolXdgConfig), and only xdg.vars: the env map holds flags and
        themes, which an installer doesn't need. When two sources name the
        same variable with different values, the later one wins (the manager
        and its runtimes run the command), with a verbose message.
        Invoke-DFManagerCommand -Environment applies the result.
    .PARAMETER Tool
        The tool records the command acts on; empty for a feed command.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER ToolDb
        Name -> tool record, for the manager's requires chain.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary: variable -> expanded value.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()][pscustomobject[]]$Tool = @(),
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [Parameter(Mandatory)][hashtable]$ToolDb
    )
    $sources = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($record in $Tool) { if ($record) { $sources.Add($record) } }
    $sources.Add($Manager)
    # The manager's requires chain, breadth first; the visited set ends a cycle.
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $visited.Add($Manager.name)
    $queue = [System.Collections.Generic.Queue[pscustomobject]]::new()
    $queue.Enqueue($Manager)
    while ($queue.Count) {
        foreach ($entry in @($queue.Dequeue().requires)) {
            $reference = ConvertFrom-DFToolReference -Reference $entry
            if (-not $reference -or $reference.Kind -ne 'Tool' -or -not $visited.Add($reference.Name)) { continue }
            $required = $ToolDb[$reference.Name]
            if (-not $required) { continue }
            $sources.Add($required)
            $queue.Enqueue($required)
        }
    }

    $environment = [ordered]@{}
    $from = @{}
    $status = $script:DFSessionStatus
    foreach ($source in $sources) {
        if ($source.xdg.method -ne 'env') { continue }
        if (-not ($status -and $status.Contains($source.name) -and $status[$source.name].State -in 'Active', 'Missing')) { continue }
        foreach ($var in @($source.xdg.vars?.PSObject.Properties)) {
            if (-not $var) { continue }
            $value = Expand-DFXdgPath $var.Value
            if ($environment.Contains($var.Name) -and $environment[$var.Name] -ne $value) {
                Write-Verbose "DotForge: $($var.Name) from $($source.name) ($value) replaces the one from $($from[$var.Name]) ($($environment[$var.Name])) for this command."
            }
            $environment[$var.Name] = $value
            $from[$var.Name] = $source.name
        }
    }
    $environment
}

# ---- Private/Get-DFRoleBehavior.ps1
#Requires -Version 7.2

function Resolve-DFRoleWords {
    <#
    .SYNOPSIS
        A won role's words as the winner's arguments; missing words are returned, not thrown.
    .PARAMETER Words
        The words, in the order their flags go.
    .PARAMETER Flags
        The winner's role block flags (word -> arguments, each a string or a
        { ifFile, unlessFile, args } group).
    .PARAMETER Tool
        The winner's tool record, for a group's {settings.<name>} and {theme}.
    .OUTPUTS
        pscustomobject { Args = [string[]]; Missing = [string[]] }.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Words, [AllowNull()][object]$Flags, [PSCustomObject]$Tool)
    $argList = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $Words) {
        $mapped = if ($Flags) { $Flags.PSObject.Properties[$word] }
        if (-not $mapped) { $missing.Add($word); continue }
        foreach ($item in @($mapped.Value)) {
            # A string first: -is [pscustomobject] is also true of a PSObject-wrapped string.
            if ($item -is [string]) { if ($item) { $argList.Add($item) } }
            elseif ($item -is [pscustomobject]) { foreach ($a in Resolve-DFRoleFlagGroup -Group $item -Tool $Tool) { $argList.Add($a) } }
        }
    }
    [pscustomobject]@{ Args = [string[]]$argList.ToArray(); Missing = [string[]]$missing.ToArray() }
}

function Select-DFRoleWord {
    <#
    .SYNOPSIS
        A role's words, without the ones that draw Nerd Font icons while icons are off.
    .DESCRIPTION
        The one place icon words are dropped (behaviors.nerdFontWords, Test-DFIconsOn).
        A dropped word is not a missing flag; the winner's status says icons are off.
    .PARAMETER Words
        The words of one alias, picker list or variable.
    .PARAMETER RoleDefinition
        The role record, with behaviors.
    .PARAMETER Tool
        The winner's tool record, for its status note.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()][string[]]$Words,
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $iconWords = @($RoleDefinition.behaviors.nerdFontWords)
    if (-not $iconWords.Count -or -not @($Words | Where-Object { $_ -in $iconWords }).Count -or (Test-DFIconsOn)) { return [string[]]@($Words) }
    Add-DFToolNote -Tool $Tool.name -Note 'icons off: no Nerd Font (see NerdFont)'
    [string[]]@($Words | Where-Object { $_ -notin $iconWords })
}

function Add-DFRoleMissingWordNote {
    <#
    .SYNOPSIS
        Notes, once per word, the role words a tool has no flag for, naming the aliases and pickers that use them.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Role
        The role name.
    .PARAMETER Missing
        Word -> names of the aliases or pickers that use it.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Missing
    )
    foreach ($word in $Missing.Keys) {
        Add-DFToolNote -Tool $Tool.name -Note "$Role`: no flag for '$word' ($(@($Missing[$word]) -join ', '))"
    }
}

function Get-DFRoleBehaviorAlias {
    <#
    .SYNOPSIS
        Builds a won role's aliases from the winner's flags.
    .DESCRIPTION
        Each alias the role's behaviors define runs the winner's executable (its file
        name without extension) with each word's flags, in the role's order. A word the
        winner doesn't map is left out and noted in the tool's status.
    .PARAMETER RoleDefinition
        The role record (Get-DFRoleDb), with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role (flags).
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject: alias name -> { command; args }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $aliases = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.aliases.Keys) {
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words $RoleDefinition.behaviors.aliases[$name] -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
        $aliases[$name] = [pscustomobject]@{ command = $command; args = $resolved.Args }
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    [pscustomobject]$aliases
}

function Get-DFRolePicker {
    <#
    .SYNOPSIS
        Builds a won role's pickers, with each list command made from the winner's flags.
    .DESCRIPTION
        Returns copies of the role's pickers whose list is "<executable> <flags>"; every
        other field (alias, function, preview, ...) is kept. A missing word is noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject[]: declarative pickers for Set-DFPickerFunction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $missing = [ordered]@{}
    $pickers = foreach ($picker in @($RoleDefinition.behaviors.pickers)) {
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words @($picker.list) -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $picker.alias | Where-Object { $_ }) }
        $copy = [ordered]@{}
        foreach ($p in $picker.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        # The list becomes PowerShell code (Set-DFPickerFunction), so each argument is a literal.
        $copy['list'] = (@($command) + @($resolved.Args | ForEach-Object { ConvertTo-DFPowerShellLiteral $_ })) -join ' '
        [pscustomobject]$copy
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    @($pickers)
}

function Resolve-DFRoleFlagGroup {
    <#
    .SYNOPSIS
        A conditional flag group's arguments: passed only while ifFile exists and unlessFile doesn't.
    .DESCRIPTION
        Paths expand {theme} (the tool's resolved theme value; none means the file is
        missing), then {settings.<name>} and ${XDG_*} (Expand-DFToolToken), and are
        canonical. {file} in args is the ifFile path.
    .PARAMETER Group
        { ifFile?, unlessFile?, args }.
    .PARAMETER Tool
        The tool record.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][PSCustomObject]$Group, [PSCustomObject]$Tool)
    $expand = {
        param([string]$Template)
        if (-not $Template) { return }
        if ($Template.Contains('{theme}')) {
            $theme = if ($Tool -and $Tool.theme) { (Get-DFToolTheme -Tool $Tool).Value }
            if (-not $theme) { return }
            $Template = $Template.Replace('{theme}', [string]$theme)
        }
        Expand-DFToolToken -Tool $Tool -Text $Template
    }
    $ifFile = $Group.PSObject.Properties['ifFile']?.Value
    $unlessFile = $Group.PSObject.Properties['unlessFile']?.Value
    $file = if ($ifFile) { & $expand $ifFile }
    if ($ifFile -and -not ($file -and (Test-Path -LiteralPath $file -PathType Leaf))) { return }
    if ($unlessFile) {
        # Fail closed: a guard path that can't be named can't be shown absent.
        $other = & $expand $unlessFile
        if (-not $other -or (Test-Path -LiteralPath $other -PathType Leaf)) { return }
    }
    # A path ends up inside a command line (PAGER, a picker's list): never let it carry shell syntax.
    if ($file -and $file -match '[`"$%\r\n]') {
        if ($Tool) { Add-DFToolNote -Tool $Tool.name -Note "skipped a flag group: unsafe characters in path '$file'" }
        return
    }
    [string[]]@(foreach ($arg in @($Group.args)) { if ($file) { ([string]$arg).Replace('{file}', $file) } else { [string]$arg } })
}

function Get-DFRoleBehaviorEnv {
    <#
    .SYNOPSIS
        Builds a won role's behavior variables: the winner's executable and each word's flags.
    .DESCRIPTION
        The executable is the ${DF_TOOL_EXE} token (ConvertTo-DFToolExePathToken: the
        winner's own build, quoted when it has a space). An argument holding a space is
        quoted, so a program that splits the variable keeps it whole. A missing word is
        noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.env.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary: variable -> command line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RoleDefinition,
        [Parameter(Mandatory)][PSCustomObject]$Block,
        [Parameter(Mandatory)][PSCustomObject]$Tool
    )
    $command = ConvertTo-DFToolExePathToken -Tool $Tool
    $values = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.env.Keys) {
        $resolved = Resolve-DFRoleWords -Words (Select-DFRoleWord -Words $RoleDefinition.behaviors.env[$name] -RoleDefinition $RoleDefinition -Tool $Tool) -Flags $Block.flags -Tool $Tool
        # git runs PAGER through sh, and bat/delta split it shell-style: a backslash is an escape
        # there, so paths use forward slashes (as ${DF_TOOL_EXE} does), and an argument with a
        # space or shell punctuation is double-quoted.
        $quoted = foreach ($a in $resolved.Args) {
            $a = $a.Replace('\', '/')
            if ($a -match '[\s;&|<>()''^*?\[#~]') { "`"$a`"" } else { $a }
        }
        $values[$name] = (@($command) + @($quoted)) -join ' '
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    $values
}
function ConvertTo-DFPowerShellLiteral {
    <#
    .SYNOPSIS
        An argument as PowerShell source: bare when plainly safe, else a single-quoted literal.
    .PARAMETER Value
        The argument.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '^[A-Za-z0-9_./:=+,@-]+$') { return $Value }
    "'" + $Value.Replace("'", "''") + "'"
}

# ---- Private/Get-DFRoleDb.ps1
#Requires -Version 7.2

$script:DFRoleDb = $null

function Get-DFRoleDb {
    <#
    .SYNOPSIS
        Loads the role definitions (data/roles.json) into a cached hashtable keyed by role name.
    .DESCRIPTION
        Each entry is normalized by ConvertTo-DFRoleRecord; invalid entries warn and
        are skipped. A missing or unreadable file warns once and yields an empty
        table, so every role feature degrades to a no-op.
    .PARAMETER Path
        Read this file instead of the shipped data/roles.json. Always uncached and
        never populates the cache.
    .PARAMETER Force
        Reload the shipped file, replacing the cache.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path,
        [switch]$Force
    )

    if (-not $Path -and -not $Force -and $null -ne $script:DFRoleDb) { return $script:DFRoleDb }

    $file = if ($Path) { $Path } else { Join-Path $PSScriptRoot '../data/roles.json' }
    $db = @{}
    try {
        $raw = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $raw.PSObject.Properties) {
            $record = ConvertTo-DFRoleRecord -Name $p.Name -Role $p.Value
            if ($record) { $db[$p.Name] = $record }
        }
    } catch {
        Write-Warning "DotForge: role definitions unavailable ($($_.Exception.Message)); roles are ignored."
    }

    if (-not $Path) { $script:DFRoleDb = $db }
    $db
}

function ConvertTo-DFRoleRecord {
    <#
    .SYNOPSIS
        Validates one role definition and returns it with every field present.
    .DESCRIPTION
        kind must be 'single' or 'category'. A single role needs a hook named
        Initialize-DFRole plus its name in PascalCase (project-env ->
        Initialize-DFRoleProjectEnv). A category role may not declare a hook, exclusive,
        reserved names, emptyMembership or behaviors. A single role's behaviors
        (words, aliases, pickers) may use only words it defines, and replace its
        reserved aliases with the behaviors' alias and picker names. Invalid entries
        warn and return nothing.
    .PARAMETER Name
        The role name (the key in roles.json).
    .PARAMETER Role
        The parsed definition.
    .OUTPUTS
        PSCustomObject, or nothing when invalid.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$Role
    )

    # Direct property reads (no helper scriptblock): this runs at every startup.
    $props = $Role.PSObject.Properties
    $reserved = $props['reserved']?.Value
    # Index the collection itself: assigning it from an if-expression would
    # enumerate it into a plain array, and string indexing would then find nothing.
    $resProps = ${reserved}?.PSObject.Properties
    # A role with behaviors derives its reserved aliases from them (its aliases and pickers).
    $behaviors = ConvertTo-DFRoleBehaviors -Behaviors $props['behaviors']?.Value
    $reservedAliases = [string[]]@(if ($null -ne $resProps) { $resProps['aliases']?.Value })
    if ($behaviors.Value) {
        $reservedAliases = [string[]]@(@($behaviors.Value.aliases.Keys) + @($behaviors.Value.pickers | ForEach-Object alias | Where-Object { $_ }))
    }
    # behaviors.env variables are the role's too.
    $reservedEnv = [string[]]@(if ($null -ne $resProps) { $resProps['env']?.Value })
    if ($behaviors.Value -and $behaviors.Value.env.Count) {
        $reservedEnv = [string[]]@(@($reservedEnv) + @($behaviors.Value.env.Keys) | Select-Object -Unique)
    }
    $fallback = $props['fallback']?.Value
    $record = [pscustomobject]@{
        name            = $Name
        kind            = $props['kind']?.Value
        exclusive       = [bool]$props['exclusive']?.Value
        hook            = $props['hook']?.Value
        emptyMembership = [bool]$props['emptyMembership']?.Value
        reserved        = [pscustomobject]@{
            env     = $reservedEnv
            aliases = $reservedAliases
            code    = [string[]]@(if ($null -ne $resProps) { $resProps['code']?.Value })
        }
        requires        = [string]$props['requires']?.Value
        description     = [string]$props['description']?.Value
        behaviors       = $behaviors.Value
        fallback        = $fallback
    }

    $problem = switch ($record.kind) {
        'single' {
            # The hook name is derived from the role name (project-env -> ProjectEnv),
            # so no two roles can share one and a sidecar's function serves one role.
            $pascal = -join ($Name -split '-' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
            $expected = "Initialize-DFRole$pascal"
            if ($record.hook -cne $expected) { "hook '$($record.hook)' must be $expected" }
            elseif ($behaviors.Problem) { $behaviors.Problem }
            elseif ($fallback) {
                $bad = @($fallback.PSObject.Properties['env']?.Value.PSObject.Properties | ForEach-Object Name | Where-Object { $_ -notin $reservedEnv })
                if ($bad) { "fallback sets $($bad -join ', '), which the role does not reserve" }
            }
        }
        'category' {
            if ($record.hook -or $record.emptyMembership -or $record.exclusive -or $record.behaviors -or $record.fallback -or
                $record.reserved.env.Count -or $record.reserved.aliases.Count -or $record.reserved.code.Count) {
                'a category role cannot declare a hook, exclusive, emptyMembership, behaviors, fallback or reserved names'
            }
        }
        default { "unknown kind '$($record.kind)' (expected single or category)" }
    }
    if ($problem) {
        Write-Warning "DotForge: role '$Name' is invalid and ignored: $problem."
        return
    }
    $record
}

function ConvertTo-DFRoleBehaviors {
    <#
    .SYNOPSIS
        Normalizes a role's behaviors block: words, aliases (name -> words), pickers (list as words), env and nerdFontWords.
    .DESCRIPTION
        Returns a Value of $null when the role has none. A problem (a word used but
        not defined) is returned as a string for ConvertTo-DFRoleRecord to report.
    .PARAMETER Behaviors
        The parsed behaviors object.
    .OUTPUTS
        pscustomobject { Value; Problem }.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Behaviors)
    if ($null -eq $Behaviors) { return [pscustomobject]@{ Value = $null; Problem = $null } }
    $words = [string[]]@($Behaviors.PSObject.Properties['words']?.Value.PSObject.Properties | ForEach-Object Name)
    $aliases = [ordered]@{}
    foreach ($alias in @($Behaviors.PSObject.Properties['aliases']?.Value.PSObject.Properties)) {
        if ($alias) { $aliases[$alias.Name] = [string[]]@($alias.Value) }
    }
    $pickers = @($Behaviors.PSObject.Properties['pickers']?.Value | Where-Object { $_ })
    $env = [ordered]@{}
    foreach ($var in @($Behaviors.PSObject.Properties['env']?.Value.PSObject.Properties)) {
        if ($var) { $env[$var.Name] = [string[]]@($var.Value) }
    }
    # Words that draw Nerd Font icons: left out while icons are off (Select-DFRoleWord).
    $nerdFontWords = [string[]]@($Behaviors.PSObject.Properties['nerdFontWords']?.Value | Where-Object { $_ })
    $used = @($aliases.Values | ForEach-Object { $_ }) + @($pickers | ForEach-Object { @($_.list) }) + @($env.Values | ForEach-Object { $_ }) + @($nerdFontWords)
    $undefined = @($used | Where-Object { $_ -notin $words } | Select-Object -Unique)
    $problem = if ($undefined) { "behaviors use undefined word(s): $($undefined -join ', ')" }
    [pscustomobject]@{
        Value   = [pscustomobject]@{ words = $words; aliases = $aliases; pickers = $pickers; env = $env; nerdFontWords = $nerdFontWords }
        Problem = $problem
    }
}

# ---- Private/Get-DFRoleDeclaration.ps1
#Requires -Version 7.2

function Get-DFRoleDeclaration {
    <#
    .SYNOPSIS
        Reads one field of a role block from the tool that fills the role this session.
    .DESCRIPTION
        For a single role, the session winner's roles.<Role>.<Field>. For a
        category role, the first active member (by name) that declares the
        field. So a tool says what it offers in its own record (zoxide's
        ranked folders, fd's folder scan), and core reads it without naming
        the tool. Returns nothing when no tool in the session declares it.
        Never throws.
    .PARAMETER Role
        The role name, e.g. 'navigation'.
    .PARAMETER Field
        The role-block field, e.g. 'directories'.
    .OUTPUTS
        The field's value, or nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Field)
    $definition = (Get-DFRoleDb)[$Role]
    if (-not $definition) { return }
    $records = if ($definition.kind -eq 'single') {
        $winner = if ($script:DFSessionRoleWinners) { $script:DFSessionRoleWinners[$Role] }
        if ($winner -and $winner.Winner) { $script:DFSessionToolDb[[string]$winner.Winner] }
    } else {
        $active = @(foreach ($name in @($script:DFSessionToolDb.Keys)) { if (Test-DFToolActive -Name $name) { $script:DFSessionToolDb[$name] } })
        Get-DFRoleMember -Role $Role -Tools $active
    }
    foreach ($record in @($records)) {
        $block = $record.roles.PSObject.Properties[$Role]?.Value
        $value = if ($block) { $block.PSObject.Properties[$Field]?.Value }
        if ($null -ne $value) { return $value }
    }
}

# ---- Private/Get-DFToolDependent.ps1
#Requires -Version 7.2

function Get-DFToolDependent {
    <#
    .SYNOPSIS
        The active tools that can't work without a tool: they require it, or require a role it is the only active member of.
    .DESCRIPTION
        Only active tools count. A tool requiring "role:<r>" depends on the
        tool when the tool is the only active member of <r>; with another
        active member, the role stays filled. With -Transitive, follows the
        requires chains and returns every dependent, deepest first, so
        removing them in that order never leaves a tool without what it needs.
    .PARAMETER Name
        The tool.
    .PARAMETER ToolDb
        Name -> tool record.
    .PARAMETER Active
        Names of the session's active tools.
    .PARAMETER Transitive
        Follow requires chains.
    .OUTPUTS
        System.String[]. Tool names.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [string[]]$Active = @(),
        [switch]$Transitive
    )
    $direct = {
        param($target)
        $record = $ToolDb[$target]
        $activeRecords = @($Active | ForEach-Object { $ToolDb[$_] })
        $soleRoles = @(if ($record) {
            foreach ($role in $record.roles.PSObject.Properties.Name) {
                $members = @(Get-DFRoleMember -Role $role -Tools $activeRecords)
                if ($members.Count -eq 1 -and $members[0].name -eq $target) { $role }
            }
        })
        foreach ($other in $Active) {
            if ($other -eq $target -or -not $ToolDb[$other]) { continue }
            $needs = @($ToolDb[$other].requires | ForEach-Object { ConvertFrom-DFToolReference -Reference $_ })
            $needsTarget = @($needs | Where-Object { $_.Kind -eq 'Tool' -and $_.Name -eq $target }).Count
            $needsSoleRole = @($needs | Where-Object { $_.Kind -eq 'Role' -and $_.Name -in $soleRoles }).Count
            if ($needsTarget -or $needsSoleRole) { $other }
        }
    }
    if (-not $Transitive) { return [string[]]@(& $direct $Name) }

    # Post-order walk: a dependent's own dependents come before it.
    $ordered = [System.Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param($target, $path)
        foreach ($dependent in & $direct $target) {
            if ($dependent -in $path -or $ordered.Contains($dependent)) { continue }
            & $visit $dependent (@($path) + $dependent)
            $ordered.Add($dependent)
        }
    }
    & $visit $Name @($Name)
    [string[]]$ordered.ToArray()
}

# ---- Private/Get-DFToolSetupState.ps1
#Requires -Version 7.2

function Get-DFToolSetupStatePath {
    <#
    .SYNOPSIS
        Returns the persisted tool-setup state file path.
    .DESCRIPTION
        Centralizes the XDG state location shared by Get-DFToolSetupState and
        Complete-DFToolSetup.
    .OUTPUTS
        System.String — $XDG_STATE_HOME\dotforge\setup-state.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path (Get-DFXdgPath State) 'dotforge' 'setup-state.json'
}

function Get-DFToolSetupState {
    <#
    .SYNOPSIS
        Reads the persisted one-time tool-setup state, keyed by tool name.
    .DESCRIPTION
        Backs Register-DFTool's "has this tool's Tools/<name>.setup.ps1 already
        run?" check and Complete-DFToolSetup's read-modify-write. Never throws:
        a missing file or corrupt JSON both
        return an empty object, treated the same as "no tool has ever run
        setup" -- see docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .OUTPUTS
        [PSCustomObject] keyed by tool name; each value has .ranAt (string)
        and .actions (object[]). Empty object ([PSCustomObject]@{}) if no
        state has ever been recorded.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $stateFile = Get-DFToolSetupStatePath
    if (-not (Test-Path $stateFile -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        [PSCustomObject]@{}
    }
}

function Clear-DFToolSetupState {
    <#
    .SYNOPSIS
        Forgets that one tool's one-time setup ran, so it runs again on its next activation.
    .PARAMETER Name
        The tool.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-DFToolSetupState
    if (-not $state.PSObject.Properties[$Name]) { return }
    $state.PSObject.Properties.Remove($Name)
    Write-DFFileAtomic -Path (Get-DFToolSetupStatePath) -Value ($state | ConvertTo-Json -Depth 10)
}

# ---- Private/Get-DFToolTheme.ps1
#Requires -Version 7.2

# Each tool's resolved theme this session: tool name -> Resolve-DFToolTheme result.
# Set by registration and Set-DFToolTheme; read by wrappers at call time.

function Resolve-DFToolTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme from its theme block: the name, its native spelling, and the value the tool is given.
    .DESCRIPTION
        Name: -Name, else the tool's per-tool key (theme.key), else the shared
        Theme key, else theme.default (Get-DFConfiguredTheme). Explicit is true
        for -Name and the per-tool key: the user chose this theme for this tool.
        Native: Name translated through theme.map (Resolve-DFThemeName).
        Value: with theme.files, a theme file found by Resolve-DFThemeFile (an
        absolute path, then <XDG config>\<files>\themes, then <tool folder>\<files>);
        otherwise, or when no file matches, Native when theme.valid is empty or
        lists it; otherwise theme.fallback with a warning ($null without one).
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Name
        A theme to use instead of the configured one.
    .EXAMPLE
        Resolve-DFToolTheme -Tool (Get-DFTool -Name bat) -Name nord

        Resolves bat's theme as if the user had chosen nord for it.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit. $null when the tool has no theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [string]$Name)
    $theme = $Tool.theme
    if (-not $theme) { return $null }
    $explicit = [bool]$Name
    if (-not $Name) {
        $explicit = [bool](Get-DFConfig $theme.key)
        $Name = Get-DFConfiguredTheme -ToolKey $theme.key -Default $theme.default
    }
    if (-not $Name) { return [pscustomobject]@{ Name = $null; Native = $null; Value = $null; Explicit = $false } }
    $native = Resolve-DFThemeName -Name $Name -ThemeMap $theme.map
    $value = $null
    if ($theme.files) {
        $bundled = Join-Path (Get-DFToolFolder -Tool $Tool -Default (Join-Path $PSScriptRoot '..' 'Tools')) $theme.files
        $value = Resolve-DFThemeFile -Tool $theme.files -Name $native -BundledDir $bundled
    }
    # A theme read only from files (no valid list of built-in names) is unset without one.
    if (-not $value -and -not ($theme.files -and -not $theme.valid)) {
        if (-not $theme.valid -or $native -in $theme.valid) {
            $value = $native
        } else {
            $value = $theme.fallback
            $instead = if ($value) { "falling back to '$value'" } else { 'leaving it unset' }
            Write-Warning "DotForge: $($Tool.name) theme '$native' not recognized — $instead"
        }
    }
    [pscustomobject]@{ Name = $Name; Native = $native; Value = $value; Explicit = $explicit }
}

function Get-DFToolTheme {
    <#
    .SYNOPSIS
        Returns a tool's theme for this session, resolving it once.
    .DESCRIPTION
        Companions call this instead of resolving the theme themselves; the
        first call (registration) resolves and caches it, later calls reuse it
        (so a rejected name warns once). Set-DFToolTheme replaces it.
    .PARAMETER Tool
        A normalized tool record.
    .EXAMPLE
        Get-DFToolTheme -Tool $DFCurrentTool

        Returns the theme the companion's tool was registered with.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit; $null for a tool without a theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    if (-not $Tool.theme) { return $null }
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    if (-not $script:DFSessionThemes.ContainsKey($Tool.name)) {
        $script:DFSessionThemes[$Tool.name] = Resolve-DFToolTheme -Tool $Tool
    }
    $script:DFSessionThemes[$Tool.name]
}

function Get-DFSessionThemeValue {
    <#
    .SYNOPSIS
        Returns the value of a tool's theme this session, or $null; wrappers call it on every run.
    .DESCRIPTION
        Reads the theme cached by registration or Set-DFToolTheme. It never
        resolves anything, so it is cheap enough for a wrapper to call on
        every run.
    .PARAMETER Name
        The tool name.
    .EXAMPLE
        Get-DFSessionThemeValue -Name bat

        Returns the theme value bat was given this session, or $null.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFSessionThemes -is [hashtable] -and $script:DFSessionThemes.ContainsKey($Name)) {
        $script:DFSessionThemes[$Name].Value
    }
}

function Set-DFSessionTheme {
    <#
    .SYNOPSIS
        Records a tool's theme for the rest of this session; Set-DFToolTheme calls it after resolving a new one.
    .PARAMETER Name
        The tool name.
    .PARAMETER Theme
        A Resolve-DFToolTheme result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscustomobject]$Theme)
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    $script:DFSessionThemes[$Name] = $Theme
}

function Set-DFToolThemeEnv {
    <#
    .SYNOPSIS
        Writes a tool's theme.env variables for a resolved theme, through Set-DFEnv.
    .DESCRIPTION
        Each theme.env template has {theme} replaced by the theme's Value, then
        ${XDG_*} expanded. Nothing is written when the theme has no Value. An
        explicit theme (the per-tool key) overrides a value set outside
        DotForge, naming the key; -ExplicitReason gives another reason.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Theme
        A Resolve-DFToolTheme result.
    .PARAMETER ExplicitReason
        Why the value overrides one set outside DotForge (Set-DFToolTheme passes its own).
    .EXAMPLE
        Set-DFToolThemeEnv -Tool $tool -Theme (Get-DFToolTheme -Tool $tool)

        Writes the tool's theme environment variables for its session theme.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [AllowNull()][pscustomobject]$Theme,
        [string]$ExplicitReason
    )
    if (-not $Theme -or -not $Theme.Value -or -not $Tool.theme.env) { return }
    if (-not $ExplicitReason -and $Theme.Explicit) { $ExplicitReason = "`$DFConfig.$($Tool.theme.key) is '$($Theme.Name)'" }
    foreach ($var in $Tool.theme.env.PSObject.Properties) {
        $value = Expand-DFXdgPath ([string]$var.Value).Replace('{theme}', $Theme.Value)
        Set-DFEnv -Name $var.Name -Value $value -Tool $Tool.name -ExplicitReason $ExplicitReason
    }
}

function Test-DFThemeSwitchable {
    <#
    .SYNOPSIS
        True when DotForge itself applies a tool's theme at run time (theme.env, a wrapper's {theme}, or the companion's apply function), so Set-DFToolTheme can switch it.
    .PARAMETER Tool
        A normalized tool record with a theme block.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $hasEnv = [bool]$Tool.theme.env -and @($Tool.theme.env.PSObject.Properties).Count -gt 0
    $inWrapper = [bool]$Tool.wrapper -and @($Tool.wrapper.args | ForEach-Object { $_.args } | Where-Object { $_.Contains('{theme}') }).Count -gt 0
    $hasEnv -or $inWrapper -or [bool]$Tool.theme.apply
}

# ---- Private/Get-DFToolUpdate.ps1
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

# ---- Private/Invoke-DFInstallPlan.ps1
#Requires -Version 7.2

function Invoke-DFInstallPlan {
    <#
    .SYNOPSIS
        Runs an install plan stage by stage and reports each tool's result.
    .DESCRIPTION
        For each stage, each manager batch:
          - its feeds are added if missing (listed first, added once);
          - the batch runs as one command when the manager supports batch,
            else one command per tool;
          - a batch with an Elevation runs the way it says (an elevator such
            as gsudo, Windows' sudo, or a separate admin window), or is
            reported as failed when no one can answer the admin prompt;
          - when a batch fails, each of its tools is re-checked: one bad id
            doesn't fail the tools that did install;
          - every command sees the location variables of its tools, its
            manager and the tools the manager requires
            (Get-DFInstallEnvironment); a feed command only the manager's.
        After the stage:
          - PATH is merged from the registry;
          - managers with installs.reactivate that installed something are
            re-activated (Register-DFTool -Name), so new runtimes reach PATH;
          - each tool is re-checked with no cached answer.
        A tool whose dependency failed or was skipped is skipped, naming it.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .PARAMETER ToolDb
        Name -> tool record.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER ToolsPath
        Tools folder for re-activation. Default: the module's Tools/.
    .OUTPUTS
        PSCustomObject[]: Tool, Result (Installed, Failed, Skipped, NotFound), Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $result = [ordered]@{}
    $set = { param($tool, $r, $d) $result[$tool] = [pscustomobject]@{ Tool = $tool; Result = $r; Detail = $d } }
    $badDep = {
        param($item)
        foreach ($d in $item.DependsOn) {
            if ($result.Contains($d) -and $result[$d].Result -in 'Failed', 'Skipped', 'NotFound') { return $d }
        }
    }
    $skipFor = {
        param($d)
        $why = @{ Failed = 'failed'; Skipped = 'was skipped'; NotFound = "isn't found yet" }[$result[$d].Result]
        "skipped: $d $why"
    }

    foreach ($stage in $Plan.Stages) {
        $reactivate = [System.Collections.Generic.List[string]]::new()
        foreach ($batch in $stage.Batches) {
            $m = $batch.Manager
            $blk = $batch.Block
            $ready = @(foreach ($it in $batch.Items) {
                $d = & $badDep $it
                if ($d) { & $set $it.Tool 'Skipped' (& $skipFor $d) } else { $it }
            })
            if (-not $ready) { continue }
            # Feeds first, each once, and only those the manager doesn't list yet.
            if ($blk.feeds) {
                $feedEnvironment = Get-DFInstallEnvironment -Manager $m -ToolDb $ToolDb
                $feeds = @($ready | Where-Object { $_.Ref.Feed } | ForEach-Object { $_.Ref.Feed } | Sort-Object name -Unique)
                if ($feeds) {
                    $listed = (Invoke-DFManagerCommand -Operation install -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.list -Values @{}) -Environment $feedEnvironment).Output
                    $names = @($listed -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
                    foreach ($f in $feeds | Where-Object { $_.name -notin $names }) {
                        $r = Invoke-DFManagerCommand -Operation install -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.add -Values @{ name = $f.name; url = $f.url }) -Environment $feedEnvironment
                        if ($r.ExitCode -ne 0) { Write-Warning "DotForge: could not add $($m.name) feed '$($f.name)' ($($f.url))." }
                    }
                }
            }
            $idOf = {
                param($it)
                if ($it.Ref.Feed -and $blk.feeds) { $blk.feeds.id.Replace('{feed}', $it.Ref.Feed.name).Replace('{id}', $it.Ref.Id) }
                else { $it.Ref.Id }
            }
            # One call for the whole batch when the manager supports it, else one per tool.
            $ids = [string[]]@($ready | ForEach-Object { & $idOf $_ })
            $environment = Get-DFInstallEnvironment -Tool @($ready | ForEach-Object { $ToolDb[$_.Tool] }) -Manager $m -ToolDb $ToolDb
            $results = @(Invoke-DFManagerBatch -Operation install -Manager $m -Block $blk -Ids $ids -Elevation $batch.Elevation -Environment $environment)
            $batched = $blk.batch -and $ready.Count -gt 1
            for ($n = 0; $n -lt $ready.Count; $n++) {
                $it = $ready[$n]; $r = $results[$n]
                $t = $ToolDb[$it.Tool]
                # A failed batch may still have installed some of its tools.
                $ok = $r.ExitCode -eq 0 -or ($batched -and (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force))
                if ($ok) { & $set $it.Tool 'Installed' "via $($m.name)$(if ($it.AvoidReason) { " ($($it.AvoidReason))" })" }
                else { & $set $it.Tool 'Failed' (Format-DFManagerFailure -Tool $it.Tool -Manager $m.name -Output $r.Output) }
            }
            if (@($results | Where-Object ExitCode -eq 0).Count -and $blk.reactivate -and -not $reactivate.Contains($m.name)) { $reactivate.Add($m.name) }
        }
        foreach ($p in $stage.Provided) {
            $d = & $badDep $p
            if ($d) { & $set $p.Tool 'Skipped' (& $skipFor $d) } else { & $set $p.Tool 'Installed' "comes with $($p.ProvidedBy)" }
        }

        Update-DFPathFromRegistry
        if ($reactivate.Count) { Register-DFTool -Name $reactivate.ToArray() @pathArgs 3>$null }
        foreach ($it in @($stage.Batches | ForEach-Object { $_.Items }) + @($stage.Provided)) {
            if (-not $it -or $result[$it.Tool].Result -ne 'Installed') { continue }
            $t = $ToolDb[$it.Tool]
            if (-not (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force)) {
                & $set $it.Tool 'NotFound' "installed, but '$($t.executable)' isn't found yet: open a new shell"
            }
        }
    }
    @($result.Values)
}

# ---- Private/Invoke-DFManagerBatch.ps1
#Requires -Version 7.2

function Invoke-DFManagerBatch {
    <#
    .SYNOPSIS
        Runs one install, update or remove for a set of package ids through one manager, and returns a result per id.
    .DESCRIPTION
        The shared executor for Install-DFTool, Update-DFTool and Remove-DFTool.
        The operation comes from the manager's installs block: install is its
        install argv, or its function and args; update and remove are an argv
        or { function; args }. An argv's {id} expands to the ids; a function
        argument that is exactly '{id}' becomes the ids. A manager that batches
        gets one call for every id, otherwise one call per id; in a batched
        call every id gets the call's exit code and output, so callers check
        each tool afterwards. A manager that doesn't declare the operation is
        never called: each id gets ExitCode -1 and "can't <op> through <manager>".
    .PARAMETER Operation
        install, update or remove.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER Block
        The manager's installs block for the source (Get-DFInstallBlock).
    .PARAMETER Ids
        Package ids, already feed-qualified where the manager needs it.
    .PARAMETER Elevation
        From Get-DFElevationMethod, for a block that needs administrator rights.
    .PARAMETER Environment
        Variables every call sees while it runs (Get-DFInstallEnvironment).
    .OUTPUTS
        PSCustomObject per id: Id, ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'remove')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [Parameter(Mandatory)][pscustomobject]$Block,
        [Parameter(Mandatory)][string[]]$Ids,
        [pscustomobject]$Elevation,
        [System.Collections.IDictionary]$Environment
    )
    $spec = if ($Operation -eq 'install') {
        if ($Block.install) { $Block.install } elseif ($Block.function) { [pscustomobject]@{ function = $Block.function; args = $Block.args } }
    } else { $Block.$Operation }
    if (-not $spec) {
        foreach ($id in $Ids) { [pscustomobject]@{ Id = $id; ExitCode = -1; Output = "can't $Operation through $($Manager.name)" } }
        return
    }
    # (A List, not `if { ,$Ids }`: statement output would unroll the wrapper.)
    $groups = [System.Collections.Generic.List[string[]]]::new()
    if ($Block.batch) { $groups.Add($Ids) } else { foreach ($id in $Ids) { $groups.Add(@($id)) } }
    foreach ($group in $groups) {
        $r = if ($spec -is [array]) {
            Invoke-DFManagerCommand -Operation $Operation -Manager $Manager -Argv (Expand-DFInstallArgv -Template $spec -Values @{ ids = $group }) -Elevation $Elevation -Environment $Environment
        } else {
            $arguments = @{}
            foreach ($p in $spec.args.PSObject.Properties) {
                # ($true -eq '{id}' is true in PowerShell, so check the type first.)
                $arguments[$p.Name] = if ($p.Value -is [string] -and $p.Value -eq '{id}') { [string[]]$group } else { $p.Value }
            }
            Invoke-DFManagerCommand -Operation $Operation -Manager $Manager -Function $spec.function -Arguments $arguments -Environment $Environment
        }
        foreach ($id in $group) { [pscustomobject]@{ Id = $id; ExitCode = $r.ExitCode; Output = $r.Output } }
    }
}

function Invoke-DFManagerOperation {
    <#
    .SYNOPSIS
        Updates or removes packages through the manager Find-DFToolSource found, asking for administrator rights when its block needs them.
    .PARAMETER Operation
        update or remove.
    .PARAMETER Found
        Find-DFToolSource's result for the first tool (Manager, Block).
    .PARAMETER Tool
        The tool records being updated or removed, for their location variables (Get-DFInstallEnvironment).
    .PARAMETER Ids
        The installed package ids.
    .PARAMETER ToolDb
        Name -> tool record (for the elevator role).
    .OUTPUTS
        PSCustomObject per id: Id, ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('update', 'remove')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Found,
        [Parameter(Mandatory)][pscustomobject[]]$Tool,
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][hashtable]$ToolDb
    )
    $elevation = if ($Found.Block.elevate) {
        $method = Get-DFElevationMethod -ToolDb $ToolDb
        if ($method.Method -ne 'Direct') { $method }
    }
    $environment = Get-DFInstallEnvironment -Tool $Tool -Manager $Found.Manager -ToolDb $ToolDb
    Invoke-DFManagerBatch -Operation $Operation -Manager $Found.Manager -Block $Found.Block -Ids $Ids -Elevation $elevation -Environment $environment
}

function ConvertTo-DFManagerResult {
    <#
    .SYNOPSIS
        Turns one Invoke-DFManagerBatch outcome into a result row: the success word, Skipped (the manager can't do it), or Failed with its last lines.
    .PARAMETER Tool
        Tool name.
    .PARAMETER Outcome
        One Invoke-DFManagerBatch result.
    .PARAMETER Manager
        The manager's name.
    .PARAMETER Success
        The Result for exit code 0 (Updated, Removed).
    .OUTPUTS
        PSCustomObject: Tool, Result, Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Tool, [pscustomobject]$Outcome, [string]$Manager, [string]$Success)
    switch ($Outcome.ExitCode) {
        0 { [pscustomobject]@{ Tool = $Tool; Result = $Success; Detail = "via $Manager" } }
        -1 { [pscustomobject]@{ Tool = $Tool; Result = 'Skipped'; Detail = $Outcome.Output } }
        default { [pscustomobject]@{ Tool = $Tool; Result = 'Failed'; Detail = (Format-DFManagerFailure -Tool $Tool -Manager $Manager -Output $Outcome.Output) } }
    }
}

function Format-DFManagerFailure {
    <#
    .SYNOPSIS
        A failed manager call's Detail: "<manager> failed: " and its last three lines; the whole output goes to the verbose stream.
    .PARAMETER Tool
        Tool name.
    .PARAMETER Manager
        The manager's name.
    .PARAMETER Output
        What the manager wrote.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Tool, [string]$Manager, [string]$Output)
    $text = "$Output".Trim()
    Write-Verbose "$Manager output for $($Tool):`n$text"
    $tail = @($text -split "`r?`n" | Select-Object -Last 3) -join ' / '
    "$Manager failed: $tail"
}

function Resolve-DFPartialUpdate {
    <#
    .SYNOPSIS
        After a batched update fails, asks the manager again which tools it did update.
    .DESCRIPTION
        One failing id fails a whole batched call, though the other tools may
        have updated. When a batch of several ids failed, the manager's
        outdated list (or its installed list, when it has no outdated) is read
        afresh: a tool no longer outdated, or whose installed version changed,
        gets exit code 0. Other outcomes are returned unchanged.
    .PARAMETER Found
        Find-DFToolSource's result for the batch's manager (Manager, Block).
    .PARAMETER Rows
        The batch's DotForge.ToolUpdate rows, in the order of -Outcomes.
    .PARAMETER Outcomes
        Invoke-DFManagerBatch's results.
    .OUTPUTS
        PSCustomObject per id: Id, ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([pscustomobject]$Found, [object[]]$Rows, [object[]]$Outcomes)
    $failed = @($Outcomes | Where-Object { $_.ExitCode -notin 0, -1 })
    if (-not ($Found.Block.batch -and $Rows.Count -gt 1 -and $failed)) { return $Outcomes }
    $operation = if ($Found.Block.outdated) { 'outdated' } else { 'list' }
    $after = @(Get-DFManagerInstalled -Manager $Found.Manager -Block $Found.Block -Operation $operation)
    for ($n = 0; $n -lt $Outcomes.Count; $n++) {
        $outcome = $Outcomes[$n]
        if ($outcome.ExitCode -in 0, -1) { $outcome; continue }
        $now = $after | Where-Object Id -eq $Rows[$n].Found.Id | Select-Object -First 1
        $updated = if ($operation -eq 'outdated') { -not $now } else { $now -and $Rows[$n].Installed -and $now.Installed -ne $Rows[$n].Installed }
        if ($updated) { [pscustomobject]@{ Id = $outcome.Id; ExitCode = 0; Output = $outcome.Output } } else { $outcome }
    }
}

# ---- Private/Invoke-DFManagerCommand.ps1
#Requires -Version 7.2

function Expand-DFInstallArgv {
    <#
    .SYNOPSIS
        Fills a manager's argv template: {id} becomes every id, other {name} tokens come from -Values.
    .PARAMETER Template
        The argv template from installs.install or installs.feeds. A token
        that is exactly {id} expands to every id; a token containing {id}
        (pkg@{id}) is repeated once per id.
    .PARAMETER Values
        ids (string[]) plus any other token values (name, url).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string[]]$Template, [Parameter(Mandatory)][hashtable]$Values)
    [string[]]@(foreach ($t in $Template) {
        $fill = { param($text) [regex]::Replace($text, '\{(\w+)\}', { param($m) [string]$Values[$m.Groups[1].Value] }) }
        if ($t -eq '{id}') { @($Values.ids) }
        # {id} inside a token (node@{id}) gives one argument per id.
        elseif ($t.Contains('{id}')) { foreach ($i in @($Values.ids)) { & $fill $t.Replace('{id}', $i) } }
        else { & $fill $t }
    })
}

function Invoke-DFManagerCommand {
    <#
    .SYNOPSIS
        Runs one package-manager command and returns its exit code and output. The only place DotForge runs a manager.
    .DESCRIPTION
        Serves every operation (install, update, remove, list, outdated). An
        argv runs as a native command; a function (Install-PSResource,
        Update-PSResource) is called with -Arguments splatted. -Elevation, from
        Get-DFElevationMethod, says how to get administrator rights: an
        elevator (gsudo) or Windows' sudo runs the argv in this console; RunAs
        opens a separate administrator window, whose output can't be read, so
        only its exit code comes back; Unavailable runs nothing and says why.
        Tests mock this function.
    .PARAMETER Operation
        install, update, remove, list or outdated (for messages).
    .PARAMETER Manager
        The manager's tool record (for messages).
    .PARAMETER Argv
        The command line, already expanded.
    .PARAMETER Function
        A PowerShell command to call instead of an argv.
    .PARAMETER Arguments
        Parameters for -Function.
    .PARAMETER Elevation
        From Get-DFElevationMethod; omit (or $null) when the command doesn't need administrator rights.
    .PARAMETER Environment
        Variables the command sees while it runs (Get-DFInstallEnvironment).
        One set outside DotForge is kept; one unset or still holding what
        DotForge wrote (Get-DFEnvState) is set. Afterwards each goes back to
        its previous value, even when the command throws, unless the command
        changed it itself (scoop's in-process shim saves some to the Windows
        environment), so the session agrees with the manager. A separate
        administrator window (RunAs) starts from the saved user environment
        and doesn't get them, nor does Windows' sudo: then a warning and the
        output name the variables not passed. gsudo passes them.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'remove', 'list', 'outdated')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [string[]]$Argv = @(),
        [string]$Function,
        [hashtable]$Arguments = @{},
        [pscustomobject]$Elevation,
        [System.Collections.IDictionary]$Environment
    )
    $changes = @(if ($Environment) { Set-DFCommandEnvironment -Environment $Environment -Manager $Manager.name })
    try {
        if ($Function) {
            try {
                $out = & $Function @Arguments -ErrorAction Stop 2>&1 | Out-String
                return [pscustomobject]@{ ExitCode = 0; Output = $out }
            } catch {
                return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
            }
        }
        $method = if ($Elevation) { $Elevation.Method } else { 'None' }
        if ($method -eq 'Unavailable') {
            return [pscustomobject]@{ ExitCode = 1; Output = "$($Manager.name) needs administrator rights: $($Elevation.Detail)" }
        }
        if ($method -eq 'RunAs') {
            # Start-Process joins -ArgumentList with spaces, so quote what would split.
            $quoted = @($Argv | Select-Object -Skip 1 | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
            try {
                $process = Start-Process -FilePath $Argv[0] -ArgumentList $quoted -Verb RunAs -Wait -PassThru -ErrorAction Stop
            } catch {
                # A declined UAC prompt is Win32 error 1223 (ERROR_CANCELLED), usually wrapped by Start-Process.
                $win32 = @($_.Exception, $_.Exception.InnerException) | Where-Object { $_ -is [System.ComponentModel.Win32Exception] } | Select-Object -First 1
                $code = if ($win32) { $win32.NativeErrorCode } else { 1 }
                return [pscustomobject]@{ ExitCode = $code; Output = "the administrator prompt was declined or failed: $($_.Exception.Message)" }
            }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = "ran in a separate administrator window (exit code $($process.ExitCode))" }
        }
        $exe, $rest = if ($method -in 'Elevator', 'WindowsSudo') { $Elevation.Executable, $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
        # A manager can resolve to a .ps1 shim (scoop.ps1) that runs in-process and
        # never sets an exit code: don't read a stale one from an earlier command.
        $global:LASTEXITCODE = 0
        # *>&1, not 2>&1: an in-process .ps1 shim also writes to the host and the
        # warning stream (scoop's "Installed apps:"), which would print mid-command.
        $items = & $exe @rest *>&1
        # list and outdated output is parsed: keep stderr and warnings out of it
        # (pip's "[notice] A new release of pip is available" would break its JSON).
        if ($Operation -in 'list', 'outdated') {
            $items = $items | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] }
        }
        $out = $items | Out-String
        $exitCode = $LASTEXITCODE
        # Windows' sudo starts the elevated command without this process's
        # environment (checked 2026-10-25; gsudo passes it).
        if ($method -eq 'WindowsSudo' -and $Environment -and $Environment.Count) {
            $note = "DotForge's install variables were not passed through Windows' sudo: $(@($Environment.Keys) -join ', ')"
            Write-Warning "DotForge: $($Manager.name): $note. The install may use the tool's default folders; installing gsudo avoids this."
            $out += "($note)"
        }
        [pscustomobject]@{ ExitCode = $exitCode; Output = $out }
    } finally {
        Restore-DFCommandEnvironment -Changes $changes
    }
}

function Set-DFCommandEnvironment {
    <#
    .SYNOPSIS
        Sets a manager command's variables in this process, keeping any set outside DotForge, and returns what it changed.
    .PARAMETER Environment
        Variable -> value (Get-DFInstallEnvironment).
    .PARAMETER Manager
        The manager's name (for messages).
    .OUTPUTS
        PSCustomObject per variable set: Name, Previous ($null when unset), Value.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [string]$Manager)
    $written = (Get-DFEnvState).Written
    foreach ($name in @($Environment.Keys)) {
        $value = [string]$Environment[$name]
        $current = [Environment]::GetEnvironmentVariable($name)
        if ($current -ceq $value) { continue }
        # Set-DFEnv's rule: a value DotForge didn't write was set outside it.
        if ($null -ne $current -and -not ($written.ContainsKey($name) -and $written[$name] -ceq $current)) {
            Write-Verbose "DotForge: keeping $name=$current, set outside DotForge, for this $Manager command."
            continue
        }
        [Environment]::SetEnvironmentVariable($name, $value)
        [pscustomobject]@{ Name = $name; Previous = $current; Value = $value }
    }
}

function Restore-DFCommandEnvironment {
    <#
    .SYNOPSIS
        Puts back the variables Set-DFCommandEnvironment changed, except one the command itself changed since.
    .PARAMETER Changes
        Set-DFCommandEnvironment's result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Changes = @())
    foreach ($change in $Changes) {
        if ([Environment]::GetEnvironmentVariable($change.Name) -cne $change.Value) { continue }
        # ($null would reach .NET as "", which leaves the variable set but empty.)
        $previous = if ($null -eq $change.Previous) { [NullString]::Value } else { $change.Previous }
        [Environment]::SetEnvironmentVariable($change.Name, $previous)
    }
}

# ---- Private/Invoke-DFPackageManagerPicker.ps1
#Requires -Version 7.2

function Invoke-DFPackageManagerPicker {
    <#
    .SYNOPSIS
        Shared fzf-picker wiring for the scoop/winget/choco package-manager
        sidecars: delimiter, first-field display, preview debounce prefix,
        preview window, tab-split parse, and the --expect/--bind pass-through.
    .DESCRIPTION
        Each package-manager sidecar (Tools/scoop.ps1, Tools/winget.ps1,
        Tools/choco.ps1) builds its own item list and its own post-selection
        action (install/uninstall/update via that package manager's own
        module or CLI) -- those stay in each sidecar, since they are
        genuinely different per tool. This helper only collapses the part
        that was byte-for-byte identical across all nine pickers: the
        Invoke-DFPicker wiring call itself.
    .PARAMETER ListItems
        Scriptblock producing the picker's display lines (tab-delimited:
        display text first, the parsed key second).
    .PARAMETER PreviewCommand
        The package manager's own preview command (e.g. 'scoop info {2}').
        The 'ping -n 2 127.0.0.1 >nul &' debounce prefix -- which stops fast
        scrolling from spawning a preview process per skipped item -- is
        added here once, instead of at each of the nine call sites.
    .PARAMETER Header
        Header text shown at the top of the fzf window.
    .PARAMETER ExpectKey
        fzf --expect key name (e.g. 'alt-r', 'alt-c', 'alt-a').
    .PARAMETER Bind
        fzf --bind spec for the in-place execute() key. Omit for update
        pickers, which have no in-place bind.
    .PARAMETER Multi
        Pass -Multi through to Invoke-DFPicker (update pickers only).
    .OUTPUTS
        [pscustomobject]@{ Key; Selected } -- see Invoke-DFPicker's -Expect
        behavior, which every package-manager picker relies on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ListItems,
        [Parameter(Mandatory)][string]$PreviewCommand,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$ExpectKey,
        [string]$Bind,
        [switch]$Multi
    )

    # Splatted conditionally rather than always passing -Bind $Bind: explicitly
    # binding a $null scalar to Invoke-DFPicker's [string[]]$Bind parameter gets
    # coerced into a one-element array containing $null (not a true empty/null
    # collection), so its `foreach ($b in $Bind)` would iterate once and emit a
    # bare, argument-less --bind. Omitting the key entirely avoids that.
    $pickerArgs = @{
        List          = $ListItems
        Delimiter     = "`t"
        WithNth       = '1'
        Multi         = $Multi
        Preview       = "ping -n 2 127.0.0.1 >nul & $PreviewCommand"
        PreviewWindow = 'right:60%'
        Header        = $Header
        Parse         = { ($_ -split "`t")[1] }
        Expect        = $ExpectKey
    }
    if ($Bind) { $pickerArgs['Bind'] = $Bind }

    Invoke-DFPicker @pickerArgs
}

# Each package-manager companion (Tools/winget.ps1, scoop.ps1, choco.ps1)
# registers a spec here; its three pickers then call Invoke-DFPackageManagerAction.
if (-not (Get-Variable -Name DFPackageManagerSpecs -Scope Script -ErrorAction Ignore)) { $script:DFPackageManagerSpecs = @{} }

function Invoke-DFPackageManagerAction {
    <#
    .SYNOPSIS
        Runs one package-manager picker (search and install, uninstall, or update) from that manager's spec.
    .DESCRIPTION
        The control flow every package-manager picker shares: check the
        manager's dependency, build the list, show the picker, then act on the
        pressed key. Everything that differs between managers (which commands
        list and act, how a line is formatted, the command strings, the wording)
        comes from the spec the companion registered in $script:DFPackageManagerSpecs:

            Name              'winget'
            Require           { $true if usable; warns itself otherwise }
            SearchPrompt      prompt when -Query is empty
            Preview           fzf preview command, {2} is the id
            Search            { param($Query) lines 'display<TAB>id' }
            Installed         { param($Source) lines for installed packages }
            Outdated          { lines for packages with an update }
            InstallCommand    install command, {0} is the id
            UninstallCommand  uninstall command, {0} is the id
            InPlace           { param($command) the command for fzf's execute() keys }
            Install, Uninstall, Update   { param($Id) do it }
            UpdateAll         { update everything }
            UpdateWord        'upgrade' or 'update' (header text)
            UpdatingWord      'Upgrading' or 'Updating' (progress text)
            AllMessage        progress text for update-all
    .PARAMETER Manager
        The spec name, e.g. 'winget'.
    .PARAMETER Action
        Install (search, then return or run the install command), Uninstall, or Update.
    .PARAMETER Query
        Search terms for Install; prompted for when empty.
    .PARAMETER Source
        Passed to the spec's Installed list (winget filters by it).
    .OUTPUTS
        System.String: the install or uninstall command, when the key asks for
        the command instead of running it. Otherwise none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall', 'Update')][string]$Action,
        [string]$Query = '',
        [string]$Source = ''
    )
    $spec = $script:DFPackageManagerSpecs[$Manager]
    if (-not (& $spec.Require)) { return }
    $name = $spec.Name
    $inPlace = { param($template) & $spec.InPlace ($template -f '{2}') }

    switch ($Action) {
        'Install' {
            if (-not $Query) { $Query = Read-Host $spec.SearchPrompt }
            # Resolved here, then closed over as plain data, so the picker's scope
            # doesn't need $Query.
            $items = @(& $spec.Search $Query)
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name search  [Enter=command | Alt-R=install | Alt-I=install in place]" `
                -ExpectKey 'alt-r' -Bind "alt-i:execute($(& $inPlace $spec.InstallCommand))"
            if (-not $sel) { return }
            $id = @($sel.Selected)[0]
            if (-not $id) { return }   # only the in-place Alt-I bind ran; nothing chosen on exit
            if ($sel.Key -eq 'alt-r') {
                Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
                & $spec.Install $id
            } else {
                $spec.InstallCommand -f $id   # Enter: the command, to review or run
            }
        }
        'Uninstall' {
            $items = @(& $spec.Installed $Source)
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]" `
                -ExpectKey 'alt-c' -Bind "alt-x:execute($(& $inPlace $spec.UninstallCommand))"
            if (-not $sel) { return }
            $id = @($sel.Selected)[0]
            if (-not $id) { return }
            if ($sel.Key -eq 'alt-c') {
                $spec.UninstallCommand -f $id
            } else {
                Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
                & $spec.Uninstall $id
            }
        }
        'Update' {
            $items = @(& $spec.Outdated)
            $word = $spec.UpdateWord
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name $word  [Tab=mark | Enter=$word marked | Alt-A=$word all]" -ExpectKey 'alt-a' -Multi
            if (-not $sel) { return }
            if ($sel.Key -eq 'alt-a') {
                Write-Host "⚙  $($spec.AllMessage)" -ForegroundColor Green
                & $spec.UpdateAll
                return
            }
            foreach ($id in $sel.Selected) {
                if ($id) {
                    Write-Host "⚙  $($spec.UpdatingWord) $id…" -ForegroundColor Green
                    & $spec.Update $id
                }
            }
        }
    }
}

function Register-DFPrefillChord {
    <#
    .SYNOPSIS
        Binds a PSReadLine chord that replaces the command line with the install command a search picker returns.
    .DESCRIPTION
        Type a search term, press the chord, pick a package: the term is
        replaced by the picker's install command, ready to edit or run. Uses
        the current line as the query and does nothing on an empty line. A
        no-op when PSReadLine isn't loaded.
    .PARAMETER Chord
        The PSReadLine chord, e.g. 'Ctrl+g,w'.
    .PARAMETER Picker
        The search picker to run with -Query, e.g. 'Select-WingetPackage'.
    .PARAMETER Description
        Shown by Get-PSReadLineKeyHandler.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Chord,
        [Parameter(Mandatory)][string]$Picker,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore)) { return }
    Set-PSReadLineKeyHandler -Chord $Chord -Description $Description -ScriptBlock {
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $cmd = & $Picker -Query $line
        if ($cmd -is [string] -and $cmd.Trim()) {
            [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)
        }
    }.GetNewClosure()
}

# ---- Private/Invoke-DFSessionActivation.ps1
#Requires -Version 7.2

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

    Set-DFExcludedToolStatus -Request $Request
    $wanted = @($Request | Where-Object { -not $_.Excluded })
    $toolDb = if ($wanted) { Import-DFToolDb -Name $wanted.Name @pathArgs } else { @{} }
    $requestedBy = @{}
    foreach ($entry in $wanted) { $requestedBy[$entry.Name] = $entry.RequestedBy }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $wanted) {
        if ($toolDb.ContainsKey($entry.Name)) { $records.Add($toolDb[$entry.Name]) }
        else { $status[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Failed -RequestedBy $entry.RequestedBy -Detail 'its tool record is missing or invalid (see the warning above)' }
    }

    $requirements = Resolve-DFToolRequirements -Records $records -ToolDb $toolDb -RequestedBy $requestedBy `
        -Excluded @(Get-DFExcludedToolNames) @pathArgs
    # A tool whose old config location still holds the user's config is left
    # alone entirely until they resolve it (Resolve-DFToolConflict).
    $owned = Select-DFOwnedRecord -Records $records -RequestedBy $requestedBy -Reactivate $Reactivate
    $records = $owned.Records
    $tools = @(Get-DFActivationOrder -Records $records -ToolDb $toolDb -RequirementEdges $requirements.Edges)
    $roleDb = Get-DFRoleDb
    $winners = Get-DFRoleWinners -ToolDb $toolDb -Tools $tools -RoleDb $roleDb
    # Stored before any companion runs: a companion may ask Get-DFRole who won.
    foreach ($name in $toolDb.Keys) { $script:DFSessionToolDb[$name] = $toolDb[$name] }
    $script:DFSessionRoleWinners = $winners
    Write-DFRoleNotice -RoleWinners $winners -RoleDb $roleDb
    $context = [pscustomobject]@{
        RoleWinners = $winners
        RoleDb      = $roleDb
        ToolsPath   = $toolsDir
        SkipSetup   = @(Get-DFConfig SkipSetup)
    }

    $prewarmJob = Start-DFActivationPrewarm -Tools $tools
    try {
        foreach ($tool in $tools) {
            if ((Test-DFToolActive $tool.name) -and $tool.name -notin $Reactivate) { continue }
            # A tool that only draws icons waits for a Nerd Font; the load says why (Write-DFNerdFontNotice).
            if ($tool.nerdFont -eq 'required' -and -not (Test-DFIconsOn)) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Excluded -RequestedBy $requestedBy[$tool.name] -Detail 'needs a Nerd Font (icons are off; see NerdFont)'
                continue
            }
            $blocker = @(Get-DFActivationBlocker -Tool $tool -Requirements $requirements @pathArgs)
            if ($blocker) {
                # Installed, but a tool it needs isn't active: Blocked. Not installed: Missing (Install-DFTool -Missing).
                $state = if (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type) { 'Blocked' } else { 'Missing' }
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State $state -RequestedBy $requestedBy[$tool.name] -Detail $blocker
                continue
            }
            # Installed only now (an earlier companion put it on PATH, as fnm does
            # for node and npm): its ownership check couldn't run before.
            if ($owned.State.Unchecked.Contains($tool.name) -and
                -not (Test-DFToolOwnership -Record $tool -State $owned.State -RequestedBy $requestedBy)) { continue }
            # One tool's failure (a throwing companion, or any error under a
            # profile's $ErrorActionPreference = 'Stop') must not stop the rest.
            try {
                Invoke-DFToolRegistration -Tool $tool -Context $context
                $oldLocations = if ($owned.State.Notes.ContainsKey($tool.name)) { $owned.State.Notes[$tool.name] } else { @() }
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name] -Detail @(@(Get-DFEnvKeptNote -Tool $tool.name) + @(Get-DFToolNote -Tool $tool.name) + @($oldLocations))
            } catch {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Failed -RequestedBy $requestedBy[$tool.name] -Detail $_.Exception.Message
            }
        }
    } finally {
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
        Complete-DFToolOwnership -State $owned.State
    }

    # A role nothing in the session fills may name a fallback (pager: more).
    Set-DFRoleFallback -RoleDb $roleDb -RoleWinners $winners -SessionTools @($script:DFSessionToolDb.Values) | Out-Null
    Add-DFRoleOutcomeStatus -RoleWinners $winners

    # Install hints are built later, when the status is read (Add-DFInstallHint).
    $script:DFSessionToolsPath = $ToolsPath

    foreach ($tool in $tools) { if (Test-DFToolActive $tool.name) { $tool } }
}

function Set-DFExcludedToolStatus {
    <#
    .SYNOPSIS
        Records Excluded for each excluded request entry that isn't already Active.
    .PARAMETER Request
        Request entries: Name, RequestedBy, Excluded.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Request = @())
    foreach ($entry in $Request) {
        if ($entry.Excluded -and -not (Test-DFToolActive $entry.Name)) {
            $script:DFSessionStatus[$entry.Name] = New-DFToolStatus -Name $entry.Name -State Excluded `
                -RequestedBy $entry.RequestedBy -Detail 'excluded by ExcludeTools'
        }
    }
}

function Get-DFExcludedToolNames {
    <#
    .SYNOPSIS
        Every tool name ExcludeTools excludes, with +groups expanded.
    .DESCRIPTION
        Every excluded name, not just the requested ones: a required tool can be
        excluded without having been requested.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $groups = Get-DFGroupDb
    foreach ($excludeEntry in @(Get-DFConfig ExcludeTools)) {
        if ($excludeEntry) { Expand-DFGroupEntry -Entry $excludeEntry -GroupDb $groups }
    }
}

function Get-DFActivationOrder {
    <#
    .SYNOPSIS
        Orders the records for activation: by after, requires, and after: ["role:<name>"].
    .DESCRIPTION
        after: ["role:<name>"] orders a tool after every requested member of
        that role. Those edges are added to (a copy of) the requirement edges,
        and Invoke-DFTopoSort orders the records.
    .PARAMETER Records
        The records to order.
    .PARAMETER ToolDb
        Name -> record for the requested tools.
    .PARAMETER RequirementEdges
        Resolve-DFToolRequirements' Edges: tool name -> names it must come after.
    .OUTPUTS
        The records, in activation order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][hashtable]$RequirementEdges
    )
    $edges = @{}
    foreach ($name in $RequirementEdges.Keys) { $edges[$name] = @($RequirementEdges[$name]) }
    foreach ($record in $Records) {
        foreach ($afterEntry in @($record.after)) {
            $reference = ConvertFrom-DFToolReference -Reference $afterEntry
            if (-not $reference -or $reference.Kind -ne 'Role') { continue }
            foreach ($member in @(Get-DFRoleMember -Role $reference.Name -Tools @($ToolDb.Values) | Where-Object { $_.name -ne $record.name })) {
                $edges[$record.name] = @(@($edges[$record.name]) + $member.name | Where-Object { $_ })
            }
        }
    }
    Invoke-DFTopoSort -Tools $Records.ToArray() -ExtraEdges $edges | Where-Object { $_ }
}

function Start-DFActivationPrewarm {
    <#
    .SYNOPSIS
        Starts loading, in the background, the installed prewarm modules about to be activated.
    .PARAMETER Tools
        The ordered tool records.
    .OUTPUTS
        The prewarm job, or nothing when no module needs it.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Tools = @())
    $prewarmModules = @(foreach ($tool in $Tools) {
        if ($tool.type -eq 'module' -and $tool.prewarm -and -not (Test-DFToolActive $tool.name) -and
            -not ($tool.nerdFont -eq 'required' -and -not (Test-DFIconsOn)) -and
            (Test-DFToolAvailable -Executable $tool.executable -Type 'module')) { $tool.executable }
    })
    if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
}

function Get-DFActivationBlocker {
    <#
    .SYNOPSIS
        Says why a tool can't be activated now, or returns nothing when nothing blocks it.
    .DESCRIPTION
        In order: a requirement Resolve-DFToolRequirements blocked (excluded, or
        no record); a required tool that didn't activate; the tool not being
        installed (with a hint naming any required role none of whose members
        is requested).
    .PARAMETER Tool
        The tool record.
    .PARAMETER Requirements
        Resolve-DFToolRequirements result.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        System.String[]: the reasons, empty when nothing blocks it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$Requirements,
        [string]$ToolsPath
    )
    if ($Requirements.Blocked.ContainsKey($Tool.name)) { return $Requirements.Blocked[$Tool.name] }
    # A required tool (not a role) was ordered first; if it then failed to
    # activate, neither can this one. (On a requires cycle, the tool not
    # yet reached has no status, so the cycle doesn't block itself.)
    $status = $script:DFSessionStatus
    $unmet = @(foreach ($req in @($Tool.requires)) {
        if ((ConvertFrom-DFToolReference -Reference $req).Kind -eq 'Tool' -and $status.Contains($req) -and -not (Test-DFToolActive $req)) { $req }
    })
    if ($unmet) { return "requires $($unmet -join ', '), which is not available" }
    if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    "'$($Tool.executable)' is not installed"
    if ($Requirements.RoleHint.ContainsKey($Tool.name)) {
        Get-DFRoleRequirementHint -Role $Requirements.RoleHint[$Tool.name] @pathArgs
    }
}

function Add-DFRoleOutcomeStatus {
    <#
    .SYNOPSIS
        Adds the role outcomes to the session status: each winner's Roles, and each missing preferred tool's stand-in.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$RoleWinners)
    $status = $script:DFSessionStatus
    foreach ($roleOutcome in $RoleWinners.Values) {
        if ($status.Contains($roleOutcome.Winner) -and $roleOutcome.Role -notin $status[$roleOutcome.Winner].Roles) {
            $status[$roleOutcome.Winner].Roles = [string[]](@($status[$roleOutcome.Winner].Roles) + $roleOutcome.Role)
        }
        if ($roleOutcome.Reason -eq 'fallback' -and $status.Contains($roleOutcome.Preferred) -and $status[$roleOutcome.Preferred].State -eq 'Missing') {
            $preferred = $status[$roleOutcome.Preferred]
            Add-DFToolStatusDetail -Status $preferred -Text "using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"
            $preferred | Add-Member -NotePropertyName FallbackRole -NotePropertyValue $roleOutcome.Role -Force
            $preferred | Add-Member -NotePropertyName FallbackTool -NotePropertyValue $roleOutcome.Winner -Force
        }
    }
}

function New-DFToolStatus {
    <#
    .SYNOPSIS
        Creates one DotForge.ToolStatus record.
    .PARAMETER Name
        Tool name.
    .PARAMETER State
        Active, Missing (not installed), Blocked (installed, but a tool it
        requires isn't active), Failed, Excluded or Conflict (its old config
        location holds the user's config; see Resolve-DFToolConflict).
    .PARAMETER RequestedBy
        'Tools', '+group', or what else requested it.
    .PARAMETER Detail
        Lines explaining the state (failure message, what blocks it, values kept over the tool's own). Joined with '; ' in Detail.
    .OUTPUTS
        DotForge.ToolStatus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Active', 'Missing', 'Blocked', 'Failed', 'Excluded', 'Conflict')][string]$State,
        [string]$RequestedBy,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Detail = @()
    )
    $status = [pscustomobject]@{
        PSTypeName  = 'DotForge.ToolStatus'
        Name        = $Name
        State       = $State
        RequestedBy = $RequestedBy
        Roles       = [string[]]@()
        DetailItems = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($line in $Detail) { if ($line) { $status.DetailItems.Add($line) } }
    # One place renders the lines, so no producer joins strings itself (T-28).
    $status | Add-Member -MemberType ScriptProperty -Name Detail -Value { $this.DetailItems -join '; ' }
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Name', 'State', 'RequestedBy', 'Roles', 'Detail'))
    $status | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    $status
}

function Add-DFToolStatusDetail {
    <#
    .SYNOPSIS
        Appends a line to a tool status's Detail.
    .PARAMETER Status
        A DotForge.ToolStatus record.
    .PARAMETER Text
        The line; empty text is ignored.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Status, [AllowEmptyString()][string]$Text)
    if ($Text) { $Status.DetailItems.Add($Text) }
}

function Test-DFToolActive {
    <#
    .SYNOPSIS
        True when the tool is Active in this session.
    .PARAMETER Name
        Tool name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    [bool]($script:DFSessionStatus -and $script:DFSessionStatus.Contains($Name) -and
        $script:DFSessionStatus[$Name].State -eq 'Active')
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
        Warns, at the end of a load, about requested tools that are missing or failed, prints new setup notes, and says why icons are off.
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
    Write-DFSetupNoteNotice
    Write-DFNerdFontNotice
    if (-not $script:DFSessionStatus) { return }
    $all = @($script:DFSessionStatus.Values)
    $missing = @($all | Where-Object State -eq 'Missing')
    $failed = @($all | Where-Object State -eq 'Failed')
    $blocked = @($all | Where-Object State -eq 'Blocked')
    if ($blocked) {
        $what = if ($blocked.Count -eq 1) { "1 tool can't load until a tool it needs does" } else { "$($blocked.Count) tools can't load until tools they need do" }
        Write-Warning "DotForge: $what`: $(($blocked | ForEach-Object { "$($_.Name) ($($_.Detail))" }) -join ', ')."
    }
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
    # One line for every tool waiting on the user; each one's advice is in Get-DFToolStatus -Conflict.
    $waiting = @($all | Where-Object { $_.State -eq 'Conflict' -and -not $_.Warned })
    if ($waiting) {
        foreach ($conflicted in $waiting) { $conflicted.Warned = $true }
        $what = if ($waiting.Count -eq 1) { '1 tool is' } else { "$($waiting.Count) tools are" }
        Write-Warning "DotForge: $what waiting on your existing config: $($waiting.Name -join ', '). See Get-DFToolStatus -Conflict, or run Resolve-DFToolConflict to go through them."
    }
}

function Select-DFOwnedRecord {
    <#
    .SYNOPSIS
        Drops requested tools whose config DotForge would hide, recording their Conflict status; records the rest as owned.
    .DESCRIPTION
        Runs before activation order and roles, so a tool in conflict gets no
        role and blocks the tools that require it. Only installed tools that
        aren't already active are checked here; one that isn't installed yet
        is listed in State.Unchecked and checked by the activation loop when
        its turn comes (an earlier companion may put it on PATH). Ownership
        changes are saved once, after the loop. See
        docs/superpowers/specs/2026-10-11-config-ownership-design.md.
    .PARAMETER Records
        The requested records (after Resolve-DFToolRequirements).
    .PARAMETER RequestedBy
        Name -> RequestedBy.
    .PARAMETER Reactivate
        Names re-registered on purpose (checked even when active).
    .OUTPUTS
        pscustomobject: Records (List[object], the records to activate) and
        State (Test-DFToolOwnership's state: Table, Readable, Changed,
        Unchecked, Clean).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Reactivate = @()
    )
    $table = Read-DFToolOwnership
    $state = [pscustomobject]@{
        # Unreadable: still check (nothing owned), but never write over the file.
        Table     = if ($null -ne $table) { $table } else { @{} }
        Readable  = $null -ne $table
        Changed   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Unchecked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Clean     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Notes     = @{}   # tool -> notes about old locations that don't hold it back
        Reactivate = $Reactivate
    }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        if ((Test-DFToolActive $record.name) -and $record.name -notin $Reactivate) { $kept.Add($record); continue }
        if (-not (Test-DFToolAvailable -Executable $record.executable -Type $record.type)) {
            $null = $state.Unchecked.Add($record.name)
            $kept.Add($record)
            continue
        }
        if (Test-DFToolOwnership -Record $record -State $state -RequestedBy $RequestedBy) { $kept.Add($record) }
    }
    [pscustomobject]@{ Records = $kept; State = $state }
}

function Test-DFToolOwnership {
    <#
    .SYNOPSIS
        Checks one installed tool against the ownership table: false (and status Conflict) when its old config location holds the user's config.
    .DESCRIPTION
        A tool with no conflict, a complete check and a relocated path is
        listed in State.Clean, to be recorded as owned (how: clean) if it ends
        up active (Complete-DFToolOwnership). An owned tool's unfinished
        removals from Resolve-DFToolConflict -Move are retried. Changes go into
        State.Table and their names into State.Changed.
    .PARAMETER Record
        The tool record.
    .PARAMETER State
        Select-DFOwnedRecord's State.
    .PARAMETER RequestedBy
        Name -> RequestedBy.
    .OUTPUTS
        System.Boolean: whether the tool may be activated.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Record,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][hashtable]$RequestedBy
    )
    $table = $State.Table
    $check = Find-DFToolConflict -Tool $Record -Ownership $table
    # An old location that only holds caches, installed packages or history (xdg.native block:
    # false) is noted with its guide; the tool stays active.
    # Kept in the ownership state, not Add-DFToolNote: registration clears a tool's notes first.
    $oldNotes = @(foreach ($note in @($check.Conflicts | Where-Object { $_.Block -eq $false })) {
            "$(@($note.OldPaths) -join ', ') isn't used any more: $($note.Guide)"
        })
    if ($oldNotes -and $State.PSObject.Properties['Notes']) { $State.Notes[$Record.name] = $oldNotes }
    $blocking = @($check.Conflicts | Where-Object { $_.Block -ne $false })
    if ($blocking) {
        $paths = @($blocking.OldPaths) -join ', '
        $status = New-DFToolStatus -Name $Record.name -State Conflict -RequestedBy $RequestedBy[$Record.name] -Detail "your existing config at $paths would be hidden. $((Get-DFConflictAdvice -Name $Record.name -Conflicts $blocking).Text)"
        $status | Add-Member -NotePropertyName Conflicts -NotePropertyValue $blocking
        # Write-DFSessionNotice warns once per conflict: a later Register-DFTool
        # re-checks every requested tool, but warns again only for one it names.
        $previous = $script:DFSessionStatus[$Record.name]
        $warned = $Record.name -notin $State.Reactivate -and $previous -and $previous.State -eq 'Conflict' -and
            $previous.PSObject.Properties['Warned'] -and $previous.Warned
        $status | Add-Member -NotePropertyName Warned -NotePropertyValue ([bool]$warned)
        $script:DFSessionStatus[$Record.name] = $status
        return $false
    }
    if (-not $State.Readable) { return $true }
    if ($check.Complete -and -not $table.ContainsKey($Record.name) -and @(Get-DFToolRelocation -Tool $Record)) {
        $null = $State.Clean.Add($Record.name)
    }
    if ($table.ContainsKey($Record.name) -and $table[$Record.name].PSObject.Properties['pending']) {
        if (Invoke-DFPendingRemoval -Name $Record.name -Ownership $table) { $null = $State.Changed.Add($Record.name) }
    }
    $true
}
function Complete-DFToolOwnership {
    <#
    .SYNOPSIS
        Records as owned the checked tools that ended up active, then saves the ownership table if anything changed.
    .DESCRIPTION
        A tool that was blocked or failed isn't recorded: the user may keep
        using it outside DotForge, and its config must still be found later.
    .PARAMETER State
        Select-DFOwnedRecord's State.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State)
    if (-not $State.Readable) { return }
    foreach ($name in $State.Clean) {
        if (-not (Test-DFToolActive $name)) { continue }
        $State.Table[$name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'clean' }
        $null = $State.Changed.Add($name)
    }
    if ($State.Changed.Count) { Save-DFToolOwnership -Ownership $State.Table -Name @($State.Changed) }
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
            node on PATH); the role is recorded in RoleHint so that, if the
            tool turns out to be missing, its detail can name the role.
    .PARAMETER Records
        The requested records. Required tools are appended.
    .PARAMETER ToolDb
        Name -> record for the requested tools. Additions are added here too.
    .PARAMETER RequestedBy
        Name -> RequestedBy. Additions are recorded here.
    .PARAMETER Excluded
        Names excluded by ExcludeTools.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .OUTPUTS
        pscustomobject with three hashtables:
          Edges: tool name -> names it must come after (for Invoke-DFTopoSort -ExtraEdges).
          Blocked: tool name -> why it can't be activated.
          RoleHint: tool name -> the required roles none of whose members is requested.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Excluded = @(),
        [string]$ToolsPath
    )
    $edges = @{}
    $blocked = @{}
    $roleHint = @{}
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $add = {
        param($Record, [string]$By)
        $ToolDb[$Record.name] = $Record
        $RequestedBy[$Record.name] = $By
        $Records.Add($Record)
        $queue.Enqueue($Record)
    }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($record in $Records.ToArray()) { $queue.Enqueue($record) }

    while ($queue.Count) {
        $record = $queue.Dequeue()
        foreach ($req in @($record.requires)) {
            $reference = ConvertFrom-DFToolReference -Reference $req
            if (-not $reference) { continue }
            if ($reference.Kind -eq 'Role') {
                $role = $reference.Name
                $members = @(Get-DFRoleMember -Role $role -Tools @($ToolDb.Values))
                if (-not $members) { $roleHint[$record.name] = @(@($roleHint[$record.name]) + $role | Where-Object { $_ }) }
                foreach ($member in $members) {
                    if ($member.name -ne $record.name) { $edges[$record.name] = @(@($edges[$record.name]) + $member.name | Where-Object { $_ }) }
                }
                continue
            }
            if ($req -in $Excluded) {
                $blocked[$record.name] = "requires $req, which is excluded"
                continue
            }
            if (-not $ToolDb.ContainsKey($req)) {
                $found = Import-DFToolDb -Name $req @pathArgs
                if (-not $found.Count) {
                    $blocked[$record.name] = "requires $req, which has no tool record"
                    continue
                }
                & $add @($found.Values)[0] "requires ($($record.name))"
            }
            $edges[$record.name] = @(@($edges[$record.name]) + $req | Where-Object { $_ })
        }
    }
    [pscustomobject]@{ Edges = $edges; Blocked = $blocked; RoleHint = $roleHint }
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
        $names = @(Get-DFRoleMember -Role $r -Tools @($all.Values) | ForEach-Object name)
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
            Add-DFToolStatusDetail -Status $st -Text "Install-DFTool -Missing will install it $how"
        }
        foreach ($g in $plan.Gaps) {
            $st = $script:DFSessionStatus[$g.Tool]
            if ($st -and $st -in $todo) { Add-DFToolStatusDetail -Status $st -Text "can't install yet: $($g.Reason)" }
        }
    } catch {
        Write-Verbose "DotForge: couldn't work out how missing tools would install: $($_.Exception.Message)"
    }
}

# ---- Private/Invoke-DFToolCompanion.ps1
#Requires -Version 7.2

function Invoke-DFToolCompanion {
    <#
    .SYNOPSIS
        Runs a tool's one-time setup step (setup.seed files and
        Tools/<name>.setup.ps1, if not yet recorded and not skipped), then
        dot-sources its companion Tools/<name>.ps1, setting $DFCurrentTool
        around each.
    .DESCRIPTION
        The regular companion runs on every load. The setup step runs first,
        at most once ever per tool -- see
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md --
        and a setup script is responsible for calling Complete-DFToolSetup
        itself on success (a tool with only setup.seed is recorded here); a thrown error here is caught and warned so the next
        Register-DFTool call retries it. Dot-sourcing runs the companion
        directly in this function's own scope (not a child scope), so
        $DFCurrentTool set here immediately before each dot-source is what
        the companion sees -- the sidecar contract only requires "set
        immediately before, cleared immediately after," not that it happen
        inside Register-DFTool specifically.
    .PARAMETER Tool
        The tool record whose companion(s) to run.
    .PARAMETER ToolsPath
        The resolved Tools/ directory, for a record with no folder of its own
        (one built without the loader). A loaded record's companions are
        next to its JSON (Get-DFToolFolder), which may be the user's folder.
    .PARAMETER SkipSetup
        Tool names (the SkipSetup setting) whose one-time setup step (seeds and
        script) must never run.
    .PARAMETER WonRoles
        Roles this tool won: { Role; Hook; HookRequired }. After the companion
        runs, each role's hook function, if the companion itself defined it,
        is dot-sourced with -Tool and -Role. A throwing hook warns; a missing
        hook warns when HookRequired. Roles the tool lost are never passed, so
        their hooks never run.
    .PARAMETER SetupOnly
        Run only the setup step and return before the companion
        (Invoke-DFToolSetup).
    .PARAMETER SeededPath
        Files the tool's earlier setup seeded, so a note's ifFile doesn't take
        them for the user's own (Invoke-DFToolSetup).
    .OUTPUTS
        None
    #>
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can
    # read it. PSScriptAnalyzer can't see the companion scope, so suppress
    # the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [Parameter(Mandatory)]
        [string]$ToolsPath,

        [string[]]$SkipSetup = @(),

        [AllowEmptyCollection()]
        [object[]]$WonRoles = @(),

        [switch]$SetupOnly,

        [AllowEmptyCollection()]
        [string[]]$SeededPath = @()
    )

    # The companion body and its hooks are dot-sourced into this scope, so they
    # can overwrite any local here ($Tool, $companion, ...). Everything this
    # function needs afterwards is captured first under one unlikely name.
    $__dfCall = @{
        Tool      = $Tool
        Name      = $Tool.name
        Folder    = Get-DFToolFolder -Tool $Tool -Default $ToolsPath
        SkipSetup = @($SkipSetup)
        WonRoles  = @($WonRoles)
        SetupOnly = [bool]$SetupOnly
    }
    $__dfCall.Companion = Join-Path $__dfCall.Folder "$($Tool.name).ps1"
    $__dfCall.Setup = Join-Path $__dfCall.Folder "$($Tool.name).setup.ps1"
    $__dfCall.HasCompanion = Test-Path $__dfCall.Companion -PathType Leaf

    # The one-time setup step runs first, so the companion can rely on what it
    # created: setup.seed files, then Tools/<name>.setup.ps1, which records its
    # own completion. With no script, the seeds are recorded here.
    $__dfCall.HasSetupScript = Test-Path $__dfCall.Setup -PathType Leaf
    $__dfCall.HasSeed = [bool]$__dfCall.Tool.PSObject.Properties['setup']?.Value?.seed
    $__dfCall.HasNotes = [bool]@($__dfCall.Tool.PSObject.Properties['setup']?.Value?.notes | Where-Object { $_ }).Count
    if (($__dfCall.HasSetupScript -or $__dfCall.HasSeed -or $__dfCall.HasNotes) -and
        $__dfCall.Name -notin $__dfCall.SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$__dfCall.Name]) {
        try {
            # Before the seeds: a note's ifFile can then tell an existing file from a seeded one.
            Add-DFDeclaredSetupNote -Tool $__dfCall.Tool -SeededPath $SeededPath
            # Kept pending, so Complete-DFToolSetup records them whoever calls it.
            Set-DFPendingSeedAction -Name $__dfCall.Name -Actions @(Invoke-DFToolSeed -Tool $__dfCall.Tool -ToolsPath $__dfCall.Folder)
            if ($__dfCall.HasSetupScript) {
                $DFCurrentTool = $__dfCall.Tool
                . ($__dfCall.Setup)
            } else {
                Complete-DFToolSetup -Name $__dfCall.Name
            }
        } catch {
            Clear-DFPendingSetupNote -Name $__dfCall.Name
            Clear-DFPendingSeedAction -Name $__dfCall.Name
            Write-Warning "DotForge: $($__dfCall.Name) one-time setup failed: $($_.Exception.Message)"
        }
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }
    if ($__dfCall.SetupOnly) { return }

    if ($__dfCall.HasCompanion) {
        $DFCurrentTool = $__dfCall.Tool
        . ($__dfCall.Companion)
    }

    # Role hooks: plain functions the companion defined in this scope. Only a
    # definition from this tool's own companion file counts, so a stray global
    # of the same name is never mistaken for the hook. Dot-sourced so init
    # scripts run in the same scope the companion body did.
    foreach ($__dfWon in $__dfCall.WonRoles) {
        $__dfCall.Won = $__dfWon
        $__dfHook = if ($__dfCall.HasCompanion) { Get-Item -LiteralPath "function:$($__dfWon.Hook)" -ErrorAction Ignore }
        if ($__dfHook -and $__dfHook.ScriptBlock.File -and
            [System.IO.Path]::GetFullPath($__dfHook.ScriptBlock.File) -eq [System.IO.Path]::GetFullPath($__dfCall.Companion)) {
            $DFCurrentTool = $__dfCall.Tool
            try {
                . $__dfHook.ScriptBlock -Tool $__dfCall.Tool -Role $__dfCall.Won.Role
            } catch {
                Write-Warning "DotForge: $($__dfCall.Name) failed to activate as the $($__dfCall.Won.Role) tool: $($_.Exception.Message)"
            }
        } elseif ($__dfCall.Won.HookRequired) {
            Write-Warning "DotForge: $($__dfCall.Name) declares the $($__dfCall.Won.Role) role but its companion defines no $($__dfCall.Won.Hook) — role not activated."
        }
    }
    Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
}

# ---- Private/Invoke-DFToolSeed.ps1
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

# ---- Private/Invoke-DFTopoSort.ps1
#Requires -Version 7.2

function Invoke-DFTopoSort {
    <#
    .SYNOPSIS
        Topological sort of tool objects using Kahn's algorithm.
        Tools whose after deps are not in the input set are processed normally.
        Cycles emit a warning and fall back to original order.
    .PARAMETER Tools
        Tool records (parsed Tools/*.json objects) to order; each may carry a
        after array of tool names. Names compare case-insensitively.
    .PARAMETER ExtraEdges
        More ordering on top of after: tool name -> names it must come after
        (what requires adds). Names outside -Tools are ignored, as for after.
    .OUTPUTS
        System.Object[]. The same records, dependencies first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Tools = @(),
        [hashtable]$ExtraEdges = @{}
    )

    if ($null -eq $Tools -or $Tools.Count -eq 0) { return @() }

    $toolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Tools) { [void]$toolNames.Add($t.name) }

    $inDegree   = @{}
    $successors = @{}
    foreach ($t in $Tools) {
        $inDegree[$t.name]   = 0
        $successors[$t.name] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($t in $Tools) {
        foreach ($dep in @(@($t.after) + @($ExtraEdges[$t.name]) | Where-Object { $_ } | Select-Object -Unique)) {
            # A dependency outside this call's set (not installed, skipped, or
            # not requested) imposes no order, so it adds no edge.
            if ($toolNames.Contains($dep)) {
                $successors[$dep].Add($t.name)
                $inDegree[$t.name]++
            }
        }
    }

    # Seed the queue in original array order to preserve stable ordering
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($t in $Tools) {
        if ($inDegree[$t.name] -eq 0) { $queue.Enqueue($t.name) }
    }

    $nameToTool = @{}
    foreach ($t in $Tools) { $nameToTool[$t.name] = $t }

    $sorted = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $sorted.Add($nameToTool[$name])
        foreach ($successor in $successors[$name]) {
            $inDegree[$successor]--
            if ($inDegree[$successor] -eq 0) { $queue.Enqueue($successor) }
        }
    }

    # Tools on a cycle never reach in-degree 0, so they never leave the queue
    # stage; any shortfall means a cycle. Registering in the caller's order is
    # safer than dropping those tools.
    if ($sorted.Count -ne $Tools.Count) {
        Write-Warning 'DotForge: circular dependency detected in tool after/requires — falling back to original order'
        return $Tools
    }

    return $sorted.ToArray()
}

# ---- Private/New-DFInstallPlan.ps1
#Requires -Version 7.2

function New-DFInstallPlan {
    <#
    .SYNOPSIS
        Builds the install layer of the session graph: a source and manager per tool, stages in dependency order, and gaps.
    .DESCRIPTION
        For each named tool, picks a source (Resolve-DFInstallSource). A
        manager that is itself one of the named tools counts as planned, so the
        tool waits for it. A tool with no packages that requires a tool in the
        plan is "provided by" it (npm comes with node). Nothing unnamed is
        added, except a manager the user chose for a gap (-Choice), which
        joins the plan. A tool's stage is one more than the highest stage it
        depends on; within a stage, tools are batched per manager.
    .PARAMETER Name
        The tools to install.
    .PARAMETER ToolDb
        Name -> tool record; must include every named tool and the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER Choice
        Source -> manager name, from the user (interactive) or -UseDefaults.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via).
    .OUTPUTS
        PSCustomObject: Items, Stages, Gaps.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{}
    )
    $want = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Name) { if (-not $want.Contains($n)) { $want.Add($n) } }
    # A manager the user chose for a gap joins the plan when it isn't installed.
    foreach ($m in $Choice.Values) {
        if ($m -and -not $want.Contains($m) -and $ToolDb[$m] -and -not (& $IsAvailable $ToolDb[$m])) { $want.Add($m) }
    }

    # How a manager that needs admin rights gets them (Get-DFElevationMethod):
    # an elevator installed now or earlier in this run, Windows' sudo, or a
    # separate admin window; none of them without a person to answer a prompt.
    $elevated = Test-DFElevated
    $elevation = Get-DFElevationMethod -ToolDb $ToolDb -IsAvailable $IsAvailable -Planned @($want)
    $elevatorPlanned = if ($elevation.Method -eq 'Elevator' -and -not (& $IsAvailable $ToolDb[$elevation.Tool])) { $ToolDb[$elevation.Tool] }
    $canElevate = $elevation.Method -ne 'Unavailable'

    $items = [ordered]@{}
    $gaps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $want.Count; $i++) {
        $t = $ToolDb[$want[$i]]
        if (-not $t) { continue }
        # What it comes with: the tools (not roles) it requires.
        $providers = @($t.requires | Where-Object { (ConvertFrom-DFToolReference -Reference $_).Kind -eq 'Tool' })
        $required = @($providers | Where-Object { $want.Contains($_) })
        # (@($null?.X) is a one-element array, so test the object first.)
        $hasPackages = $t.packages -and @($t.packages.PSObject.Properties).Count -gt 0
        if (-not $hasPackages -and $required) {
            $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $null; Manager = $null; Ref = $null; ProvidedBy = $required[0]; DependsOn = [string[]]$required; Stage = 0 }
            continue
        }
        # No packages, and what it comes with isn't being installed: say what to add.
        if (-not $hasPackages -and $providers) {
            $gaps.Add([pscustomobject]@{
                Tool = $t.name; Reason = "comes with $($providers[0]): add $($providers[0]) to install it"
                Options = @(); Source = $null; Dependents = [string[]]@()
            })
            continue
        }
        $planned = [string[]]@($want | Where-Object { $_ -ne $t.name })
        $r = Resolve-DFInstallSource -Tool $t -ToolDb $ToolDb -IsAvailable $IsAvailable -Planned $planned -Choice $Choice -Via $Via -CanElevate $canElevate
        if ($r.Gap) {
            $gaps.Add([pscustomobject]@{
                Tool = $t.name; Reason = $r.Gap; Options = $r.Options
                Source = ($r.Sources | Select-Object -First 1)
                Dependents = [string[]]@()
            })
            continue
        }
        $needsElevator = $r.Block.elevate -and -not $elevated -and $elevatorPlanned
        $deps = @(@($required) + $(if ($want.Contains($r.Manager.name)) { $r.Manager.name }) + $(if ($needsElevator) { $elevatorPlanned.name }) |
            Where-Object { $_ -and $_ -ne $t.name } | Select-Object -Unique)
        $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $r.Source; Manager = $r.Manager; Block = $r.Block; Ref = $r.Ref; ProvidedBy = $null; DependsOn = [string[]]$deps; Stage = 0; AvoidReason = $r.AvoidReason }
    }

    # Tools that depend (transitively) on a gap can't be installed either.
    $blocked = @($gaps.Tool)
    $blockedBy = @{}
    do {
        $more = @($items.Values | Where-Object { $_.Tool -notin $blocked -and @($_.DependsOn | Where-Object { $_ -in $blocked }).Count })
        foreach ($b in $more) {
            $blocked += $b.Tool
            # Credit the dependent to the gap it ultimately waits on (directly, or through another blocked tool).
            $root = $b.DependsOn | Where-Object { $_ -in $blocked } | Select-Object -First 1
            while ($root -and -not ($gaps | Where-Object Tool -eq $root)) { $root = $blockedBy[$root] }
            $blockedBy[$b.Tool] = $root
            $g = $gaps | Where-Object Tool -eq $root | Select-Object -First 1
            if ($g) { $g.Dependents += $b.Tool }
            $items.Remove($b.Tool)
        }
    } while ($more)

    # Stage = 1 + the highest stage depended on (a cycle falls back to stage 1).
    $stageOf = @{}
    $visit = $null
    $visit = {
        param($n, $seen)
        if ($stageOf.ContainsKey($n)) { return $stageOf[$n] }
        if ($n -in $seen) { return 0 }
        $deps = @($items[$n].DependsOn | Where-Object { $items.Contains($_) })
        $s = 1 + (@($deps | ForEach-Object { & $visit $_ (@($seen) + $n) }) + 0 | Measure-Object -Maximum).Maximum
        $stageOf[$n] = $s
        $s
    }
    foreach ($n in @($items.Keys)) { $items[$n].Stage = & $visit $n @() }

    $stages = @(foreach ($g in ($items.Values | Group-Object Stage | Sort-Object { [int]$_.Name })) {
        # One batch per manager and source: uv's PyPI tools and its Pythons are separate commands.
        $batches = @(foreach ($b in ($g.Group | Where-Object Manager | Group-Object { "$($_.Manager.name)|$($_.Source)" })) {
            $m = $b.Group[0].Manager
            $blk = $b.Group[0].Block
            [pscustomobject]@{
                Manager = $m; Source = $b.Group[0].Source; Block = $blk; Items = @($b.Group)
                Elevation = $(if ($blk.elevate -and $elevation.Method -ne 'Direct') { $elevation })
            }
        })
        [pscustomobject]@{ Number = [int]$g.Name; Batches = $batches; Provided = @($g.Group | Where-Object ProvidedBy) }
    })
    [pscustomobject]@{ Items = @($items.Values); Stages = $stages; Gaps = @($gaps) }
}

# ---- Private/New-DFToolPickerFunction.ps1
#Requires -Version 7.2

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs a tool's declarative fzf pickers as global
        functions (and aliases, where declared).
    .DESCRIPTION
        Reads $Tool.picker (one object, or a list of them, as a normalized
        record has) and defines, for each, a global function that calls
        Invoke-DFPicker with it.
        When picker.list_accepts_path is true, the function takes a -Path
        parameter (default '.') appended to the list command. Quoted arguments
        in the list command are supported. Skips a null or "custom" picker,
        and a picker that lacks a function/list pair.
    .PARAMETER Tool
        The normalized tool record declaring the pickers.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    if ($Tool.picker -is [string]) { return }
    foreach ($picker in @($Tool.picker)) {
        if ($picker -is [PSCustomObject] -and $picker.function -and $picker.list) { Set-DFPickerFunction -Picker $picker }
    }
}

function Set-DFPickerFunction {
    <#
    .SYNOPSIS
        Defines one declarative picker's global function, and its alias if declared.
    .PARAMETER Picker
        One declarative picker object (function and list set).
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Picker)

    # A fresh scope per picker, so each function's closure captures its own values.
    $picker = $Picker

    # Everything except the list source is the same for both shapes, so the
    # Invoke-DFPicker call is built once. GetNewClosure captures these locals.
    $action = if ($picker.action -and $picker.action -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $picker.action.Replace('{}', '$v'))
    }
    $parse = if ($picker.parse) { [scriptblock]::Create($picker.parse) }
    # A preview that draws icons may declare a plain one for while icons are off.
    $plain = $picker.PSObject.Properties['preview_plain']?.Value
    $preview = if ($plain -and -not (Test-DFIconsOn)) { $plain } else { $picker.preview }
    $show = {
        param([scriptblock]$List)
        Invoke-DFPicker -List $List -Preview $preview -PreviewWindow $picker.preview_window `
            -Ansi:$picker.ansi -Header $picker.header -Parse $parse -Action $action
    }.GetNewClosure()

    $list = if ($picker.list_accepts_path) {
        [scriptblock]::Create("$($picker.list) @args")
    }
    $fn = if ($picker.list_accepts_path) {
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            # A local copy: the inner .GetNewClosure() captures only this scope's variables,
            # not the outer closure's (the old code's $listParts was $null there).
            $listToInvoke = $list
            & $show { & $listToInvoke $Path }.GetNewClosure()
        }.GetNewClosure()
    } else {
        $list = [scriptblock]::Create($picker.list)
        {
            [CmdletBinding()]
            param()
            & $show $list
        }.GetNewClosure()
    }

    Set-Item -Path "function:global:$($picker.function)" -Value $fn
    if ($picker.alias) {
        Set-Alias -Name $picker.alias -Value $picker.function -Scope Global -Force
    }
}

# ---- Private/New-DFToolWrapper.ps1
#Requires -Version 7.2

function Expand-DFToolToken {
    <#
    .SYNOPSIS
        Expands a tool record's path template: {settings.<name>} from the tool's settings, then ${XDG_*}, then canonicalizes it.
    .DESCRIPTION
        Returns $null (with a verbose message naming the tool and setting) when
        the template names a setting the tool doesn't have, so the caller can
        drop what depends on it instead of using a wrong path. The result goes
        through ConvertTo-DFPath, so a leading ~ expands to $HOME.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Text
        The template, e.g. '{settings.configPath}' or '${XDG_CONFIG_HOME}/lsd/config.yaml'.
    .OUTPUTS
        System.String, or $null when a referenced setting is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Text)
    $settings = $Tool.settings
    foreach ($match in [regex]::Matches($Text, '\{settings\.(\w+)\}')) {
        $setting = $match.Groups[1].Value
        if (-not $settings -or -not [string]$settings.PSObject.Properties[$setting]?.Value) {
            Write-Verbose "DotForge: $($Tool.name) has no setting '$setting' for '$Text'"
            return $null
        }
    }
    $filled = [regex]::Replace($Text, '\{settings\.(\w+)\}', { param($match) [string]$settings.PSObject.Properties[$match.Groups[1].Value].Value })
    ConvertTo-DFPath (Expand-DFXdgPath $filled)
}

function Format-DFWrapperHelp {
    <#
    .SYNOPSIS
        Returns the comment-based help block for a generated executable wrapper.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Name
        The wrapper's command name.
    .PARAMETER Description
        Extra description from a companion that builds the wrapper itself.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Name, [string]$Description)
    $exe = $Tool.executable
    $declared = @(foreach ($group in @($Tool.wrapper.args)) {
        $list = $group.args -join ' '
        if ($group.ifFile) { "$list (when $($group.ifFile) exists)" } else { $list }
    }) -join '; '
    $themeLine = if ($declared.Contains('{theme}')) { "`n        {theme} is the session's $($Tool.name) theme; Set-DFToolTheme switches it." } else { '' }
    $extra = if ($Description) { "`n        $Description" } else { '' }
    @"
    <#
    .SYNOPSIS
        Runs $exe with the arguments DotForge adds.
    .DESCRIPTION
        Wraps $exe and passes, before your own arguments: $declared.$themeLine$extra
        Piped input is passed through. Defined by DotForge from the wrapper block in $($Tool.name).json.
    .EXAMPLE
        $Name --help

        Runs $exe --help with DotForge's arguments.
    .OUTPUTS
        System.String. The output of $exe.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>

"@
}

function New-DFToolWrapper {
    <#
    .SYNOPSIS
        Defines a global function, named after a tool's executable, that runs it with the tool's declared wrapper arguments.
    .DESCRIPTION
        Builds the arguments on every call from wrapper.args: plain strings are
        always passed, an { ifFile, args } group only while its file exists
        ({file} is that path; ifFile may use {settings.<name>}, ${XDG_*} and {theme}),
        and {theme} is the session theme's value (Get-DFSessionThemeValue), so
        Set-DFToolTheme takes effect at once. Your own arguments follow. Piped
        input is passed through (without that branch, a function with no
        process block swallows the pipeline and the tool waits on the
        console). The executable is called by its file name (glow.exe), so the
        wrapper never calls itself.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Invoke
        Runs a non-piped call instead of the plain one, for a companion whose
        wrapper does more (fastfetch). Called as
        & $Invoke <executable> <declared args> <user args> <$MyInvocation>.
    .PARAMETER Description
        Extra text for the generated help's description.
    .OUTPUTS
        None. Defines function:global:<executable name>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [scriptblock]$Invoke,
        [string]$Description
    )
    # The generated function is a closure over these $_df* variables.
    $_dfExe = $Tool.executable
    $_dfToolName = $Tool.name
    $_dfInvoke = $Invoke
    $_dfThemeOf = ${function:Get-DFSessionThemeValue}
    $_dfCanonical = ${function:ConvertTo-DFPath}
    $_dfGroups = @(foreach ($group in @($Tool.wrapper.args)) {
        # A {theme} path is only known per call (Set-DFToolTheme can change it), so it stays a template.
        $file = if ($group.ifFile -and $group.ifFile.Contains('{theme}')) { $group.ifFile }
                elseif ($group.ifFile) { Expand-DFToolToken -Tool $Tool -Text $group.ifFile }
        if ($group.ifFile -and -not $file) { continue }   # its file can't be named: never pass the group
        [pscustomobject]@{
            IfFile     = $file
            UnlessFile = if ($group.PSObject.Properties['unlessFile']?.Value) { Expand-DFToolToken -Tool $Tool -Text $group.unlessFile }
            UnlessArg  = [string[]]@($group.PSObject.Properties['unlessArg']?.Value)
            # A {theme} group fills {file} per call, once its path is known.
            Args   = [string[]]@(foreach ($arg in $group.args) { if ($file -and -not $file.Contains('{theme}')) { $arg.Replace('{file}', $file) } else { $arg } })
        }
    })
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_dfExe)
    $body = (Format-DFWrapperHelp -Tool $Tool -Name $name -Description $Description) + @'
    $theme = [string](& $_dfThemeOf $_dfToolName)
    $declared = @(foreach ($group in $_dfGroups) {
        $file = $group.IfFile
        if ($file -and $file.Contains('{theme}')) {
            if (-not $theme) { continue }
            $file = & $_dfCanonical $file.Replace('{theme}', $theme)
        }
        if ($file -and -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        # Your own config owns this (unlessFile), or you passed the option yourself (unlessArg):
        # a tool that rejects a repeated option must get only yours.
        if ($group.UnlessFile -and (Test-Path -LiteralPath $group.UnlessFile -PathType Leaf)) { continue }
        $yours = foreach ($given in $args) { foreach ($flag in $group.UnlessArg) { if ([string]$given -ceq $flag -or ([string]$given).StartsWith("$flag=", [System.StringComparison]::Ordinal)) { $flag } } }
        if ($yours) { continue }
        foreach ($arg in $group.Args) { $arg.Replace('{file}', [string]$file).Replace('{theme}', $theme) }
    })
    if ($MyInvocation.ExpectingInput) { $input | & $_dfExe @declared @args; return }
    if ($_dfInvoke) { & $_dfInvoke $_dfExe $declared $args $MyInvocation; return }
    & $_dfExe @declared @args
'@
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body).GetNewClosure())
}

# ---- Private/Register-DFFuzzyKeyHandler.ps1
#Requires -Version 7.2

# Ctrl+R / Ctrl+T / Alt+C for fzf-compatible engines that ship no PowerShell bindings
# (fzf, skim). Each tool's role hook passes its own executable; nothing here names
# a tool. Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.

# How a multi-line history entry is shown on one line in the picker.
$script:DFHistoryLineMark = ' ␤ '
# Set by Write-DFKeyMessage: the next redraw goes below the message instead of over it.
$script:DFKeyMessageShown = $false

function Register-DFFuzzyKeyHandler {
    <#
    .SYNOPSIS
        Binds Ctrl+R (history), Ctrl+T (paths) or Alt+C (folders) to an fzf-compatible engine.
    .DESCRIPTION
        History: PSReadLine's saved history, newest first and without repeats,
        is piped to <engine> --no-sort --query <line>, and the pick replaces
        the line. Path: the engine runs its own default command
        (FZF_DEFAULT_COMMAND / SKIM_DEFAULT_COMMAND) with --multi, and the
        picks are inserted at the cursor. Directory: the Alt+C folder list
        (Get-DFDirectoryJumpCandidate) is streamed to <engine> --tiebreak=index,
        and the shell moves to the pick (Enter-DFDirectory). Esc changes nothing. Binds through
        Set-DFRoleKeyHandler, so a binding the user made is kept.
    .PARAMETER Engine
        The executable, e.g. fzf or sk.
    .PARAMETER Key
        History (Ctrl+r, role history-search), Path (Ctrl+t, role path-insert) or
        Directory (Alt+c, role directory-jump).
    .PARAMETER Tool
        The tool's name, for its status.
    .PARAMETER Accent
        Directory only: the #rrggbb color the ranked (zoxide) folders are drawn
        in, usually the engine's theme prompt color; without one they are bold.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][ValidateSet('History', 'Path', 'Directory')][string]$Key,
        [Parameter(Mandatory)][string]$Tool,
        [string]$Accent
    )
    $role, $chord = switch ($Key) {
        'History' { 'history-search', 'Ctrl+r' }
        'Path' { 'path-insert', 'Ctrl+t' }
        'Directory' { 'directory-jump', 'Alt+c' }
    }
    # The handler runs later, outside the module: carry the private function along.
    $invoke = ${function:Invoke-DFFuzzyKey}
    $handler = { & $invoke -Engine $Engine -Key $Key -Accent $Accent }.GetNewClosure()
    # -Bind runs at once, inside Set-DFRoleKeyHandler, so it needs no closure.
    Set-DFRoleKeyHandler -Role $role -Chord $chord -Tool $Tool -Bind {
        Set-PSReadLineKeyHandler -Chord $chord -BriefDescription "DotForge $role ($Engine)" -Description "Fuzzy $role with $Engine (DotForge)" -ScriptBlock $handler
    }
}

function Invoke-DFFuzzyKey {
    <#
    .SYNOPSIS
        Runs one fuzzy key press: picks with the engine, then edits the command line.
    .PARAMETER Engine
        The executable.
    .PARAMETER Key
        History, Path or Directory.
    .PARAMETER Accent
        Directory only: the ranked folders' color (see Register-DFFuzzyKeyHandler).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][ValidateSet('History', 'Path', 'Directory')][string]$Key, [string]$Accent)
    if ($Key -eq 'Directory') { Invoke-DFDirectoryKey -Engine $Engine -Accent $Accent; return }
    $buffer = Get-DFReadLineBuffer
    if ($Key -eq 'History') {
        $shown = [ordered]@{}
        foreach ($entry in @(Get-DFHistoryCandidate -Path (Get-PSReadLineOption).HistorySavePath)) {
            $shown[$entry.Replace("`n", $script:DFHistoryLineMark)] = $entry
        }
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--no-sort', '--query', $buffer.Line) -InputObject ([string[]]@($shown.Keys)))
        if ($picked.Count -and $shown.Contains([string]$picked[0])) { Update-DFReadLineBuffer -Replace $shown[[string]$picked[0]]; return }
    } else {
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--multi'))
        if ($picked.Count) { Update-DFReadLineBuffer -Insert (Format-DFPathInsert -Path $picked); return }
    }
    Update-DFReadLineBuffer
}

function Invoke-DFDirectoryKey {
    <#
    .SYNOPSIS
        Alt+C: streams the folder list to the engine and moves the shell to the pick; the typed line stays.
    .PARAMETER Engine
        The executable.
    .PARAMETER Accent
        The ranked folders' #rrggbb color; anything else draws them bold.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string]$Accent)
    # Shown text -> full path, filled as the lines go out; the pick is mapped back, never parsed.
    # The engine runs with --ansi, so it shows the color and returns the plain text.
    $paths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $escape = [char]27
    $highlight = if ($Accent -cmatch '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        '{0}[38;2;{1};{2};{3}m' -f $escape, [Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16)
    } else { "$escape[1m" }
    $reset = "$escape[0m"
    # Not a closure: it runs inside this call (through Invoke-DFFuzzyEngine), in the
    # module, so it finds the private function and $paths there (and tests can mock it).
    $source = {
        param($StopWhen)
        Get-DFDirectoryJumpCandidate -StopWhen $StopWhen | ForEach-Object {
            $paths[$_.Shown] = $_.Path
            if ($_.Ranked) { "$highlight$($_.Shown)$reset" } else { $_.Shown }
        }
    }
    $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--ansi', '--tiebreak=index') -Stream $source)
    if ($picked.Count -and $paths.ContainsKey([string]$picked[0])) { [void](Enter-DFDirectory -Path $paths[[string]$picked[0]]) }
    Update-DFReadLineBuffer
}

function Get-DFHistoryCandidate {
    <#
    .SYNOPSIS
        PSReadLine's saved history, newest first, without repeats; a multi-line entry stays one entry.
    .DESCRIPTION
        PSReadLine saves a multi-line command with a backtick ending every line
        but the last; those lines are joined with a newline.
    .PARAMETER Path
        The history file (Get-PSReadLineOption).HistorySavePath.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $entries = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Text.StringBuilder]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.EndsWith('`')) { [void]$pending.Append($line.Substring(0, $line.Length - 1)).Append("`n"); continue }
        $entries.Add($pending.ToString() + $line)
        [void]$pending.Clear()
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        if ($entry.Trim() -and $seen.Add($entry)) { $entry }
    }
}

function Format-DFPathInsert {
    <#
    .SYNOPSIS
        Joins picked paths into PowerShell arguments, single-quoting any that isn't plainly a path.
    .DESCRIPTION
        A file name can hold $( ), ;, &, a backtick and more, which PowerShell
        would run when the line is entered. Only names made of letters, digits
        and . / \ : _ + - (not starting with -) stay bare, unless PowerShell
        would read them as a number (1kb, 0x10, 1e3); every other name is
        single-quoted, with every kind of single quote doubled.
    .PARAMETER Path
        The picked paths.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Path)
    @(foreach ($p in $Path) { if ($p -cmatch '^[\w./\\:+][\w./\\:+-]*$' -and -not (Test-DFNumericArgument $p)) { $p } else {
        # PowerShell also ends a single-quoted string at ‘ ’ ‚ ‛; its own escaper doubles them all.
        "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($p) + "'"
    } }) -join ' '
}

function Test-DFNumericArgument {
    <#
    .SYNOPSIS
        Tells whether PowerShell reads a bare command argument as a number (1kb, 0x10, 1e3, +5).
    .PARAMETER Text
        The bare argument.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -notmatch '^[+.]?\d') { return $false }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput("echo $Text", [ref]$tokens, [ref]$errors)
    $argument = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[1]
    -not ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst])
}

function Invoke-DFFuzzyEngine {
    <#
    .SYNOPSIS
        Runs the engine: on the given items, or on its own default command when none are given.
    .PARAMETER Engine
        The executable.
    .PARAMETER Arguments
        Its arguments.
    .PARAMETER InputObject
        Lines to pick from; omit it to let the engine list files itself.
    .PARAMETER Stream
        A source to stream lines from instead, called with one argument: a
        scriptblock that returns $true once the engine has exited, so the source
        can stop early (Invoke-DFFuzzyEngineStream).
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [string[]]$InputObject, [scriptblock]$Stream)
    if ($Stream) { return Invoke-DFFuzzyEngineStream -Engine $Engine -Arguments $Arguments -Source $Stream }
    # PowerShell sends the items as UTF-8 ($OutputEncoding) but decodes the picks with the console's
    # code page (437 by default), which garbles any non-ASCII pick: read them as UTF-8 too.
    $consoleEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        if ($PSBoundParameters.ContainsKey('InputObject')) { $InputObject | & $Engine @Arguments } else { & $Engine @Arguments }
    } finally {
        [Console]::OutputEncoding = $consoleEncoding
    }
}

function Invoke-DFFuzzyEngineStream {
    <#
    .SYNOPSIS
        Runs the engine as a process and writes the source's lines to it as they come, stopping the source when the engine exits.
    .DESCRIPTION
        A PowerShell pipeline keeps running its upstream after a native
        command at its end exits, so a pick made before a long scan ends would
        wait for the scan. Here the source gets a stop check
        ({ engine exited }) and the lines go to the engine's stdin directly,
        UTF-8 both ways.
    .PARAMETER Engine
        The executable name.
    .PARAMETER Arguments
        Its arguments.
    .PARAMETER Source
        Called with the stop check; writes the lines.
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [Parameter(Mandatory)][scriptblock]$Source)
    $exe = (Get-Command -Name $Engine -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    if (-not $exe) { Write-Verbose "DotForge: $Engine not found"; return }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $stopWhen = { $process.HasExited }.GetNewClosure()
        try {
            & $Source $stopWhen | ForEach-Object {
                if (-not $process.HasExited) {
                    try { $process.StandardInput.WriteLine([string]$_); $process.StandardInput.Flush() } catch [System.IO.IOException] { Write-Verbose 'DotForge: the engine closed its input' }
                }
            }
        } finally {
            try { $process.StandardInput.Close() } catch [System.IO.IOException] { Write-Verbose 'DotForge: the engine closed its input' }
        }
        $process.WaitForExit()
        [string[]]@($output.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ })
    } finally {
        $process.Dispose()
    }
}

function Get-DFReadLineBuffer {
    <#
    .SYNOPSIS
        The command line being edited and the cursor position.
    .OUTPUTS
        PSCustomObject: Line, Cursor.
    #>
    [CmdletBinding()]
    param()
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
}

function Update-DFReadLineBuffer {
    <#
    .SYNOPSIS
        Replaces the command line or inserts text at the cursor, then redraws the prompt.
    .PARAMETER Replace
        The new command line.
    .PARAMETER Insert
        Text to insert at the cursor.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([string]$Replace, [string]$Insert)
    if ($Replace) {
        $buffer = Get-DFReadLineBuffer
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $buffer.Line.Length, $Replace)
    } elseif ($Insert) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Insert)
    }
    # A full-screen picker leaves the prompt half-drawn. After a message, redraw below it:
    # a plain redraw starts on the prompt's first row and would wipe it.
    $below = $script:DFKeyMessageShown
    $script:DFKeyMessageShown = $false
    Invoke-DFPromptRedraw -Below:$below
}

function Write-DFKeyMessage {
    <#
    .SYNOPSIS
        Writes one red line from a key handler, on a line of its own, and has the next redraw keep it on screen.
    .PARAMETER Text
        The message.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Red
    $script:DFKeyMessageShown = $true
}

function Invoke-DFPromptRedraw {
    <#
    .SYNOPSIS
        Redraws the prompt and the line being typed: in place, or (-Below) starting on the cursor's row.
    .PARAMETER Below
        Start on the cursor's row, below a message just written.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([switch]$Below)
    if ($Below) { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, [Console]::CursorTop) }
    else { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() }
}

function Remove-DFKeyHandlerCall {
    <#
    .SYNOPSIS
        Removes every Set-PSReadLineKeyHandler call from a tool's init script, so only role winners bind keys.
    .DESCRIPTION
        Parses the script and cuts out each outermost Set-PSReadLineKeyHandler
        command. A script that doesn't parse returns $null: loading nothing is
        safer than loading a script whose bindings couldn't be removed.
    .PARAMETER Script
        The init script text.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return $null }
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-PSReadLineKeyHandler' }, $true))
    $outermost = @($calls | Where-Object {
        $parent = $_.Parent
        while ($parent) { if ($parent -in $calls) { return $false }; $parent = $parent.Parent }
        $true
    })
    $text = $Script
    foreach ($call in @($outermost | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $text = $text.Remove($call.Extent.StartOffset, $call.Extent.EndOffset - $call.Extent.StartOffset)
    }
    $text
}

# ---- Private/Register-DFLazyCompleter.ps1
function Register-DFLazyCompleter {
    <#
    .SYNOPSIS
        Registers a command's completer so that it loads on the first Tab, not at startup.
    .DESCRIPTION
        For a tool whose own completer is slow to load (uv's is a 757 KB script).
        Registers a small native completer for -CommandName. On the first Tab after
        that command it runs -Load once, which must register the real completer
        (Register-ArgumentCompleter, Import-Module, Invoke-Expression of the tool's
        script), then answers that same Tab through TabExpansion2, which now reaches
        the real completer. Later Tabs go straight to the real completer.

        If -Load fails, or registers nothing, the Tab gets no completions (PowerShell
        falls back to file names) and -Load is not run again.
    .PARAMETER CommandName
        The command to complete, e.g. 'uv'.
    .PARAMETER Load
        Registers the real completer. Runs at most once, at the first Tab. A sidecar
        that calls a private helper from it captures it first
        (`$cache = ${function:Get-DFCachedCommandOutput}`) and passes a closure.
    .EXAMPLE
        Register-DFLazyCompleter -CommandName uv -Load { Invoke-Expression (uv generate-shell-completion powershell | Out-String) }

        uv's completer loads the first time Tab is pressed after `uv`.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][scriptblock]$Load
    )

    $state = @{ Loaded = $false }
    $stub = {
        param($wordToComplete, $commandAst, $cursorPosition)
        # A second visit means -Load registered no replacement: answer nothing, never loop.
        if ($state.Loaded) { return }
        $state.Loaded = $true
        try { & $Load } catch {
            Write-Debug "DotForge: loading the $CommandName completer failed: $_"
            return
        }
        # The command's extent stops at its last word; a cursor past it (after a
        # trailing space) means "the next argument", so pad the text out to it.
        $text = $commandAst.Extent.Text
        $column = [Math]::Max($cursorPosition - $commandAst.Extent.StartOffset, 0)
        if ($column -gt $text.Length) { $text = $text.PadRight($column) }
        (TabExpansion2 -inputScript $text -cursorColumn $column).CompletionMatches
    }.GetNewClosure()
    Register-ArgumentCompleter -Native -CommandName $CommandName -ScriptBlock $stub
}

# ---- Private/Register-DFToolAliases.ps1
#Requires -Version 7.2

function Register-DFToolAliases {
    <#
    .SYNOPSIS
        Creates one tool's declared aliases (or wrapper functions, for
        aliases that carry arguments).
    .DESCRIPTION
        For each alias in -Aliases (by default the tool's own top-level
        aliases): a zero-argument alias becomes a plain Set-Alias; an alias
        with args becomes a global wrapper function, removing any colliding
        built-in alias first (Alias outranks Function in command resolution,
        so a built-in like `cd` would otherwise shadow the wrapper).
    .PARAMETER Tool
        The tool record declaring the aliases.
    .PARAMETER Aliases
        The aliases to create. Defaults to the tool's own top-level aliases;
        Invoke-DFToolRegistration passes a won role's aliases here.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [AllowNull()]
        [object]$Aliases = $Tool.aliases
    )

    if (-not $Aliases) { return }

    $Aliases.PSObject.Properties | ForEach-Object {
        $aliasName = $_.Name

        # ConvertTo-DFToolRecord guarantees { command; args[] } per alias.
        $aliasCmd  = $_.Value.command
        $aliasArgs = $_.Value.args

        if (-not $aliasCmd) { return }

        if ($aliasArgs.Count -eq 0) {
            Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
        } else {
            # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
            # function of the same name in command resolution
            # (Alias > Function), so it would shadow the wrapper
            # function below. Remove the colliding global alias first.
            # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
            if (Test-Path "Alias:\$aliasName") {
                Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
            }
            $capturedCmd  = $aliasCmd
            $capturedArgs = $aliasArgs
            Set-Item -Path "function:global:$aliasName" -Value {
                & $capturedCmd @capturedArgs @args
            }.GetNewClosure()
        }
    }
}

# ---- Private/Register-DFToolSteps.ps1
#Requires -Version 7.2

# The per-session steps Invoke-DFSessionActivation runs: resolve role winners,
# register each tool, and report coreutils conflicts.

function Write-DFDefaultsRoleWarning {
    <#
    .SYNOPSIS
        Warns about Defaults entries that name an unknown role or a category (which has no winner).
    .PARAMETER Defaults
        The session Defaults hashtable.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Defaults,
        [Parameter(Mandatory)][hashtable]$RoleDb
    )
    foreach ($roleName in @($Defaults.Keys)) {
        if (-not $RoleDb.ContainsKey($roleName)) {
            Write-Warning "DotForge: Defaults['$roleName'] names an unknown role — ignoring. See Get-DFRole for the list."
        } elseif ($RoleDb[$roleName].kind -eq 'category') {
            Write-Warning "DotForge: Defaults['$roleName']: '$roleName' is a category, which has no winner — every member is configured. Ignoring."
        }
    }
}

function Get-DFRoleCandidates {
    <#
    .SYNOPSIS
        Builds a mapping of single-kind roles to their candidate tools in the registration set.
    .PARAMETER Tools
        The tools being registered in this call.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .PARAMETER Defaults
        The session Defaults hashtable (for optIn evaluation).
    .OUTPUTS
        System.Collections.Hashtable. Role name -> List[object] of candidate tools.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()][object[]]$Tools = @(),
        [Parameter(Mandatory)][hashtable]$RoleDb,
        [hashtable]$Defaults = @{}
    )
    # One pass over the registration set builds role -> candidates; this runs
    # at every startup, so it avoids a pipeline per role. Topo-sorting an
    # empty set can hand back a lone $null, hence the null check.
    $candidatesByRole = @{}
    foreach ($tool in $Tools) {
        if (-not $tool) { continue }
        $available = $null
        foreach ($rp in $tool.roles.PSObject.Properties) {
            $roleName = $rp.Name
            if (-not $RoleDb.ContainsKey($roleName)) {
                # Stay quiet when no definitions loaded at all (Get-DFRoleDb already
                # warned), and for a legacy v1 role string, which was free-form.
                if ($RoleDb.Count -and -not $rp.Value.legacy) { Write-Warning "DotForge: $($tool.name) declares unknown role '$roleName' — ignored." }
                continue
            }
            if ($RoleDb[$roleName].kind -ne 'single') { continue }
            # optIn is generic role metadata: an optional member joins the
            # candidate set only when the user selected it for this role.
            if ($rp.Value.optIn -and $Defaults[$roleName] -ine $tool.name) { continue }
            if ($null -eq $available) { $available = Test-DFToolAvailable -Executable $tool.executable -Type $tool.type }
            if (-not $available) { continue }
            if (-not $candidatesByRole.ContainsKey($roleName)) { $candidatesByRole[$roleName] = [System.Collections.Generic.List[object]]::new() }
            $candidatesByRole[$roleName].Add($tool)
        }
    }
    $candidatesByRole
}

function Select-DFRoleWinner {
    <#
    .SYNOPSIS
        Picks the winner object for one single-kind role among its candidates.
    .PARAMETER Role
        The single-kind role name.
    .PARAMETER Candidates
        The candidates for this role.
    .PARAMETER Preferred
        The tool name the user requested in Defaults for this role, or $null.
    .PARAMETER ToolDb
        The tool database (for membership checks of Defaults entries).
    .OUTPUTS
        pscustomobject or $null. Role, Winner, Reason, Candidates, Ranked, Preferred.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [string]$Preferred,
        [Parameter(Mandatory)][hashtable]$ToolDb
    )
    $winner = $null
    $reason = $null
    $chosen = $Preferred
    if (-not [string]::IsNullOrWhiteSpace($chosen)) {
        $chosenTool = $ToolDb[$chosen]
        if (-not $chosenTool) {
            # A role is only ever filled by a tool the user asked for.
            Write-Warning "DotForge: Defaults['$Role'] names '$chosen', which is not requested in Tools — using priority. Add '$chosen' to Tools to use it."
        } elseif (-not $chosenTool.roles.PSObject.Properties[$Role]) {
            $members = @(Get-DFRoleMember -Role $Role -Tools @($ToolDb.Values) | ForEach-Object name)
            Write-Warning "DotForge: Defaults['$Role'] names '$chosen', which is not a $Role tool (requested ones: $($members -join ', ')) — using priority."
        } else {
            # Report the tool's own spelling, not the user's (names compare case-insensitively).
            foreach ($c in $Candidates) { if ($c.name -eq $chosen) { $winner = $c.name; $reason = 'Defaults'; break } }
        }
    }
    if ($Candidates.Count -eq 0) { return $null }
    # Rank by priority (highest first), ties by name. An insertion sort over
    # the usual one to three candidates; no pipeline, since this runs at startup.
    $ranked = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Candidates) {
        $i = 0
        while ($i -lt $ranked.Count) {
            $o = $ranked[$i]
            $cp = $c.roles.$Role.priority
            $op = $o.roles.$Role.priority
            if ($cp -gt $op -or ($cp -eq $op -and [string]::Compare($c.name, $o.name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { break }
            $i++
        }
        $ranked.Insert($i, $c)
    }
    # The user's preferred member, when it is requested and really in the role.
    $preferredMember = if (-not [string]::IsNullOrWhiteSpace($chosen) -and $ToolDb[$chosen] -and
        $ToolDb[$chosen].roles.PSObject.Properties[$Role]) { $ToolDb[$chosen].name }
    if (-not $winner) {
        $winner = $ranked[0].name
        # The preferred tool is requested but unavailable: another requested
        # tool stands in, and the end-of-load notice says so.
        $reason = if ($preferredMember) { 'fallback' } elseif ($Candidates.Count -eq 1) { 'sole' } else { 'priority' }
    }
    $names = [string[]]@(foreach ($c in $Candidates) { $c.name })
    [array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
    [pscustomobject]@{
        Role       = $Role
        Winner     = $winner
        Reason     = $reason
        Candidates = $names
        Ranked     = [string[]]@(foreach ($c in $ranked) { $c.name })
        Preferred  = $preferredMember
    }
}

function Get-DFRoleWinners {
    <#
    .SYNOPSIS
        Chooses one winner per single-kind role for this registration.
    .DESCRIPTION
        Candidates are the tools in -Tools that declare the role and are
        installed (in a session, -Tools holds only the requested tools). A
        membership with roles.<role>.optIn true is a candidate only when
        Defaults[<role>] names that tool. The winner is the Defaults entry when
        it names a candidate (reason 'Defaults'). When the Defaults tool is
        requested but unavailable, the highest-priority candidate stands in
        (reason 'fallback', Preferred names the tool it stands in for).
        Otherwise the highest roles.<role>.priority wins, ties broken by name
        (reason 'priority', or 'sole' for a single candidate). A Defaults
        entry naming a tool that is not requested warns.
        A Defaults entry naming an unknown role or a non-member also warns. A tool
        declaring a role the definitions don't know warns and is ignored for
        it. Category roles and roles without candidates are left out. Never
        throws.
    .PARAMETER ToolDb
        The tool database (for membership checks of Defaults entries).
    .PARAMETER Tools
        The tools being registered in this call.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        System.Collections.Hashtable. Role name -> @{ Role; Winner; Reason; Candidates (by name); Ranked (by priority); Preferred }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [AllowEmptyCollection()][object[]]$Tools = @(),
        [hashtable]$RoleDb = (Get-DFRoleDb)
    )
    $winners = @{}
    $defaults = Get-DFConfig Defaults -Default @{}

    Write-DFDefaultsRoleWarning -Defaults $defaults -RoleDb $RoleDb

    $candidatesByRole = Get-DFRoleCandidates -Tools $Tools -RoleDb $RoleDb -Defaults $defaults

    foreach ($roleName in @($RoleDb.Keys)) {
        if ($RoleDb[$roleName].kind -ne 'single') { continue }
        $candidates = if ($candidatesByRole.ContainsKey($roleName)) { $candidatesByRole[$roleName] } else { @() }
        $winnerObject = Select-DFRoleWinner -Role $roleName -Candidates $candidates -Preferred $defaults[$roleName] -ToolDb $ToolDb
        if ($winnerObject) {
            $winners[$roleName] = $winnerObject
        }
    }
    $winners
}

function Test-DFHasEntries {
    <#
    .SYNOPSIS
        True when a parsed JSON object (such as a role block's env or aliases) has at least one property.
    .PARAMETER Object
        The object, or $null.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Object)
    $null -ne $Object -and @($Object.PSObject.Properties).Count -gt 0
}

function Invoke-DFToolRegistration {
    <#
    .SYNOPSIS
        Applies one installed tool's configuration: XDG, environment, the declared theme, aliases, picker, won roles, companion.
    .DESCRIPTION
        The per-tool body of Register-DFTool. For each role the tool won, its role
        block's env (through Set-DFEnv) and aliases are applied before the
        companion runs, and its role hook is called right after it (by
        Invoke-DFToolCompanion). For a role with behaviors, its aliases and
        pickers are built from the winner's flags (Get-DFRoleBehaviorAlias,
        Get-DFRolePicker). Roles it lost are skipped entirely. Anything a
        companion writes to the output stream passes through to the caller.
    .PARAMETER Tool
        The normalized tool record.
    .PARAMETER Context
        What the whole activation shares (Invoke-DFSessionActivation builds it):
          RoleWinners: Get-DFRoleWinners result.
          RoleDb: role definitions (Get-DFRoleDb).
          ToolsPath: the resolved Tools folder holding companions.
          SkipSetup: tool names whose one-time setup script must not run.
    .OUTPUTS
        None of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$Context
    )
    $RoleWinners = $Context.RoleWinners
    $RoleDb = $Context.RoleDb

    # Notes about values kept over this tool's own are rebuilt by every registration.
    Clear-DFEnvKeptNote -Tool $Tool.name
    Clear-DFToolNote -Tool $Tool.name
    Set-DFToolXdgConfig -Tool $Tool

    # Non-XDG settings apply regardless of xdg.method. Expand-DFXdgPath expands
    # ${XDG_*} and passes flag strings through byte-for-byte.
    if ($Tool.env) {
        foreach ($var in $Tool.env.PSObject.Properties) {
            Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Tool $Tool.name
        }
    }

    # A declared theme is resolved afresh on each registration (the config may
    # have changed), applied to theme.env, and cached for the companion and wrappers.
    if ($Tool.theme) {
        if ($script:DFSessionThemes -is [hashtable]) { $script:DFSessionThemes.Remove($Tool.name) }
        Set-DFToolThemeEnv -Tool $Tool -Theme (Get-DFToolTheme -Tool $Tool)
    }

    # A declared executable wrapper; custom ones are built by the companion (New-DFToolWrapper -Invoke).
    if ($Tool.wrapper -and -not $Tool.wrapper.custom) { New-DFToolWrapper -Tool $Tool }

    # A legacy (v1 "role" string) loser keeps v1 behavior: its top-level aliases
    # that the role reserves are left to the winner.
    $suppressed = @(foreach ($rp in $Tool.roles.PSObject.Properties) {
        $won = $RoleWinners[$rp.Name]
        if ($rp.Value.legacy -and $won -and $won.Winner -ne $Tool.name -and $RoleDb.ContainsKey($rp.Name)) {
            $RoleDb[$rp.Name].reserved.aliases
        }
    })
    $topAliases = $Tool.aliases
    if ($suppressed -and $topAliases) {
        $kept = [ordered]@{}
        foreach ($a in $topAliases.PSObject.Properties) {
            if ($a.Name -in $suppressed) { Write-Verbose "DotForge: $($Tool.name) alias '$($a.Name)' left to the winner of its role"; continue }
            $kept[$a.Name] = $a.Value
        }
        $topAliases = [pscustomobject]$kept
    }
    Register-DFToolAliases -Tool $Tool -Aliases $topAliases
    New-DFToolPickerFunction -Tool $Tool

    $wonRoles = @(Invoke-DFWonRoles -Tool $Tool -Context $Context)

    Invoke-DFToolCompanion -Tool $Tool -ToolsPath $Context.ToolsPath -SkipSetup @($Context.SkipSetup) -WonRoles @($wonRoles)
}

function Invoke-DFWonRoles {
    <#
    .SYNOPSIS
        Applies the roles a tool won: each role block's env and aliases, or for a role with behaviors the aliases and pickers built from the winner's flags.
    .PARAMETER Tool
        The normalized tool record.
    .PARAMETER Context
        The activation context (RoleWinners, RoleDb).
    .OUTPUTS
        One { Role; Hook; HookRequired } per won role, for Invoke-DFToolCompanion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$Context
    )
    $RoleWinners = $Context.RoleWinners
    $RoleDb = $Context.RoleDb
    # Enumerate properties rather than .Name: on a tool with no roles,
    # member enumeration would yield a single $null.
    $roleNames = @(foreach ($rp in $Tool.roles.PSObject.Properties) { $rp.Name }) | Sort-Object
    foreach ($roleName in $roleNames) {
        $won = $RoleWinners[$roleName]
        if (-not $won -or $won.Winner -ne $Tool.name) { continue }
        $block = $Tool.roles.$roleName
        # An explicit Defaults choice overrides a value set outside DotForge; an auto-pick doesn't.
        $explicit = if ($won.Reason -eq 'Defaults') { "`$DFConfig.Defaults.$roleName is '$($won.Winner)'; using $($won.Winner)" }
        if ($block.env) {
            foreach ($var in $block.env.PSObject.Properties) {
                # ${DF_TOOL_EXE}: the winner's own executable path (see Resolve-DFToolExecutable).
                $value = [string]$var.Value
                if ($value.Contains('${DF_TOOL_EXE}')) { $value = $value.Replace('${DF_TOOL_EXE}', (ConvertTo-DFToolExePathToken -Tool $Tool)) }
                Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $value) -Tool $Tool.name -ExplicitReason $explicit
            }
        }
        $roleDefinition = $RoleDb[$roleName]
        # Behaviors apply to a member that maps the role's words (flags). A legacy (v1
        # role string) record, or one written before the role had behaviors, keeps its
        # own aliases, so an existing setup never loses flags it had.
        $behaviors = $roleDefinition.behaviors -and -not $block.legacy -and $block.flags
        if ($behaviors) {
            # The role defines its aliases and pickers in words; the winner's flags fill them in.
            if (Test-DFHasEntries $block.aliases) {
                Write-Verbose "DotForge: $($Tool.name)'s own aliases for '$roleName' are ignored; the role defines them (behaviors)."
            }
            Register-DFToolAliases -Tool $Tool -Aliases (Get-DFRoleBehaviorAlias -RoleDefinition $roleDefinition -Block $block -Tool $Tool)
            foreach ($picker in Get-DFRolePicker -RoleDefinition $roleDefinition -Block $block -Tool $Tool) { Set-DFPickerFunction -Picker $picker }
            $built = Get-DFRoleBehaviorEnv -RoleDefinition $roleDefinition -Block $block -Tool $Tool
            foreach ($var in $built.Keys) { Set-DFEnv -Name $var -Value $built[$var] -Tool $Tool.name -ExplicitReason $explicit }
        } elseif ($block.aliases) {
            Register-DFToolAliases -Tool $Tool -Aliases $block.aliases
        }
        [pscustomobject]@{
            Role         = $roleName
            Hook         = $roleDefinition.hook
            # An empty {} block is still an object, so count what it holds.
            HookRequired = -not ($behaviors -or (Test-DFHasEntries $block.env) -or (Test-DFHasEntries $block.aliases) -or
                $block.legacy -or $roleDefinition.emptyMembership)
        }
    }
}

function Write-DFConflictNotice {
    <#
    .SYNOPSIS
        Warns once, with the fix, when Coreutils for Windows shadows DotForge commands.
    .DESCRIPTION
        One consolidated warning rather than one per tool. Costs nothing when
        coreutils is absent, and stops once the conflict is resolved. Resolving
        it needs elevation and is the user's choice, so this only prints the
        commands.
    .PARAMETER Tools
        The tool records whose command names to check (the session's active tools).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Tools = @())
    $conflicts = @(Get-DFCommandConflict -Tools $Tools -ErrorAction Ignore)
    if (-not $conflicts) { return }
    $names = ($conflicts.Command | Sort-Object) -join ' '
    # DisableWith, not Command: 'la' is not a coreutils utility and the manager
    # rejects it; disabling 'ls' is what removes it.
    $disable = ($conflicts.DisableWith | Sort-Object -Unique) -join ' '
    Write-Warning @"
DotForge: coreutils shadows $($conflicts.Count) DotForge command(s) before PowerShell resolves them: $names
  These will not reach DotForge's version at the prompt, even though Get-Command reports otherwise.
  Keep DotForge's:  coreutils-manager disable $disable   (run elevated, once)
  Keep coreutils':  add IgnoreConflicts = @($(($conflicts.Command | Sort-Object | ForEach-Object { "'$_'" }) -join ', ')) to your Start-DFSession -Config
  Silence entirely: add SkipConflictCheck = `$true to your Start-DFSession -Config
"@
}

# ---- Private/Resolve-DFRequestedTools.ps1
#Requires -Version 7.2

function Resolve-DFRequestedTools {
    <#
    .SYNOPSIS
        Turns the Tools and ExcludeTools config lists into the session's request set.
    .DESCRIPTION
        Pure: names in, entries out. No tool record is read.
          1. Tools: +group expands to its members; a tool name stays itself
             (matched case-insensitively, returned in its canonical case).
             Each entry records what requested it ('Tools' or '+group'); a
             direct entry wins over a group. Duplicates collapse, first-seen
             order is kept.
          2. ExcludeTools (tools and +groups) mark matching entries Excluded;
             an exclusion always wins. Excluding something that wasn't
             requested warns.
        Unknown tools and groups warn ("did you mean") and are left out; they
        never stop the session.
    .PARAMETER Tools
        The Tools config list.
    .PARAMETER ExcludeTools
        The ExcludeTools config list.
    .PARAMETER GroupDb
        Get-DFGroupDb output.
    .PARAMETER KnownTools
        Every tool name DotForge has a record for (canonical case).
    .PARAMETER Source
        Where the Tools names came from, for warnings. Default: 'Tools'.
    .OUTPUTS
        pscustomobject: Name, RequestedBy, Excluded.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Tools = @(),
        [AllowEmptyCollection()][string[]]$ExcludeTools = @(),
        [Parameter(Mandatory)][System.Collections.IDictionary]$GroupDb,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownTools,
        [string]$Source = 'Tools'
    )

    $canonical = @{}   # case-insensitive name -> canonical name
    foreach ($t in $KnownTools) { $canonical[$t] = $t }
    $groupNames = [string[]]@($GroupDb.Keys)

    # Expands one list entry to canonical tool names, warning about unknowns.
    $expand = {
        param([string]$Entry, [string]$Where)
        $isGroup = $Entry.StartsWith('+')
        if ($isGroup -and -not $GroupDb.Contains($Entry.Substring(1))) {
            $s = Get-DFFieldSuggestion -Name $Entry.Substring(1) -Known $groupNames
            Write-Warning "DotForge: $Where names unknown group '$Entry'$(if ($s) { " — did you mean '+$s'?" }). Run Get-DFToolGroup to list groups."
            return
        }
        foreach ($name in @(Expand-DFGroupEntry -Entry $Entry -GroupDb $GroupDb)) {
            if ($canonical.ContainsKey($name)) { $canonical[$name] }
            elseif (-not $isGroup) {
                $s = Get-DFFieldSuggestion -Name $Entry -Known $KnownTools
                Write-Warning "DotForge: $Where names unknown tool '$Entry'$(if ($s) { " — did you mean '$s'?" })."
            }
        }
    }

    $entries = [ordered]@{}   # canonical name -> entry
    foreach ($item in $Tools) {
        if (-not $item) { continue }
        $by = $item.StartsWith('+') ? $item : 'Tools'
        foreach ($name in @(& $expand $item $Source)) {
            if (-not $entries.Contains($name)) {
                $entries[$name] = [pscustomobject]@{ Name = $name; RequestedBy = $by; Excluded = $false }
            } elseif ($by -eq 'Tools') {
                $entries[$name].RequestedBy = 'Tools'
            }
        }
    }

    foreach ($item in $ExcludeTools) {
        if (-not $item) { continue }
        foreach ($name in @(& $expand $item 'ExcludeTools')) {
            if ($entries.Contains($name)) {
                $entries[$name].Excluded = $true
            } elseif (-not $item.StartsWith('+')) {
                Write-Warning "DotForge: ExcludeTools names '$name', which is not requested in Tools."
            }
        }
    }

    $entries.Values
}

function Expand-DFGroupEntry {
    <#
    .SYNOPSIS
        Expands one Tools/ExcludeTools entry: '+group' to its member names, a tool name to itself.
    .DESCRIPTION
        The one place a +group entry is expanded. An unknown group expands to
        nothing; names are returned as the group lists them, unchecked.
    .PARAMETER Entry
        A tool name or '+group'.
    .PARAMETER GroupDb
        Get-DFGroupDb output.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$GroupDb
    )
    if (-not $Entry.StartsWith('+')) { return $Entry }
    $group = $Entry.Substring(1)
    if ($GroupDb.Contains($group)) { $GroupDb[$group].Tools }
}

# ---- Private/Resolve-DFThemeName.ps1
#Requires -Version 7.2

function Resolve-DFThemeName {
    <#
    .SYNOPSIS
        Translates a canonical theme family name to a tool's native dialect
        using that tool's own themeMap. A pure, file-free translator.
    .DESCRIPTION
        If $ThemeMap contains a key equal to $Name (case-insensitive), returns
        the mapped dialect. Otherwise returns $Name unchanged — so a per-tool
        override that is the tool's own native name, or any non-canonical value,
        passes through to the sidecar's own built-in validation. A $null or
        empty map always passes through. The resolver never validates or falls
        back; that stays in the sidecars.
    .PARAMETER Name
        The configured theme name (from Get-DFConfiguredTheme's chain).
    .PARAMETER ThemeMap
        The target tool's themeMap object (canonical -> dialect), typically
        $DFCurrentTool.themeMap. May be $null.
    .OUTPUTS
        [string] the tool's dialect, or $Name unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [pscustomobject]$ThemeMap
    )

    if ($null -ne $ThemeMap) {
        $prop = $ThemeMap.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($prop) { return [string]$prop.Value }
    }
    $Name
}

# ---- Private/Resolve-DFToolExecutable.ps1
#Requires -Version 7.2

function Resolve-DFToolExecutable {
    <#
    .SYNOPSIS
        Returns the full path of a tool's executable, skipping copies its executableExclude patterns rule out.
    .DESCRIPTION
        Walks Get-Command <executable> -All (PATH order) and returns the first path
        that matches none of the tool's executableExclude globs (case-insensitive),
        or $null when none qualifies. Used only to expand ${DF_TOOL_EXE}; tool
        detection (Test-DFToolAvailable) ignores the exclusions.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $exclude = @($Tool.PSObject.Properties['executableExclude']?.Value)
    foreach ($cmd in @(Get-Command $Tool.executable -All -CommandType Application -ErrorAction Ignore)) {
        $path = $cmd.Source
        if (-not $path) { continue }
        $skip = $false
        foreach ($pattern in $exclude) { if ($pattern -and $path -like $pattern) { $skip = $true; break } }
        if (-not $skip) { return $path }
    }
}

function ConvertTo-DFToolExePathToken {
    <#
    .SYNOPSIS
        The value ${DF_TOOL_EXE} expands to: the tool's resolved path with forward slashes, quoted when it holds a space, else its bare name.
    .DESCRIPTION
        Forward slashes keep sh -c based callers (git's pager handling) from
        treating backslashes as escapes; Windows programs accept them. With no
        qualifying copy, the executable name without .exe, which leaves the
        choice to PATH as before.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $path = Resolve-DFToolExecutable -Tool $Tool
    if (-not $path) { return [IO.Path]::GetFileNameWithoutExtension($Tool.executable) }
    $path = $path -replace '\\', '/'
    if ($path -match '\s') { "`"$path`"" } else { $path }
}

# ---- Private/Set-DFEnv.ps1
#Requires -Version 7.2

function Get-DFEnvState {
    <#
    .SYNOPSIS
        Returns this session's record of the environment variables DotForge wrote, warned about and kept.
    .DESCRIPTION
        Kept in a session global, not a $script: variable, so Import-Module
        DotForge -Force doesn't forget which values DotForge itself wrote.
        Written maps variable -> the value DotForge last wrote: a current value
        that differs was set outside DotForge (profile, parent shell, system
        environment). Warned holds the conflicts already reported this session.
        Kept maps tool -> variable -> a note naming the outside value kept over
        what the tool wanted (Get-DFEnvKeptNote).
    .OUTPUTS
        System.Collections.Hashtable. @{ Written = @{}; Warned = @{}; Kept = @{} }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($global:DFEnvState -isnot [hashtable]) {
        $global:DFEnvState = @{ Written = @{}; Warned = @{}; Kept = @{} }
    }
    $global:DFEnvState
}

function Set-DFEnv {
    <#
    .SYNOPSIS
        Sets an environment variable for a tool, without overriding a value the user set outside DotForge.
    .DESCRIPTION
        The one precedence rule for every variable DotForge writes (xdg.vars,
        env, theme.env, role env, theme apply functions):
          1. The current value already equals -Value: nothing to do.
          2. The variable is unset, or still holds what DotForge last wrote: write it.
          3. It was set outside DotForge: keep it and note that for -Tool's
             status, unless -ExplicitReason says the user chose this value in
             DotForge's config (or by running a command). Then overwrite it and
             warn, once per session for each conflict, naming both settings.
        Writing or matching a variable drops the tool's kept note for it.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        The value to write (already expanded).
    .PARAMETER Tool
        The tool the value belongs to; a kept value is noted against it.
    .PARAMETER ExplicitReason
        Set when the user chose the value explicitly, e.g.
        "`$DFConfig.Defaults.pager is 'moar'; using moar". It completes the
        warning "<Name> was '<current>' but <reason>."
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Tool,
        [string]$ExplicitReason
    )
    $state = Get-DFEnvState
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $state.Written[$Name] = $Value
        if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
        return
    }
    $setOutside = $current -and $state.Written[$Name] -cne $current
    if ($setOutside) {
        if (-not $ExplicitReason) {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Tool's '$Value'."
            if (-not $state.Kept[$Tool]) { $state.Kept[$Tool] = [ordered]@{} }
            $state.Kept[$Tool][$Name] = "$Name kept as set outside DotForge ('$(Format-DFEnvValue $current)'); DotForge wanted '$(Format-DFEnvValue $Value)'"
            return
        }
        # Once per session: `. $PROFILE` re-runs the profile's own assignment,
        # and the same contradiction needs reporting only once.
        $conflict = "$Name|$current|$ExplicitReason"
        if (-not $state.Warned.ContainsKey($conflict)) {
            $state.Warned[$conflict] = $true
            Write-Warning ("DotForge: $Name was '$(Format-DFEnvValue $current)' but $ExplicitReason.`n" +
                '  Remove one of the two settings to silence this.')
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $state.Written[$Name] = $Value
    if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
}

function Get-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Returns the notes for variables kept over what a tool wanted, in the order they were kept.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    $notes = (Get-DFEnvState).Kept[$Tool]
    if ($notes) { [string[]]@($notes.Values) }
}

function Clear-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Forgets a tool's kept-variable notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    (Get-DFEnvState).Kept.Remove($Tool)
}

function Format-DFEnvValue {
    <#
    .SYNOPSIS
        Shortens a variable's value for a message: over 60 characters keeps the first 57 and adds "...".
    .PARAMETER Value
        The value.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($Value.Length -gt 60) { $Value.Substring(0, 57) + '...' } else { $Value }
}

# ---- Private/Set-DFRoleFallback.ps1
#Requires -Version 7.2

function Set-DFRoleFallback {
    <#
    .SYNOPSIS
        Applies each single role's fallback env when no tool in the session fills the role.
    .DESCRIPTION
        A role in data/roles.json may name a fallback (pager: PAGER = more). It applies
        only when this activation picked no winner and no member is active in the session
        (a later Register-DFTool -Name for another tool must not undo an earlier winner).
        Written through Set-DFEnv, so a value set outside DotForge is kept.
    .PARAMETER RoleDb
        Get-DFRoleDb.
    .PARAMETER RoleWinners
        This activation's Get-DFRoleWinners result.
    .PARAMETER SessionTools
        The session's tool records (each role's members are found among them).
    .OUTPUTS
        System.String[]: the roles whose fallback was applied.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$RoleDb,
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SessionTools
    )
    [string[]]@(foreach ($role in $RoleDb.Values) {
        if (-not $role.fallback -or $RoleWinners.ContainsKey($role.name)) { continue }
        $active = @(Get-DFRoleMember -Role $role.name -Tools $SessionTools | Where-Object { Test-DFToolActive $_.name })
        if ($active) { continue }
        foreach ($var in $role.fallback.env.PSObject.Properties) {
            Set-DFEnv -Name $var.Name -Value ([string]$var.Value) -Tool "$($role.name) role"
        }
        $role.name
    })
}

# ---- Private/Set-DFRoleKeyHandler.ps1
#Requires -Version 7.2

# Chords DotForge bound this session, so registering a tool again doesn't mistake
# DotForge's own earlier binding for one the user made.
$script:DFBoundKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Set-DFRoleKeyHandler {
    <#
    .SYNOPSIS
        Binds a key-binding role's PSReadLine chord for its winner, keeping a binding the user made.
    .DESCRIPTION
        The history-search and path-insert roles bind only through this (it is
        their reserved code). When the chord already runs a custom handler that
        DotForge didn't bind this session, it is kept and the tool's status says
        so, unless Defaults names this tool for the role: then it is replaced
        with a warning. When PSReadLine isn't loaded (a redirected host, a
        VS Code task) nothing is bound, and PSReadLine isn't loaded for it.
    .PARAMETER Role
        The role name.
    .PARAMETER Chord
        The PSReadLine chord, e.g. 'Ctrl+r'.
    .PARAMETER Tool
        The winning tool's name.
    .PARAMETER Bind
        Binds the chord: Set-PSReadLineKeyHandler, or the tool's own option.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Chord,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][scriptblock]$Bind
    )
    # pwsh 7 always ships PSReadLine; an interactive console has already loaded it, a redirected host hasn't.
    if (-not (Get-Module -Name PSReadLine)) { return }
    $existing = Get-PSReadLineKeyHandler -Chord $Chord -ErrorAction Ignore | Select-Object -First 1
    if ($existing -and -not $script:DFBoundKeys.Contains($Chord) -and (Test-DFCustomKeyHandler -Handler $existing)) {
        $winner = if ($script:DFSessionRoleWinners) { $script:DFSessionRoleWinners[$Role] }
        if (-not ($winner -and $winner.Reason -eq 'Defaults')) {
            Add-DFToolNote -Tool $Tool -Note "kept your own $Chord binding, so $Tool doesn't bind it ($Role)"
            return
        }
        Write-Warning "DotForge: Defaults names $Tool for $Role; replacing your $Chord binding."
    }
    & $Bind
    [void]$script:DFBoundKeys.Add($Chord)
}

function Test-DFCustomKeyHandler {
    <#
    .SYNOPSIS
        True when a PSReadLine key handler is a custom one rather than a PSReadLine function.
    .PARAMETER Handler
        A Get-PSReadLineKeyHandler result.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Handler)
    $readLine = 'Microsoft.PowerShell.PSConsoleReadLine' -as [type]
    if (-not $readLine) { return $false }
    $name = [string]$Handler.Function
    -not ($name -and $readLine.GetMethod($name))
}

# ---- Private/Set-DFToolXdgConfig.ps1
#Requires -Version 7.2

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars through Set-DFEnv (a value set outside DotForge is kept) and creates xdg.dirs;
        'manual' warns with any instructions; 'wrapper' and 'default' are
        no-ops here (handled by a companion .ps1, or not needed at all). A
        default config file is seeded once by the setup step (setup.seed,
        Invoke-DFToolSetup), never here on every load.
    .PARAMETER Tool
        The tool record (from the tool JSON database) to configure.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $xdg = $Tool.xdg
    if (-not $xdg) { return }
    switch ($xdg.method) {
        'env' {
            # A tool's vars are defaults: a variable the user set outside DotForge
            # (profile, system) is kept, one DotForge wrote is updated (Set-DFEnv).
            foreach ($var in @($xdg.vars?.PSObject.Properties)) {
                if ($var) { Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Tool $Tool.name }
            }
            $xdg.dirs | Where-Object { $_ } |
                ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
        }
        'manual' {
            Write-Warning "DotForge: $($Tool.name) requires manual XDG configuration.$(if ($xdg.instructions) { " $($xdg.instructions)" })"
        }
        'wrapper' {
            Write-Verbose "DotForge: $($Tool.name) xdg.method 'wrapper' — handled by companion .ps1"
        }
        'default' { } # tool already follows XDG natively — no env config needed
    }
}

# ---- Private/Start-DFModulePrewarm.ps1
#Requires -Version 7.2

function Start-DFModulePrewarm {
    <#
    .SYNOPSIS
        Fires a background job that imports each named module in its own
        throwaway runspace, purely to warm OS/CLR-level caches.
    .DESCRIPTION
        PowerShell-level session state -- loaded modules, defined functions,
        $global: variables -- is not shared across runspaces (confirmed
        empirically -- see docs/superpowers/specs/2026-09-05-startup-perf-audit.md
        Part 2), so the import performed here is never visible to the
        caller's session. This function's only purpose is the side effect of
        touching the module's files once before the caller's own (unchanged)
        Import-Module call reaches them -- that later, real import is then
        fast, due to already-warm OS/CLR-level caches (measured ~77%
        reduction on a representative module, reproduced 3/3).

        That isolation is at the PowerShell session-state level only.
        Start-ThreadJob runs its scriptblock on a thread inside the SAME
        process as the caller (unlike Start-Job, which is a separate
        process), so process-global .NET/CLR static state IS shared with
        the caller. A module whose import touches shared static/global .NET
        state -- not just PowerShell session state -- is not safe to point
        at this function: importing it here, concurrently with anything
        else touching that same static state, is a real (if narrow)
        concurrency risk. PSReadLine is the concrete example that prompted
        this note -- it keeps its key-handler dispatch table on a
        process-global static singleton, and PSFzf's import touches it. Any
        `Tools/<name>.json` can opt a tool's module out of prewarming
        entirely with a top-level `"prewarm": false` field (see
        `Tools/psreadline.json`, which sets it for exactly this reason);
        `Register-DFTool` excludes such tools from the module list it
        passes here.

        Nothing depends on this job succeeding, finishing before the caller
        continues, or running at all: a module that fails to import here is
        silently ignored (the caller's own real import will report any real
        failure normally), and a caller that never waits on the returned
        job simply gets today's synchronous-import cost for whichever
        modules the job didn't reach in time -- never worse than not
        calling this function at all. If Start-ThreadJob itself is
        unavailable (e.g. Microsoft.PowerShell.ThreadJob cannot be found),
        that failure is caught and this function returns $null, same as
        the empty-input case -- never worse than not calling this function
        at all.

        Assumes the named modules have no import-time side effects beyond
        session-local state (defining functions, format/type data, etc.) --
        true of Terminal-Icons/PSFzf/posh-git, this function's motivating
        callers. A module whose import writes files, calls the network, or
        otherwise mutates state outside its own session would have that
        side effect run twice (once here, discarded; once for real) if
        pointed at this function -- not a fit for that kind of module.
    .PARAMETER ModuleNames
        Module names to pre-import, e.g. @('Terminal-Icons', 'PSFzf'). May
        be empty.
    .OUTPUTS
        [System.Management.Automation.Job] the started background job, or
        $null when -ModuleNames is empty or Start-ThreadJob itself fails.
        Never call Receive-Job on it for its result -- there is nothing
        meaningful to receive, since the import happened in a runspace the
        caller can't see into. The caller should Remove-Job -Force it once
        done with its own work, whether or not the job has finished by then.
    .EXAMPLE
        Start-DFModulePrewarm -ModuleNames @('Terminal-Icons', 'PSFzf', 'posh-git')
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ModuleNames
    )

    if (-not $ModuleNames) {
        return $null
    }

    try {
        Start-ThreadJob -ScriptBlock {
            param([string[]]$Names)
            foreach ($name in $Names) {
                try { Import-Module -Name $name -ErrorAction Stop } catch { }
            }
        } -ArgumentList (, $ModuleNames)
    } catch {
        # Start-ThreadJob itself failed (e.g. Microsoft.PowerShell.ThreadJob is
        # unavailable) -- degrade silently, same shape as the empty-input
        # early return above. The caller's own real Import-Module downstream
        # is unaffected either way; see .DESCRIPTION.
        $null
    }
}

# ---- Private/Test-DFToolAvailable.ps1
#Requires -Version 7.2

$script:DFToolAvailability = @{}

function Test-DFToolAvailable {
    <#
    .SYNOPSIS
        Checks whether a tool's executable or module is available; "available" is remembered for the session.
    .DESCRIPTION
        Wraps Get-Command (exe-type tools) / Get-Module -ListAvailable
        (module-type tools) with a session-scoped cache keyed by type and
        name. Only a positive answer is remembered: an available tool is probed
        once per session, but a missing one is probed again on every call,
        because an earlier tool can put it on PATH mid-load (fnm puts node,
        npm and inshellisense's `is` on PATH only when its companion runs) and
        an install can add it mid-session. A missing tool costs one lookup per
        call, and only missing tools pay it.
    .PARAMETER Executable
        The executable name (exe-type tools) or module name (module-type
        tools) to check.
    .PARAMETER Type
        'exe' or 'module'. Defaults to 'exe'.
    .PARAMETER Force
        Bypass the cache and re-probe.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'ripgrep.exe'
        Returns $true if ripgrep.exe is on PATH.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module'
        Returns $true if the PSFzf module is installed.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [ValidateSet('exe', 'module')]
        [string]$Type = 'exe',

        [switch]$Force
    )

    $key = "$Type|$Executable"
    if (-not $Force -and $script:DFToolAvailability.ContainsKey($key)) {
        return $script:DFToolAvailability[$key]
    }

    $available = if ($Type -eq 'module') { Test-DFModuleOnPath -Name $Executable } else { Test-DFExecutableOnPath -Name $Executable }

    # Never remember "not installed": see .DESCRIPTION.
    if ($available) { $script:DFToolAvailability[$key] = $true }
    return $available
}

function Test-DFExecutableOnPath {
    <#
    .SYNOPSIS
        Whether an executable is on PATH, by checking its exact candidate filenames in each PATH folder.
    .DESCRIPTION
        A cheaper stand-in for Get-Command when only "is it installed?"
        matters (about half the time per tool at startup). A name with an
        extension is looked up as is; a bare name also tries each PATHEXT
        extension (pipx is pipx.cmd from scoop, pipx.exe from pip). Folders
        that don't exist are skipped. A rooted path is checked directly.
    .PARAMETER Name
        The executable, e.g. 'rg.exe' or 'pipx'.
    .PARAMETER PathValue
        The PATH to search. Default: $Env:Path.
    .PARAMETER PathExt
        Extensions a bare name may have. Default: $Env:PATHEXT.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$PathValue = $Env:Path,
        [string]$PathExt = $Env:PATHEXT
    )
    if ([IO.Path]::IsPathRooted($Name)) { return [IO.File]::Exists($Name) }
    $names = if ([IO.Path]::HasExtension($Name)) { @($Name) }
             else { @($Name) + @("$PathExt" -split ';' | Where-Object { $_ } | ForEach-Object { $Name + $_ }) }
    foreach ($dir in "$PathValue" -split [IO.Path]::PathSeparator) {
        $dir = $dir.Trim().Trim('"')
        if (-not $dir) { continue }
        foreach ($n in $names) {
            if ([IO.File]::Exists([IO.Path]::Combine($dir, $n))) { return $true }
        }
    }
    $false
}

function Test-DFModuleOnPath {
    <#
    .SYNOPSIS
        Whether a PowerShell module is installed, by checking for its folder under each PSModulePath root.
    .DESCRIPTION
        A cheaper stand-in for Get-Module -ListAvailable (about a tenth of the
        time), which also reads every manifest it finds.
    .PARAMETER Name
        The module name.
    .PARAMETER ModulePath
        The module search path. Default: $Env:PSModulePath.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ModulePath = $Env:PSModulePath
    )
    foreach ($root in "$ModulePath" -split [IO.Path]::PathSeparator) {
        $root = $root.Trim().Trim('"')
        if ($root -and [IO.Directory]::Exists([IO.Path]::Combine($root, $Name))) { return $true }
    }
    $false
}

# ---- Private/Update-DFPathFromRegistry.ps1
#Requires -Version 7.2

function Get-DFRegistryPath {
    <#
    .SYNOPSIS
        Returns the persisted Machine and User PATH (what a new shell would get).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join [IO.Path]::PathSeparator
}

function Update-DFPathFromRegistry {
    <#
    .SYNOPSIS
        Appends PATH entries an installer wrote to the registry, so this shell finds new tools without a restart.
    .DESCRIPTION
        Only entries the session lacks are added, at the end, through
        Add-DFToPath. Nothing is removed or reordered, so session-only entries
        (fnm's multishell folder, a venv) survive.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $sep = [IO.Path]::PathSeparator
    $have = @($Env:Path -split $sep | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
    foreach ($p in (Get-DFRegistryPath) -split $sep) {
        $p = [Environment]::ExpandEnvironmentVariables($p.Trim())
        if ($p -and $p.TrimEnd('\', '/') -notin $have) {
            Add-DFToPath $p
            $have += $p.TrimEnd('\', '/')
        }
    }
}

# ---- Private/Write-DFDevBuildNotice.ps1
#Requires -Version 7.2

function Write-DFDevBuildNotice {
    <#
    .SYNOPSIS
        Says, when a session starts, that this DotForge is a private developer build.
    .DESCRIPTION
        Dev builds come from build/Publish-DFLocal.ps1 (version <next patch>-dev<timestamp>,
        installed from a local gallery). One line at session start keeps you from
        forgetting you are running one. Gallery releases (stable or 'preview') and
        DotForge run from source files (no module, as in tests) say nothing.
    .PARAMETER Version
        The module version. Default: the loaded DotForge module's.
    .PARAMETER Prerelease
        The prerelease label. Default: the loaded DotForge module's.
    .PARAMETER Location
        Where the module is installed. Default: the loaded DotForge module's folder.
    .OUTPUTS
        None. Writes one line to the host.
    #>
    [CmdletBinding()]
    param(
        [string]$Version = $ExecutionContext.SessionState.Module.Version,
        [string]$Prerelease = $ExecutionContext.SessionState.Module.PrivateData.PSData.Prerelease,
        [string]$Location = $ExecutionContext.SessionState.Module.ModuleBase
    )
    if ($Prerelease -notlike 'dev*') { return }
    Write-Host "DotForge $Version-$Prerelease`: developer build, not a Gallery release ($Location)" -ForegroundColor DarkYellow
}

# ---- Private/Write-DFInstallPlan.ps1
#Requires -Version 7.2

function Write-DFInstallPlan {
    <#
    .SYNOPSIS
        Prints an install plan: stages, manager batches, feeds to add, elevation, sources a record avoids, and gaps.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($s in $Plan.Stages) {
        $parts = @(foreach ($b in $s.Batches) {
            $feeds = @($b.Items | Where-Object { $_.Ref.Feed } | ForEach-Object { "+ feed '$($_.Ref.Feed.name)' ($($_.Ref.Feed.url))" } | Select-Object -Unique)
            $elev = if ($b.Elevation) { " (needs admin: $($b.Elevation.Detail))" } else { '' }
            "$($b.Manager.name)$elev`: $((@($feeds) + @($b.Items | ForEach-Object { "$($_.Tool) ($($_.Ref.Id))" })) -join ' · ')"
        })
        $parts += @($s.Provided | ForEach-Object { "$($_.Tool) (comes with $($_.ProvidedBy))" })
        Write-Host ("  stage {0}  {1}" -f $s.Number, ($parts -join "`n           "))
    }
    # A source the tool's record avoids, used because the user named it or nothing else has the tool.
    foreach ($item in @($Plan.Stages | ForEach-Object { $_.Batches } | ForEach-Object { $_.Items } | Where-Object { $_.AvoidReason })) {
        Write-Host "  note: $($item.Tool) from $($item.Source): $($item.AvoidReason)" -ForegroundColor Yellow
    }
    foreach ($g in $Plan.Gaps) {
        Write-Host "  not installed: $($g.Tool) — $($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" -ForegroundColor Yellow
    }
}

function Get-DFInstallGapResult {
    <#
    .SYNOPSIS
        Turns a plan's gaps into result rows (Result 'Gap', and 'Skipped' for the tools waiting on one).
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        PSCustomObject[].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($g in $Plan.Gaps) {
        [pscustomobject]@{ Tool = $g.Tool; Result = 'Gap'; Detail = "$($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" }
        foreach ($d in $g.Dependents) { [pscustomobject]@{ Tool = $d; Result = 'Skipped'; Detail = "waits on $($g.Tool)" } }
    }
}

function Write-DFInstallSummary {
    <#
    .SYNOPSIS
        Prints one line per result group: installed, failed (with output), skipped, not found, gaps.
    .PARAMETER Result
        Rows from Invoke-DFInstallPlan and Get-DFInstallGapResult.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Result = @())
    foreach ($g in $Result | Group-Object Result) {
        Write-Host "  $($g.Name): $(@($g.Group | ForEach-Object { if ($_.Result -eq 'Installed') { $_.Tool } else { "$($_.Tool) ($($_.Detail))" } }) -join ', ')"
    }
}

# ---- Private/Write-DFRemoveLeftover.ps1
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
        System.String[]. '?' stands for a block that can't list what it installed.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([pscustomobject]$Manager, [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    if (-not $Manager -or -not $Manager.installs) { return }
    Import-DFManagerOps -Manager $Manager -ToolsPath $ToolsPath
    foreach ($block in $Manager.installs) {
        # A block with no list can't say what it holds: count that as "something".
        if (-not $block.list) { '?'; continue }
        Get-DFManagerInstalled -Manager $Manager -Block $block | ForEach-Object { $_.Id }
    }
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
        # Type first, then the other fields by name: a setup script's hashtable has no stable order.
        $fields = @($action.PSObject.Properties | Where-Object Name -ne 'type' | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
        $lines.Add("change its setup made: $(@($action.PSObject.Properties['type']?.Value) + $fields -join ' ')")
    }
    if ($Tool.name -in @(Get-DFConfig Tools)) { $lines.Add("remove '$($Tool.name)' from Tools in your profile") }
    elseif ($script:DFSessionStatus -and $script:DFSessionStatus.Contains($Tool.name)) { $lines.Add("add '$($Tool.name)' to ExcludeTools in your profile (a group requests it)") }
    Write-Host "DotForge removed $($Tool.name). Left behind:"
    foreach ($line in $lines) { Write-Host "  $line" }
    Write-Host '  its aliases and functions stay until you open a new shell'
}

# ---- Private/Write-DFRoleNotice.ps1
#Requires -Version 7.2

function Write-DFRoleNotice {
    <#
    .SYNOPSIS
        Warns when DotForge had to guess the winner of an exclusive role.
    .DESCRIPTION
        For each exclusive role whose winner was chosen by priority (two or more
        candidates and no usable $DFConfig.Defaults entry), warns once naming the
        winner and the line that picks another tool. "Once" is per candidate set,
        recorded in <XDG state>/dotforge/role-state.json, so installing another
        candidate warns again. An unreadable state file counts as empty; a failed
        write is ignored. Never throws.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [hashtable]$RoleDb = (Get-DFRoleDb)
    )
    $guessed = @($RoleWinners.Values | Where-Object {
        $_.Reason -eq 'priority' -and $RoleDb.ContainsKey($_.Role) -and $RoleDb[$_.Role].exclusive
    })
    if (-not $guessed) { return }

    $stateFile = Join-Path (Get-DFXdgPath State) 'dotforge' 'role-state.json'
    $state = @{}
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $state = @{} }
        if ($state -isnot [hashtable]) { $state = @{} }
    }

    $changed = $false
    foreach ($w in $guessed | Sort-Object Role) {
        $key = $w.Candidates -join ','
        if ($state[$w.Role] -eq $key) { continue }
        # Suggest the runner-up by priority (Ranked), not the alphabetically first.
        $order = if ($w.PSObject.Properties['Ranked'] -and $w.Ranked) { $w.Ranked } else { $w.Candidates }
        $other = $order | Where-Object { $_ -ne $w.Winner } | Select-Object -First 1
        Write-Warning ("DotForge: $($w.Candidates -join ', ') can each fill the $($w.Role) role; using $($w.Winner). " +
            "Choose with `$DFConfig.Defaults = @{ '$($w.Role)' = '$other' }")
        $state[$w.Role] = $key
        $changed = $true
    }
    if ($changed) {
        try { Write-DFFileAtomic -Path $stateFile -Value ($state | ConvertTo-Json) } catch { Write-Verbose "DotForge: could not save role state: $($_.Exception.Message)" }
    }
}

# ---- Public/Add-DFToPath.ps1
#Requires -Version 7.2

function Add-DFToPath {
    <#
    .SYNOPSIS
        Adds a directory to $Env:Path with normalization and deduplication.
    .DESCRIPTION
        Normalizes the path with ConvertTo-DFPath (native separators, no '.'/'..',
        no trailing separator), deduplicates it against every existing PATH entry
        (compared in the same normalized form), and appends it when not already
        present. With -Prepend it is placed first, and any existing copy further
        down is removed so the directory appears exactly once.

        Only the current session's $Env:Path changes; nothing is written to the
        user or machine PATH in the registry. To keep the change, call this from
        your profile. The directory does not need to exist.

        Relative paths, including '~\...', are rejected with a warning rather than
        resolved against the current directory: pass "$HOME\..." instead. An empty
        value is silently ignored. All DotForge PATH additions use this function.
    .PARAMETER Dir
        Absolute path of the directory to add. Empty or null does nothing; a
        relative path writes a warning and does nothing.
    .PARAMETER Prepend
        Put the directory at the front of PATH, so its executables win over
        same-named ones later in PATH. Default: append to the end.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin'

        Appends C:\tools\bin to the current session PATH if not already present.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin' -Prepend

        Inserts C:\tools\bin at the front of PATH so it takes priority.
    .OUTPUTS
        None. Changes $Env:Path for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Dir,
        [switch]$Prepend
    )

    if (-not $Dir) { return }

    if (-not [IO.Path]::IsPathRooted($Dir)) {
        Write-Warning "Add-DFToPath: '$Dir' is not an absolute path — skipped."
        return
    }

    $normalized = ConvertTo-DFPath $Dir

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { ConvertTo-DFPath $_ } catch { $_ } }

    if ($Prepend) {
        $remaining = ($Env:Path -split [IO.Path]::PathSeparator) | Where-Object {
            if (-not $_ -or -not [IO.Path]::IsPathRooted($_)) { return $true }
            try { (ConvertTo-DFPath $_) -ne $normalized } catch { $true }
        }
        $Env:Path = (@($normalized) + @($remaining)) -join [IO.Path]::PathSeparator
        return
    }

    if ($normalized -notin $existing) {
        $Env:Path += [IO.Path]::PathSeparator + $normalized
    }
}

# ---- Public/Complete-DFToolSetup.ps1
#Requires -Version 7.2

function Complete-DFToolSetup {
    <#
    .SYNOPSIS
        Records that a tool's one-time setup has completed successfully.
    .DESCRIPTION
        Call this from a Tools/<name>.setup.ps1 companion as its own last
        line, only once the script's work has actually succeeded. Merges an
        entry for -Name into the persisted state file at
        $XDG_STATE_HOME/dotforge/setup-state.json, recording the UTC time it
        ran and an opaque -Actions record whose shape the calling tool
        defines -- DotForge core never interprets it.

        Register-DFTool checks this state before dot-sourcing a tool's
        Tools/<name>.setup.ps1 again, so once an entry exists for a tool, its
        setup script is skipped on every future Register-DFTool call --
        forever, until the state file is deleted or the entry is removed.
        Notes added with Add-DFToolSetupNote (or declared in setup.notes) are
        recorded with it and printed once at the end of the load. See
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .PARAMETER Name
        The tool name this setup record belongs to (matches the "name" field
        in the tool's Tools/<name>.json).
    .PARAMETER Actions
        Free-form objects describing what the setup did, e.g.
        @{ type = 'gitConfigInclude'; path = '...' }. Opaque to DotForge
        core -- recorded verbatim for a future teardown command to read
        back. Defaults to an empty array.
    .EXAMPLE
        Complete-DFToolSetup -Name 'delta' -Actions @(
            @{ type = 'gitConfigInclude'; path = $resolvedIncludePath }
        )

        Records that delta's setup ran, and what it changed.
    .EXAMPLE
        Complete-DFToolSetup -Name 'mdv'

        Records that mdv's setup ran, with no actions to report.
    .OUTPUTS
        None. Writes $XDG_STATE_HOME\dotforge\setup-state.json (atomically,
        through a temp file).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/writing-a-tool.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Actions = @()
    )

    $state = Get-DFToolSetupState
    $entry = [PSCustomObject]@{
        ranAt   = (Get-Date).ToUniversalTime().ToString('o')
        actions = @(@(Get-DFPendingSeedAction -Name $Name) + @($Actions))
        notes   = [string[]]@(Get-DFPendingSetupNote -Name $Name)
    }
    $state | Add-Member -MemberType NoteProperty -Name $Name -Value $entry -Force

    $stateFile = Get-DFToolSetupStatePath
    Write-DFFileAtomic -Path $stateFile -Value ($state | ConvertTo-Json -Depth 10)
    Clear-DFPendingSeedAction -Name $Name
    Publish-DFSetupNote -Name $Name
}

# ---- Public/DFAliases.ps1
#Requires -Version 7.2

# Aliases for commands in the on-demand modules (DotForge.Catalog, DotForge.Helpers).
# They are defined here, in the startup core, so they exist from the first prompt:
# an alias exported by a module that has not loaded yet loses to a program of the
# same name on PATH (env, which, touch, paste). Calling one resolves its target
# function, which makes PowerShell load that module.

Set-Alias -Name trifle -Value Find-DFPackage
Set-Alias -Name tcats -Value Get-DFCategoryList
Set-Alias -Name ftrifle -Value Select-DFPackage
Set-Alias -Name yank -Value Copy-DFToClipboard
Set-Alias -Name paste -Value Get-DFFromClipboard
Set-Alias -Name path -Value Get-DFPath
Set-Alias -Name fenv -Value Select-DFEnvVar
Set-Alias -Name ep -Value Edit-DFProfile
Set-Alias -Name env -Value Get-DFEnv
Set-Alias -Name reload -Value Invoke-DFProfileReload
Set-Alias -Name touch -Value New-DFFile
Set-Alias -Name which -Value Get-DFWhich
Set-Alias -Name open -Value Open-DFItem
Set-Alias -Name hm -Value Invoke-DFHelp
Set-Alias -Name fcmd -Value Select-DFCommand
Set-Alias -Name fverb -Value Select-DFVerb
Set-Alias -Name fmod -Value Select-DFModule
Set-Alias -Name fh -Value Select-DFHelpTopic
Set-Alias -Name clh -Value Show-DFCliHelp
Set-Alias -Name clhp -Value Show-DFCliHelpPaged
Set-Alias -Name up -Value Set-DFLocationUp
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet
Set-Alias -Name fcd -Value Select-DFLocation
Set-Alias -Name fps -Value Select-DFProcess
Set-Alias -Name top -Value Get-DFTopProcess
Set-Alias -Name uuidgen -Value New-DFUuid

# ---- Public/DFHelpers.Pager.ps1
#Requires -Version 7.2

function Invoke-DFWithPager {
    <#
    .SYNOPSIS
        Pipes output through the pager named by $Env:Pager, or prints it when none is set.
    .DESCRIPTION
        Accepts either pipeline input or a scriptblock. Collects all output as
        strings, then either sends it to the external pager named by $Env:Pager
        (via Invoke-DFPagerExe) or writes it to the success stream when no pager
        is configured. Nothing is sent to the pager when the collected result is
        empty.

        $Env:Pager is a command line split on whitespace: the first word is the
        executable, the rest are its arguments (e.g. 'less -R' or
        'bat --paging=always'). Quoted arguments are not supported; use the
        --key=value form instead. A warning is written when quotes are present.

        Side effects: starts the pager process. Reads $Env:Pager only.
    .PARAMETER InputObject
        String values piped in from the pipeline. Non-string objects are
        converted with their default ToString(). Ignored, with a warning, when
        -Command is also given.
    .PARAMETER Command
        Optional scriptblock whose output is used instead of pipeline input. Each
        output object is converted to a string.
    .EXAMPLE
        Get-ChildItem | Select-Object -ExpandProperty Name | Invoke-DFWithPager

        Pages the names of the files in the current directory.
    .EXAMPLE
        $Env:Pager = 'less -R'
        pg { git log --oneline }

        Runs the scriptblock and pages its output through less, using the pg alias.
    .OUTPUTS
        System.String. Emitted only when $Env:Pager is unset; otherwise the
        output goes to the pager and nothing is returned.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [string]$InputObject,

        [Parameter(Position = 0)]
        [scriptblock]$Command
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end {
        if ($Command) {
            if ($lines.Count -gt 0) {
                Write-Warning 'Invoke-DFWithPager: both pipeline input and -Command were provided; pipeline input is ignored.'
            }
            $lines = @(& $Command | ForEach-Object { "$_" })
        }
        if ($Env:Pager -and $lines.Count -gt 0) {
            Invoke-DFPagerExe -Lines $lines -Pager $Env:Pager
        } else {
            $lines
        }
    }
}
Set-Alias -Name pg -Value Invoke-DFWithPager

# ---- Public/Find-DFTool.ps1
#Requires -Version 7.2

function Find-DFTool {
    <#
    .SYNOPSIS
        Searches the DotForge tool registry by wildcard pattern across name,
        description, and tags.
    .DESCRIPTION
        Performs a case-insensitive wildcard search across each tool's name,
        description, and tags, and returns every record with at least one match.
        The pattern is wrapped in '*...*', so a plain word matches anywhere.
        Useful for discovering tools in the registry by keyword. Searches only
        DotForge's own tool records; to search package-manager catalogs, use
        Find-DFPackage. Read-only; changes nothing.
    .PARAMETER Pattern
        Text or wildcard pattern to match (e.g. 'rip', 'grep*', 'mark?own').
        Matched as '*<Pattern>*'. Optional when -Role is given.
    .PARAMETER Role
        Only tools that declare this role (see Get-DFRole), e.g. pager or
        listing. Combine with -Pattern to narrow further.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Find-DFTool 'grep'

        Returns all tools whose name, description, or tags contain 'grep'.
    .EXAMPLE
        Find-DFTool '*pager*' | Select-Object name

        Lists tool names that relate to paging.
    .EXAMPLE
        Find-DFTool -Role pager

        Lists every tool that can be the pager.
    .OUTPUTS
        PSCustomObject — matching tool registry records.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)][string]$Pattern,
        [string]$Role,
        [string]$ToolsPath
    )

    if (-not $Pattern -and -not $Role) {
        Write-Error 'Specify -Pattern, -Role, or both.' -ErrorAction Stop
        return
    }

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $db.Values | Where-Object {
        (-not $Role -or $_.roles.PSObject.Properties[$Role]) -and
        (-not $Pattern -or
            $_.name -like "*$Pattern*" -or
            ($_.description -like "*$Pattern*") -or
            (@($_.tags) | Where-Object { $_ -like "*$Pattern*" }))
    }
}

# ---- Public/Get-DFCommandConflict.ps1
#Requires -Version 7.2

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
        aliases plus every alias, role alias and picker alias declared in the tool database)
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

    .PARAMETER Tools
        Tool records to check instead of every known tool. Start-DFSession passes
        the tools it activated.
    .PARAMETER IncludeIgnored
        Also return conflicts listed in the session config's IgnoreConflicts, which are
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
        Start-DFSession -Config @{ Tools = @('bat'); IgnoreConflicts = @('cat') }
        Get-DFCommandConflict

        Reports conflicts while accepting coreutils' cat over DotForge's bat alias.

    .OUTPUTS
        [PSCustomObject] with Command, ShadowedBy, WouldResolveTo, Ignored,
        DisableWith, and Fix properties. Returns nothing when no conflict exists.

    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/coreutils-conflicts.md
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ToolsPath,
        [object[]]$Tools,
        [switch]$IncludeIgnored
    )

    $shadowed = Get-DFCoreutilsShadowSet
    if (-not $shadowed) { return }

    # Names DotForge creates. Two sources, because they are created two different ways:
    #  1. Helper aliases (touch, env, paste, ...) — created at import by Public/*.ps1
    #     and exported by the module manifest (AliasesToExport), so the module owns
    #     them and (Get-Module DotForge).ExportedAliases contains them.
    #  2. Tool aliases and picker aliases (cat, ls, ff, ...) — created by
    #     Register-DFTool from the tool database and, for roles with behaviors,
    #     from data/roles.json.
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

    # A session passes its active tools; run on its own, every known tool is checked.
    $checked = if ($PSBoundParameters.ContainsKey('Tools')) { @($Tools) } else {
        $dbParams = @{}
        if ($ToolsPath) { $dbParams['ToolsPath'] = $ToolsPath }
        @((Import-DFToolDb @dbParams -ErrorAction Ignore).Values)
    }
    $roleDb = Get-DFRoleDb
    foreach ($tool in $checked) {
        if (-not $tool) { continue }
        if ($tool.aliases) {
            $owned.AddRange([string[]]@($tool.aliases.PSObject.Properties.Name))
        }
        # A role's aliases (ls, ll, ...) are defined only by the role's winner,
        # but any member may win, so all of them can be shadowed. A role with
        # behaviors builds its aliases and pickers itself; Get-DFRoleDb lists
        # their names in reserved.aliases.
        foreach ($role in $tool.roles.PSObject.Properties) {
            if ($role.Value.aliases) {
                $owned.AddRange([string[]]@($role.Value.aliases.PSObject.Properties.Name))
            }
            $definition = $roleDb[$role.Name]
            if ($definition -and $definition.behaviors) { $owned.AddRange([string[]]@($definition.reserved.aliases)) }
        }
        foreach ($picker in @($tool.picker)) {
            if ($picker -is [PSCustomObject] -and $picker.alias) { $owned.Add([string]$picker.alias) }
        }
    }

    $ignored = [string[]]@(Get-DFConfig IgnoreConflicts)

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

# ---- Public/Get-DFConfig.ps1
#Requires -Version 7.2

function Get-DFConfig {
    <#
    .SYNOPSIS
        Reads one setting of the current DotForge session, or returns -Default when it isn't set.
    .DESCRIPTION
        Reads the configuration Start-DFSession stored for this session. It is
        read-only: to change a setting, pass a new configuration to
        Start-DFSession. A missing key or a $null value returns -Default; a
        configured $false is returned as is. Like any PowerShell command, an
        array value is written to the pipeline element by element, so read
        list settings with @(Get-DFConfig Tools).

        DotForge's on-demand modules (the package catalog and the general
        helpers) read session settings through this command.
    .PARAMETER Key
        The setting name, e.g. 'Theme' or 'Tools'.
    .PARAMETER Default
        Returned when the setting isn't configured. Default: $null.
    .EXAMPLE
        Get-DFConfig Theme

        Shows the session's color theme, e.g. catppuccin-mocha.
    .EXAMPLE
        @(Get-DFConfig Tools)

        Lists the tools and +groups this session was started with.
    .EXAMPLE
        Get-DFConfig PSReadLineEditMode -Default Windows

        Returns the configured edit mode, or Windows when none is set.
    .OUTPUTS
        System.Object. The setting's value, or -Default.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)]$Default = $null
    )
    if ($script:DFSessionConfig -and $script:DFSessionConfig.Contains($Key) -and $null -ne $script:DFSessionConfig[$Key]) {
        return $script:DFSessionConfig[$Key]
    }
    $Default
}

# ---- Public/Get-DFRole.ps1
#Requires -Version 7.2

function Get-DFRole {
    <#
    .SYNOPSIS
        Lists DotForge's tool roles, which tools fill each, and which one is active.
    .DESCRIPTION
        A role is a job several tools can do, such as pager or prompt. For a
        single role, one installed tool wins: the one named in Defaults,
        otherwise the highest-priority installed tool. Only
        the winner sets the role's variables and aliases and installs its shell
        hooks. A category role only groups tools; every member works as usual.

        After Start-DFSession, it shows the session's view: members, candidates
        and winners among the tools you requested, as they were decided at
        load. Before a session (or with -ToolsPath) it considers every tool
        DotForge knows. Overridden lists
        role variables whose current value is not the winner's. Source says
        why: 'outside DotForge' is a value such as a PAGER you set yourself,
        which DotForge keeps unless you also name a tool in Defaults;
        'DotForge (earlier winner)' is a value DotForge wrote for a different
        winner earlier in this session. Read-only; changes nothing.
    .PARAMETER Name
        Role names to show. All roles when omitted.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Get-DFRole | Format-Table Name, Kind, Winner, Reason, Candidates

        Shows every role and the tool that fills it on this machine.
    .EXAMPLE
        Get-DFRole pager | Select-Object -ExpandProperty Overridden

        Shows whether a pager variable you set outside DotForge is overriding the pager role's winner.
    .OUTPUTS
        DotForge.Role. Name, Kind, Exclusive, Description, Members, Candidates, Winner, Reason, Fallback (what the role falls back to when nothing wins), Overridden.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    [OutputType('DotForge.Role')]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [string]$ToolsPath
    )
    $roleDb = Get-DFRoleDb
    if ($script:DFSessionRoleWinners -and -not $ToolsPath) {
        # In a session: the session's own view, among the tools you requested.
        # No extra records are read, and it matches what is actually active.
        $db = $script:DFSessionToolDb
        $set = @($db.Values)
        $winners = $script:DFSessionRoleWinners
    } else {
        $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
        $db = Import-DFToolDb @dbArgs
        $set = @($db.Values)
        $winners = Get-DFRoleWinners -ToolDb $db -Tools $set -RoleDb $roleDb
    }

    foreach ($role in $roleDb.Values | Sort-Object name) {
        if ($Name -and $role.name -notin $Name) { continue }
        $members = @(Get-DFRoleMember -Role $role.name -Tools @($db.Values) | ForEach-Object name)
        $w = $winners[$role.name]
        # What DotForge would set for this role: the winner's block env and, for a role
        # with behaviors.env, the variables built from its flags; with no winner, the fallback.
        $wanted = [ordered]@{}
        if ($w) {
            $winnerTool = $db[$w.Winner]
            $block = $winnerTool.roles.($role.name)
            if ($block.env) { foreach ($var in $block.env.PSObject.Properties) { $wanted[$var.Name] = Expand-DFXdgPath $var.Value } }
            if ($role.behaviors -and $role.behaviors.env.Count -and $block.flags -and -not $block.legacy) {
                $built = Get-DFRoleBehaviorEnv -RoleDefinition $role -Block $block -Tool $winnerTool
                foreach ($builtName in $built.Keys) { $wanted[$builtName] = $built[$builtName] }
            }
        } elseif ($role.fallback) {
            foreach ($var in $role.fallback.env.PSObject.Properties) { $wanted[$var.Name] = [string]$var.Value }
        }
        $overridden = @(foreach ($varName in $wanted.Keys) {
            $current = [Environment]::GetEnvironmentVariable($varName, 'Process')
            if ($current -and $current -cne $wanted[$varName]) {
                # $Name is this function's role filter: never reuse it here.
                $source = if ((Get-DFEnvState).Written[$varName] -ceq $current) { 'DotForge (earlier winner)' } else { 'outside DotForge' }
                [pscustomobject]@{ Name = $varName; Value = $current; Source = $source }
            }
        })
        $candidates = if ($w) { $w.Candidates } else {
            [string[]]@($set | Where-Object { $_.name -in $members -and (Test-DFToolAvailable -Executable $_.executable -Type $_.type) } | ForEach-Object name | Sort-Object)
        }
        [pscustomobject]@{
            PSTypeName  = 'DotForge.Role'
            Name        = $role.name
            Kind        = $role.kind
            Exclusive   = $role.exclusive
            Description = $role.description
            Members     = [string[]]$members
            Candidates  = [string[]]@($candidates)
            Winner      = ${w}?.Winner
            Reason      = ${w}?.Reason
            # With no winner, what the role falls back to (pager: PAGER = more).
            Fallback    = if (-not $w -and $role.fallback) {
                $map = [ordered]@{}
                foreach ($v in $role.fallback.env.PSObject.Properties) { $map[$v.Name] = [string]$v.Value }
                [pscustomobject]$map
            }
            Overridden  = $overridden
        }
    }
}

# ---- Public/Get-DFTool.ps1
#Requires -Version 7.2

function Get-DFTool {
    <#
    .SYNOPSIS
        Queries the DotForge tool registry.
    .DESCRIPTION
        Returns tool records from the JSON tool database (one per Tools/*.json
        file, plus your own records in $XDG_CONFIG_HOME\dotforge\tools), whether
        or not the tool is installed. A record's source is builtin or user, and
        its folder is where it was read from. With no parameters, returns
        every known tool, in no particular order. Use -Name for an exact lookup
        or -Tag to filter by capability tag (e.g. 'fuzzy', 'prompt', 'git').

        Each record is the parsed JSON: name, executable, description, tags,
        packages, xdg, aliases, picker, and any other fields the tool declares.
        Read-only; changes nothing.
    .PARAMETER Name
        Return only the tool with this exact name (case-insensitive). Returns
        nothing when no tool matches.
    .PARAMETER Tag
        Return every tool whose tags include this exact value.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Get-DFTool -Name ripgrep

        Returns the tool record for ripgrep.
    .EXAMPLE
        Get-DFTool -Tag fuzzy

        Returns all tools tagged 'fuzzy' (fzf, PSFzf, etc.).
    .EXAMPLE
        Get-DFTool | Select-Object name, description

        Lists all registered tools with their descriptions.
    .EXAMPLE
        Get-DFTool | Where-Object source -eq user

        Lists your own tool records, including any that replace a shipped one.
    .OUTPUTS
        PSCustomObject — one or more tool registry records.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'ByName')][string]$Name,
        [Parameter(ParameterSetName = 'ByTag')][string]$Tag,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs
    $results = $db.Values

    switch ($PSCmdlet.ParameterSetName) {
        'ByName' { $results = $results | Where-Object { $_.name -eq $Name } }
        'ByTag'  {
            $results = $results | Where-Object { $_.tags -contains $Tag }
        }
    }

    $results
}

# ---- Public/Get-DFToolGroup.ps1
#Requires -Version 7.2

function Get-DFToolGroup {
    <#
    .SYNOPSIS
        Lists DotForge's predefined tool groups and their members.
    .DESCRIPTION
        A group is a predefined list of tools you can request as one entry in
        Start-DFSession -Config: Tools = @('+core', '+git') requests every member.
        Groups can also be excluded (ExcludeTools = @('+admin-tools')).
        Use this to see what a group contains before requesting it.
    .PARAMETER Name
        Group names to show, with or without the leading +. Default: all groups.
    .EXAMPLE
        Get-DFToolGroup

        Lists every group with its description and members.
    .EXAMPLE
        Get-DFToolGroup +core | Select-Object -ExpandProperty Tools

        Shows which tools +core requests.
    .OUTPUTS
        DotForge.ToolGroup objects: Name, Description, Tools.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string[]]$Name)
    $db = Get-DFGroupDb
    $names = if ($Name) { $Name | ForEach-Object { $_.TrimStart('+') } } else { $db.Keys }
    foreach ($n in $names) {
        if (-not $db.Contains($n)) {
            Write-Warning "DotForge: no tool group named '+$n'. Run Get-DFToolGroup to list them."
            continue
        }
        $g = $db[$n]
        $key = @($db.Keys | Where-Object { $_ -eq $n })[0]
        [pscustomobject]@{ PSTypeName = 'DotForge.ToolGroup'; Name = $key; Description = $g.Description; Tools = $g.Tools }
    }
}

# ---- Public/Get-DFToolStatus.ps1
#Requires -Version 7.2

function Get-DFToolStatus {
    <#
    .SYNOPSIS
        Shows what this session's Start-DFSession decided for each requested tool.
    .DESCRIPTION
        One object per requested (or excluded) tool:
            Name         the tool
            State        Active, Missing (not installed), Blocked (installed,
                         but a tool it requires isn't active), Failed (setup or
                         activation threw), Excluded (by ExcludeTools), or
                         Conflict (its old config location holds your config;
                         see Resolve-DFToolConflict)
            RequestedBy  Tools, the +group that requested it, or Register-DFTool
            Roles        roles it won this session, e.g. prompt
            Detail       why it is Missing, Failed or in Conflict, or the tool standing in for it
        It reports what already happened, so it is instant. Pipe -Missing
        into Install-DFTool to install those tools.
    .PARAMETER Name
        Only these tools.
    .PARAMETER Missing
        Only tools that aren't installed.
    .PARAMETER Failed
        Only tools that failed to load.
    .PARAMETER Conflict
        Only tools left inactive because their old config location holds your
        config. Resolve-DFToolConflict hands one over to DotForge.
    .EXAMPLE
        Get-DFToolStatus

        Lists every requested tool and what happened to it.
    .EXAMPLE
        Get-DFToolStatus -Missing

        Lists the requested tools that aren't installed; Install-DFTool -Missing installs them.
    .EXAMPLE
        Get-DFToolStatus -Conflict

        Lists the requested tools DotForge left alone because your existing config would be hidden.
    .OUTPUTS
        DotForge.ToolStatus objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [switch]$Missing,
        [switch]$Failed,
        [switch]$Conflict
    )
    if (-not $script:DFSessionStatus) {
        Write-Warning 'DotForge: no session yet. Start-DFSession configures the tools your config file (~/.config/dotforge/config.psd1) requests.'
        return
    }
    Add-DFInstallHint
    Add-DFSetupNoteDetail
    foreach ($s in $script:DFSessionStatus.Values) {
        if ($Name -and $s.Name -notin $Name) { continue }
        if ($Missing -and $s.State -ne 'Missing') { continue }
        if ($Failed -and $s.State -ne 'Failed') { continue }
        if ($Conflict -and $s.State -ne 'Conflict') { continue }
        $s
    }
}

# ---- Public/Install-DFTool.ps1
#Requires -Version 7.2

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs missing tools: everything the session reported missing (-Missing), or the named tools.
    .DESCRIPTION
        Builds one plan for all targets: a source and manager per tool
        (InstallVia, the tool's install.prefer, InstallOrder, DotForge's
        order; ExcludeSources never used unless InstallVia names it), in
        stages so that a manager or runtime installs before the tools that
        need it. Nothing you didn't ask for is installed, unless you choose it
        or pass -UseDefaults.

        Modes:
          - Interactive (default, when someone can answer): each open choice
            shows its default ("Enter keeps it"); then the whole plan is shown,
            including third-party feeds and elevation, and confirmed once.
          - -UseDefaults: no questions; DotForge's and the tool specs'
            defaults fill every gap.
          - No one to ask and no -UseDefaults (a script): only what needs no
            decision installs; each gap is reported with the tools waiting on it.
          - -WhatIf: the plan only.
          - -Confirm:$false: interactive, but without the final confirmation.

        Afterwards, new tools are activated in this session. A tool you named
        that isn't in your Tools setting is active only until the shell closes.
    .PARAMETER Missing
        Install the tools Get-DFToolStatus -Missing lists.
    .PARAMETER Name
        Tools (and +groups) to install.
    .PARAMETER Via
        Install the named tools from this source, for this call only.
    .PARAMETER UseDefaults
        Don't ask: take the default for every open choice.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Install-DFTool -Missing

        Asks about anything undecided, shows the plan, and installs it.
    .EXAMPLE
        Install-DFTool -Name glow -Via scoop -UseDefaults

        Installs glow from scoop without asking.
    .EXAMPLE
        Install-DFTool -Missing -WhatIf

        Shows what would be installed, in which stage, and from where.
    .OUTPUTS
        PSCustomObject. One per tool: Tool, Result (Installed, Failed, Skipped, NotFound, Gap), Detail.
        A Failed Detail has the manager's last lines; -Verbose shows all of its output.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Missing')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Missing')][switch]$Missing,
        [Parameter(Mandatory, ParameterSetName = 'Name')][string[]]$Name,
        [Parameter(ParameterSetName = 'Name')][string]$Via,
        [switch]$UseDefaults,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @pathArgs

    $targets = if ($Missing) {
        @(Get-DFToolStatus -Missing 3>$null | ForEach-Object { $_.Name })
    } else {
        @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) -Source 'Install-DFTool' | ForEach-Object { $_.Name })
    }
    # Fresh checks (a previous partial run may have installed some of these),
    # each made once per call: the question loop below re-plans after every answer.
    # (Found through the caller's scope when New-DFInstallPlan invokes it; a
    # GetNewClosure() copy would lose the module's private functions.)
    $dfInstallChecked = @{}
    $isAvailable = {
        param($r)
        if (-not $r) { return $false }
        if (-not $dfInstallChecked.ContainsKey($r.name)) {
            $dfInstallChecked[$r.name] = [bool](Test-DFToolAvailable -Executable $r.executable -Type $r.type -Force)
        }
        $dfInstallChecked[$r.name]
    }
    $targets = @($targets | Where-Object { $db.ContainsKey($_) -and -not (& $isAvailable $db[$_]) })
    if (-not $targets) { Write-Host 'DotForge: nothing to install.'; return }

    $viaMap = @{}
    if ($Via) { foreach ($t in $targets) { $viaMap[$t] = $Via } }

    # Choices: one question per open gap source, until nothing more can be decided.
    $interactive = -not $UseDefaults -and (Test-DFInteractiveHost)
    $choice = @{}
    # Planning warnings (an InstallVia that doesn't apply) repeat every round: show each once.
    $script:DFInstallWarned = [System.Collections.Generic.HashSet[string]]::new()
    while ($true) {
        $plan = New-DFInstallPlan -Name $targets -ToolDb $db -IsAvailable $isAvailable -Choice $choice -Via $viaMap
        $open = @($plan.Gaps | Where-Object { $_.Options -and $_.Source -and -not $choice.ContainsKey($_.Source) })
        if (-not $open -or -not ($UseDefaults -or $interactive)) { break }
        $g = $open[0]
        $choice[$g.Source] = if ($UseDefaults) { $g.Options[0] }
            else { Read-DFInstallChoice -Prompt "$($g.Tool) needs a manager for $($g.Source)" -Options $g.Options -Default $g.Options[0] }
    }

    Write-DFInstallPlan -Plan $plan
    $gapRows = @(Get-DFInstallGapResult -Plan $plan)
    # -WhatIf: the plan only. Interactive: confirm once. -UseDefaults, or no one
    # to ask: no prompt (without -UseDefaults, only decision-free tools are planned).
    if (-not $plan.Items -or $WhatIfPreference) { return $gapRows }
    $skipConfirm = $PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm']
    if ($interactive -and -not $skipConfirm -and (Read-DFInstallChoice -Prompt "Install $(@($plan.Items).Count) tool(s) as planned above?" -Options 'y', 'n' -Default 'y') -ne 'y') { return $gapRows }

    # Installing changes what's available: the runner gets uncached checks.
    $fresh = { param($r) $r -and (Test-DFToolAvailable -Executable $r.executable -Type $r.type -Force) }
    $results = @(Invoke-DFInstallPlan -Plan $plan -ToolDb $db -IsAvailable $fresh @pathArgs)
    $done = @($results | Where-Object Result -eq 'Installed' | ForEach-Object { $_.Tool })
    if ($done) {
        Register-DFTool -Name $done @pathArgs 3>$null
        $requested = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) 3>$null | ForEach-Object { $_.Name })
        foreach ($t in $done | Where-Object { $_ -notin $requested -and $_ -in $targets }) {
            Write-Warning "DotForge: $t is installed and active now; add it to Tools to load it in future sessions."
        }
    }
    $all = @($results) + $gapRows
    Write-DFInstallSummary -Result $all
    $all
}

# ---- Public/Invoke-DFPicker.ps1
#Requires -Version 7.2

function Invoke-DFPicker {
    <#
    .SYNOPSIS
        Generalized fzf picker. Handles list -> fzf -> parse -> action skeleton.
    .PARAMETER List
        Scriptblock that produces the items to display in fzf, one per line.
        Objects are converted to strings. Required.
    .PARAMETER Header
        Header text shown at the top of the fzf window.
    .PARAMETER Preview
        fzf --preview string. Use {} as placeholder for the selected item.
    .PARAMETER PreviewWindow
        fzf --preview-window value. Default: 'right:60%'.
    .PARAMETER Ansi
        Pass --ansi to fzf (for ANSI-colored input).
    .PARAMETER Multi
        Pass --multi to fzf so Tab marks several items; -Action is called once
        per selected item (or each is returned).
    .PARAMETER Delimiter
        fzf --delimiter value.
    .PARAMETER WithNth
        fzf --with-nth value (which fields to display).
    .PARAMETER Parse
        Scriptblock to transform the raw fzf output line. $_ is the raw line.
        If omitted, the raw line is used as-is.
    .PARAMETER Action
        Scriptblock invoked with the parsed value as param($v).
        If omitted, the parsed value is written to the output stream.
        Ignored when -Expect is used (the caller branches on the returned .Key).
    .PARAMETER Expect
        fzf --expect keys (e.g. 'alt-r','alt-i'). When set, fzf reports which key
        the user pressed and the picker switches to "multi-key" mode: instead of
        returning/acting on the parsed value, it returns a single object
        [pscustomobject]@{ Key = <pressed key>; Selected = @(<parsed items>) }.
        The pressed key is '' when the user accepted with Enter. -Action is not
        invoked in this mode.
    .PARAMETER Bind
        fzf --bind specs (e.g. 'alt-i:execute(winget install --id {2})'). Each
        entry is passed as its own --bind. Use for act-in-place bindings that run
        a command while fzf stays open.
    .PARAMETER FzfArgs
        Extra fzf arguments passed through verbatim (appended last). Escape hatch
        for fzf flags this function does not model directly.
    .DESCRIPTION
        Runs the list -> fzf -> parse -> action skeleton that every DotForge
        picker is built on: evaluates -List, pipes the items to fzf with the
        given flags, optionally transforms each selected line with -Parse, then
        passes it to -Action or returns it on the output stream. Pressing Esc in
        fzf returns nothing and runs no action.

        The picker executable is fzf, or the one named by $Env:Picker (any
        fzf-compatible picker, e.g. 'sk' for skim). If it is not on PATH, the
        call throws a terminating error.

        A -List scriptblock that uses local variables from the caller must be
        bound with .GetNewClosure() (e.g. { $topics }.GetNewClosure()); without
        it the variables resolve in the wrong scope and the list is empty.

        Uses the private Invoke-DFFzf wrapper so tests can mock fzf without
        spawning a real process. Side effects: starts the picker process, plus
        whatever -Action, -Preview and -Bind commands do.
    .EXAMPLE
        Invoke-DFPicker -List { git branch } -Header 'Select branch' -Parse { $_.TrimStart('*').Trim() } -Action { param($b) git checkout $b }

        Fuzzy-selects a git branch and checks it out. -Parse strips the '* '
        marker and indentation that git branch prints.
    .EXAMPLE
        $file = Invoke-DFPicker -List { Get-ChildItem -Name } -Preview 'type {}'

        Fuzzy-selects a file from the current directory, previewing it with
        cmd.exe's type (fzf runs preview commands through cmd.exe on Windows),
        and returns the selected name (nothing if you press Esc).
    .EXAMPLE
        $r = Invoke-DFPicker -List { Get-Process | ForEach-Object { "$($_.Name)`t$($_.Id)" } } `
            -Delimiter "`t" -WithNth 1 -Expect 'alt-k' -Parse { ($_ -split "`t")[1] }
        if ($r.Key -eq 'alt-k') { Stop-Process -Id $r.Selected -WhatIf } else { Get-Process -Id $r.Selected }

        Shows process names while carrying the id in a hidden field. Enter shows
        the process; Alt-K previews stopping it. -Expect makes both keys select
        the same item but drive different actions.
    .OUTPUTS
        System.String — selected (and optionally parsed) item when -Action is omitted.
        None — when -Action is provided (side-effect only).
        System.Management.Automation.PSCustomObject — { Key; Selected } when -Expect is used.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$List,
        [string]$Header        = '',
        [string]$Preview       = '',
        [string]$PreviewWindow = 'right:60%',
        [switch]$Ansi,
        [switch]$Multi,
        [string]$Delimiter     = '',
        [string]$WithNth       = '',
        [scriptblock]$Parse,
        [scriptblock]$Action,
        [string[]]$Expect,
        [string[]]$Bind,
        [string[]]$FzfArgs
    )

    $pickerArgs = [System.Collections.Generic.List[string]]@('--preview-window', $PreviewWindow)
    if ($Preview)   { $pickerArgs.AddRange([string[]]@('--preview',   $Preview)) }
    if ($Header)    { $pickerArgs.AddRange([string[]]@('--header',    $Header)) }
    if ($Ansi)      { $pickerArgs.Add('--ansi') }
    if ($Multi)     { $pickerArgs.Add('--multi') }
    if ($Delimiter) { $pickerArgs.AddRange([string[]]@('--delimiter', $Delimiter)) }
    if ($WithNth)   { $pickerArgs.AddRange([string[]]@('--with-nth',  $WithNth)) }
    if ($Expect)    { $pickerArgs.AddRange([string[]]@('--expect', ($Expect -join ','))) }
    foreach ($b in $Bind) { $pickerArgs.AddRange([string[]]@('--bind', $b)) }
    if ($FzfArgs)   { $pickerArgs.AddRange([string[]]$FzfArgs) }

    $items = @(& $List)
    if (-not $items.Count) { Write-Host 'Nothing to pick from.'; return }
    $selected = Invoke-DFFzf -InputItems $items -FzfArgs $pickerArgs
    if (-not $selected) { return }

    if ($Expect) {
        # fzf prints the pressed key on the first line (empty string for Enter),
        # then the selection(s). Return both so the caller can branch on the key.
        $lines  = @($selected)
        $key    = $lines[0]
        $picked = @($lines | Select-Object -Skip 1 | ForEach-Object {
            if ($Parse) { $_ | ForEach-Object $Parse } else { $_ }
        })
        return [pscustomobject]@{ Key = $key; Selected = $picked }
    }

    foreach ($item in @($selected)) {
        $value = if ($Parse) { $item | ForEach-Object $Parse } else { $item }
        if ($Action) { & $Action $value } else { $value }
    }
}

# ---- Public/Invoke-DFToolSetup.ps1
#Requires -Version 7.2

function Invoke-DFToolSetup {
    <#
    .SYNOPSIS
        Runs a tool's one-time setup again: its seeded config files, then its setup script.
    .DESCRIPTION
        Setup normally runs once per machine, the first time a tool is
        activated, and is then recorded so it never repeats (a config file you
        delete stays deleted). This clears that record for one tool and runs
        setup now. A seeded file that exists is kept, unless -Force, which
        overwrites it with DotForge's default after confirmation. The tool
        must be active in this session.
    .PARAMETER Name
        The tool.
    .PARAMETER Force
        Overwrite seeded files that exist (asks first).
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch

        Recreates fastfetch's default config if you deleted it.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch -Force

        Replaces your fastfetch config with DotForge's default.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/writing-a-tool.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [switch]$Force, [string]$ToolsPath)
    $s = Get-DFToolStatus -Name $Name 3>$null
    if (-not $s -or $s.State -ne 'Active') {
        Write-Error "DotForge: $Name is not active in this session; put it in Tools and run Start-DFSession first."
        return
    }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $tool = (Import-DFToolDb -Name $Name @pathArgs)[$Name]
    $toolsDir = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath } else { Join-Path $PSScriptRoot '../Tools' })
    $seed = if ($tool.setup) { $tool.setup.seed }
    if ($Force -and $seed) {
        foreach ($p in $seed.PSObject.Properties) {
            $dest = ConvertTo-DFPath (Expand-DFXdgPath $p.Name)
            if ((Test-Path -LiteralPath $dest) -and $PSCmdlet.ShouldProcess($dest, 'Overwrite with the default')) { Remove-Item -LiteralPath $dest }
        }
    }
    # Re-running setup is what the command is for, so only -WhatIf stops here; no prompt otherwise.
    if ($WhatIfPreference -and -not $PSCmdlet.ShouldProcess($Name, 'Run the one-time setup again')) { return }
    # A file the last setup seeded is DotForge's, not one the user already had.
    $seededPath = @(Get-DFSeededPath -Name $Name)
    Clear-DFToolSetupState -Name $Name
    Invoke-DFToolCompanion -Tool $tool -ToolsPath $toolsDir -SetupOnly -SeededPath $seededPath
    Write-DFSetupNoteNotice
}

# ---- Public/New-DFDirectory.ps1
#Requires -Version 7.2

function New-DFDirectory {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent.
    .DESCRIPTION
        Wraps New-Item -ItemType Directory -Force, creating any missing parent
        directories. Succeeds silently if the directory already exists; emits a
        warning if creation fails. An absolute path is canonicalized with
        ConvertTo-DFPath first; a relative path is created relative to the
        current location. Null or empty paths are skipped. All DotForge
        directory creation uses this function.
    .PARAMETER Path
        Directory path to create. Empty or null values
        are skipped.
    .EXAMPLE
        New-DFDirectory "$Env:XDG_CONFIG_HOME/mytool"

        Creates the directory (and any missing parents) or does nothing if it exists.
    .OUTPUTS
        None. Creates the directory on disk.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        # Canonicalize an absolute path (collapses .., native separators); leave a
        # relative path untouched so creating a relative dir stays valid and silent.
        if ([System.IO.Path]::IsPathRooted($Path)) { $Path = ConvertTo-DFPath $Path }
        try {
            New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                throw [System.IO.IOException]::new("Cannot create '$Path' because a file or directory with the same name already exists.")
            }
        }
        catch {
            Write-Warning "DotForge: couldn't create '$Path': $($_.Exception.Message)"
        }
    }
}

# ---- Public/New-DFShim.ps1
#Requires -Version 7.2

function New-DFShim {
    <#
    .SYNOPSIS
        Creates a .cmd shim that forwards invocations to a target executable,
        preserving the caller's working directory and exit code.
    .DESCRIPTION
        Generates a Windows .cmd batch file in the shims directory that, when
        invoked, runs the target executable with all forwarded arguments from
        the caller's own current directory -- so relative-path arguments
        resolve the way the user expects -- and correctly propagates the exit
        code. Put the shims directory on $PATH once and create shims as needed.
        Accepts a DotForge tool name (DB lookup) or an explicit -Target path.
    .PARAMETER Target
        Path to the target executable; must be an existing file. Bypasses the
        tool registry lookup. When -Name is omitted, the shim
        name is derived from the target's basename (without extension).
    .PARAMETER Name
        Shim filename (without .cmd extension). When -Target is omitted, also
        used as the DotForge tool name to look up the executable path in the registry.
        Optional when -Target is given; derived from the target's basename if omitted.
    .PARAMETER ShimsPath
        Directory where the shim is written. Defaults to $DFConfig['ShimsPath'],
        then $HOME\.local\bin.
    .PARAMETER Force
        Overwrite an existing shim without error.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    .EXAMPLE
        New-DFShim 'C:\tools\grep\grep.exe'

        Creates $HOME\.local\bin\grep.cmd; name derived from the executable basename.
    .EXAMPLE
        New-DFShim -Name ripgrep

        Creates $HOME\.local\bin\ripgrep.cmd pointing at the ripgrep executable
        found via the DotForge tool registry. Warns if $HOME\.local\bin is not on PATH.
    .EXAMPLE
        New-DFShim 'C:\tools\myapp\myapp.exe' -Name myapp

        Creates a shim with an explicit name, bypassing name derivation.
    .EXAMPLE
        New-DFShim 'C:\tools\myapp\myapp.exe' -Force

        Overwrites an existing shim.
    .EXAMPLE
        New-DFShim -Name ripgrep -WhatIf

        Shows what would be created without writing any file.
    .OUTPUTS
        None. Writes <ShimsPath>\<Name>.cmd, creating the directory if needed.
        Errors (non-terminating) when neither -Target nor -Name is given, the
        target doesn't exist, the tool is unknown or not installed, or the shim
        already exists without -Force. Warns when the shims directory is not on
        PATH.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Target,

        [string]$Name,

        [string]$ShimsPath,

        [switch]$Force,

        [string]$ToolsPath
    )

    # 0. Derive Name from Target basename if not provided; error if neither given
    if ($Target -and -not $Name) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($Target)
    } elseif (-not $Target -and -not $Name) {
        Write-Error 'DotForge: Provide -Target (path to executable) or -Name (tool registry lookup).'
        return
    }

    # 1. Resolve shims directory
    $shimsDir = if ($ShimsPath) {
        $ShimsPath
    } elseif (Get-DFConfig ShimsPath) {
        Get-DFConfig ShimsPath
    } else {
        Join-Path $HOME '.local' 'bin'
    }

    # Canonicalize (expands a ~ in ShimsPath / $DFConfig['ShimsPath'], collapses ..,
    # normalizes separators) before creating the dir, checking PATH, and naming the shim.
    $shimsDir = ConvertTo-DFPath $shimsDir

    # 2. Create directory (idempotent)
    New-DFDirectory $shimsDir

    # 3. PATH check
    $onPath = $Env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object {
            try { ConvertTo-DFPath $_ } catch { }
        } |
        Where-Object { $_ -eq $shimsDir }
    if (-not $onPath) {
        Write-Warning "DotForge: '$shimsDir' is not on PATH — shims won't be invocable until it is added"
    }

    # 4. Resolve target executable
    $resolvedTarget = $null
    if ($Target) {
        if (-not (Test-Path $Target -PathType Leaf)) {
            Write-Error "DotForge: Target '$Target' does not exist or is not a file"
            return
        }
        $resolvedTarget = $Target
    } else {
        $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
        $db = Import-DFToolDb @dbArgs
        if (-not $db.ContainsKey($Name)) {
            Write-Error "DotForge: Tool '$Name' not found in registry. Use -Target to specify the executable path."
            return
        }
        $executable = $db[$Name].executable
        $found = Get-Command $executable -ErrorAction Ignore
        if (-not $found) {
            Write-Error "DotForge: Tool '$Name' executable '$executable' not found on PATH. Is the tool installed?"
            return
        }
        $resolvedTarget = $found.Source
    }

    # 5. Shim existence check
    $shimPath = Join-Path $shimsDir "$Name.cmd"
    if ((Test-Path $shimPath) -and -not $Force -and -not $WhatIfPreference) {
        Write-Error "DotForge: Shim '$shimPath' already exists. Use -Force to overwrite."
        return
    }

    # 6. Write shim
    # No `cd` here: the shim must preserve the caller's own working directory
    # so relative-path arguments resolve the way the user expects, not against
    # the target executable's install directory.
    if ($PSCmdlet.ShouldProcess($shimPath, 'Create shim')) {
        $lines = @(
            '@echo off'
            'setlocal'
            "`"$resolvedTarget`" %*"
            'set "_exit=%ERRORLEVEL%"'
            'endlocal & exit /b %_exit%'
        )
        Set-Content -Path $shimPath -Value ($lines -join "`r`n") -Encoding ASCII -NoNewline
        Write-Verbose "DotForge: shim created → $shimPath"
    }
}

# ---- Public/Register-DFTool.ps1
#Requires -Version 7.2

function Register-DFTool {
    <#
    .SYNOPSIS
        Adds one or more tools to the current session, without restarting the shell.
    .DESCRIPTION
        Start-DFSession configures the tools your profile requests. Use
        Register-DFTool to add another tool (or +group) to the session you
        are in, for example to try one out, or after installing it.
        Install-DFTool calls it for the tools it installs.

        Each named tool goes through the same steps Start-DFSession uses: its
        record is read, role winners are recomputed over the session's tools
        plus the new ones, and an installed tool is set up (once ever) and
        activated:

          1. Its XDG configuration: the env vars in xdg.vars and the
             directories in xdg.dirs.
          2. The non-XDG env vars in its "env" block.
          3. Its aliases and wrapper functions, and its declarative picker.
          4. For each role it wins, that role's variables and aliases.
          5. Its companion Tools/<name>.ps1 and its role hooks; and once
             ever per machine, Tools/<name>.setup.ps1.

        A tool that isn't installed is reported as missing, a tool that fails
        is reported and the rest continue, and a tool you name is applied again
        even if it is already active (useful after changing its settings). Get-DFToolStatus shows the result. Registering a tool doesn't
        add it to your profile's Tools: add it there to load it in future
        sessions.

        Side effects: changes are scoped to the current session (env vars,
        functions, aliases, key bindings), except what a companion or setup
        script writes to disk: deployed config and theme files under
        $XDG_CONFIG_HOME, caches under $XDG_CACHE_HOME, the setup-state file,
        and for delta, one include.path line in your global git config. Some
        tools relocate their data to XDG paths, so a tool that already had
        files in its old default location stops seeing them.
    .PARAMETER Name
        Tool names and +groups to add. An unknown name warns and is skipped.
    .PARAMETER ToolsPath
        Read tool records and companions from this directory instead of the
        module's Tools folder. Intended for tests.
    .EXAMPLE
        Register-DFTool -Name glow

        Adds glow to this session.
    .EXAMPLE
        Register-DFTool +git

        Adds every tool in the +git group (delta, gh, lazygit) to this session.
    .OUTPUTS
        None. Changes the current session and may write the files listed above.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/safety.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [string]$ToolsPath
    )
    if ($ToolsPath) { $ToolsPath = ConvertTo-DFPath $ToolsPath }

    # An old-style global $DFConfig is no longer read; say so instead of silently
    # dropping its settings (some of them, like SkipSetup, are protections).
    Assert-DFSessionConfigured
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    # The session's requested tools plus the new ones, so role winners are
    # computed over everything requested; tools already active are skipped.
    $request = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:DFSessionStatus) {
        foreach ($s in $script:DFSessionStatus.Values) {
            if ($s.State -eq 'Excluded') { continue }
            $request.Add([pscustomobject]@{ Name = $s.Name; RequestedBy = $s.RequestedBy; Excluded = $false })
            $null = $seen.Add($s.Name)
        }
    }
    foreach ($e in @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs) -Source 'Register-DFTool')) {
        if ($seen.Add($e.Name)) { $e.RequestedBy = 'Register-DFTool'; $request.Add($e) }
    }

    # Tools you name are re-applied even if already active (e.g. after a config change).
    $reapply = @(foreach ($e in @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs) 3>$null)) { $e.Name })
    # ...and read again from disk, so a record you edited or copied to your own folder takes effect.
    # Warnings come from the activation's read below.
    if ($reapply) { $null = Import-DFToolDb -Name $reapply -Force @pathArgs 3>$null }
    $active = @(Invoke-DFSessionActivation -Request $request.ToArray() -Reactivate $reapply @pathArgs)
    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) { Write-DFConflictNotice -Tools $active }
    Write-DFSessionNotice
}

# ---- Public/Remove-DFTool.ps1
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
            Write-DFRemoveLeftover -Tool $db[$toolName]
        }
        $result
    }
}

# ---- Public/Set-DFToolTheme.ps1
#Requires -Version 7.2

function Set-DFToolTheme {
    <#
    .SYNOPSIS
        Switches an active tool's theme for the rest of this session.
    .DESCRIPTION
        For a tool whose theme block DotForge applies itself: resolves -Theme
        like the configured one (theme map, theme files, built-in names, with a
        warning and the tool's fallback for a name it doesn't know), re-applies
        the theme's environment variables, and makes the tool's wrapper use it
        from the next call. The choice is explicit, so it replaces a value you
        set outside DotForge.

        It lasts for this session; to keep it, set the tool's theme key (for
        example $DFConfig GlowTheme) in your profile. A tool whose theme is
        applied by its companion names its own command instead, and a theme
        written to a config file once, at setup, can't be switched here.
    .PARAMETER Name
        The tool, e.g. glow. Tab completion lists active tools with a theme.
    .PARAMETER Theme
        A theme name, or the full path to a theme file for tools that read theme files.
    .EXAMPLE
        Set-DFToolTheme glow dracula

        Renders Markdown with glow's dracula style for the rest of the session.
    .EXAMPLE
        Set-DFToolTheme bat 'Monokai Extended'

        Switches bat's BAT_THEME.
    .OUTPUTS
        PSCustomObject: Name, Native, Value (what the tool is given) and Explicit.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            foreach ($toolName in @($script:DFSessionToolDb.Keys | Sort-Object)) {
                if ($toolName -like "$wordToComplete*" -and $script:DFSessionToolDb[$toolName].theme -and (Test-DFToolActive $toolName)) { $toolName }
            }
        })]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Theme
    )
    $tool = if ($script:DFSessionToolDb) { $script:DFSessionToolDb[$Name] }
    if (-not $tool -or -not (Test-DFToolActive $Name)) { Write-Error "DotForge: $Name isn't active in this session."; return }
    if (-not $tool.theme) { Write-Error "DotForge: $Name has no theme to switch."; return }
    # A companion that applies its theme in code names a function that takes the theme's value
    # (the native name, checked against valid, or the fallback).
    if ($tool.theme.apply) {
        # Defined by the companion only when it applies the theme (a prompt engine, only when it won).
        if (-not (Get-Command -Name $tool.theme.apply -ErrorAction Ignore)) {
            Write-Error "DotForge: $Name's theme isn't applied in this session ($($tool.theme.apply) isn't defined)."
            return
        }
        $resolved = Resolve-DFToolTheme -Tool $tool -Name $Theme
        Set-DFSessionTheme -Name $Name -Theme $resolved
        if ($resolved.Value) { & $tool.theme.apply -Name $resolved.Value }
        return $resolved
    }
    if ($tool.theme.command) { Write-Error "DotForge: $Name's theme is applied by its companion; use $($tool.theme.command)."; return }
    if (-not (Test-DFThemeSwitchable -Tool $tool)) {
        Write-Error "DotForge: $Name's theme is written to its config once, at setup, so it can't be switched live; edit its config file."
        return
    }
    $resolved = Resolve-DFToolTheme -Tool $tool -Name $Theme
    Set-DFSessionTheme -Name $Name -Theme $resolved
    Set-DFToolThemeEnv -Tool $tool -Theme $resolved -ExplicitReason "Set-DFToolTheme chose '$Theme'"
    $resolved
}

# ---- Public/Start-DFSession.ps1
#Requires -Version 7.2

function Start-DFSession {
    <#
    .SYNOPSIS
        Configures the tools you request for this PowerShell session. Call it once, from your profile.
    .DESCRIPTION
        Start-DFSession is DotForge's profile entry point:
          1. Stores the configuration (unknown keys warn): -Config when given,
             else the config file, $XDG_CONFIG_HOME/dotforge/config.psd1
             (~/.config/dotforge/config.psd1). -Config replaces the file
             entirely; the two are never merged. The file is a PowerShell data
             file (literal values and comments, no code). A missing or
             unreadable file warns, naming it, and configures nothing.
          2. Exports the XDG folders (XDG_CONFIG_HOME and the rest).
          3. Resolves Tools and ExcludeTools: +groups expand, exclusions win.
          4. Reads only the requested tools' records, checks which are
             installed, and picks role winners among them.
          5. Runs each installed tool's one-time setup (first time only), then
             activates it: environment variables, aliases, pickers, companion,
             role hook. One tool's failure never stops the rest.
          6. Checks for coreutils shadowing DotForge's commands (SkipConflictCheck
             turns this off).
          7. Warns about requested tools that aren't installed or failed, with
             the command that installs them.

        With ShowBanner, it clears the screen (unless BannerClear is $false)
        and prints one line at once; slow banner work (fastfetch, drive health,
        the public IP) runs in the background while tools load, and the banner
        prints a line at a time when the load ends.

        Tools that aren't requested are never looked at. Nothing is installed:
        run Install-DFTool -Missing for that. Calling Start-DFSession again
        applies the new config and activates newly requested tools; a tool no
        longer requested stays active until you open a new shell.

        Config keys (see docs/guide/configuration.md for all of them):
            Tools              Tool names and +groups to configure.
            ExcludeTools       Tool names and +groups to leave out.
            Defaults           Role -> preferred tool, e.g. @{ prompt = 'starship' }.
            Theme              Shared theme name.
            SkipSetup          Tools whose one-time setup never runs.
            SkipConflictCheck  $true skips the coreutils shadowing check.
            IgnoreConflicts    Command names left out of that check.
    .PARAMETER Config
        The session configuration hashtable. Optional: without it, the config
        file is read. When given, the config file is not read at all.
    .PARAMETER ToolsPath
        Read tool records and companions from this folder instead of the
        module's Tools/. For testing and custom tool sets.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession

        Configures what ~/.config/dotforge/config.psd1 asks for, e.g. a file
        holding @{ Tools = @('+core', 'starship'); Theme = 'catppuccin-mocha' }.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession -Config @{ Tools = @('+core', 'starship'); ExcludeTools = @('less') }

        Configures every +core tool except less, plus starship, ignoring the config file.
    .EXAMPLE
        $DFConfig = @{ Tools = @('+core', '+git'); Defaults = @{ pager = 'moor' }; Theme = 'catppuccin-mocha' }
        Start-DFSession -Config $DFConfig

        Keeps the configuration in a variable of your own. DotForge doesn't read
        the variable itself, only what you pass.
    .OUTPUTS
        None. See Get-DFToolStatus for what the session decided.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Config,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    Write-DFDevBuildNotice
    # -Config replaces the config file entirely; the two are never merged.
    if (-not $PSBoundParameters.ContainsKey('Config')) { $Config = Read-DFConfigFile }
    Set-DFSessionConfig -Config $Config
    Set-DFXdgEnvironment

    $request = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -ExcludeTools @(Get-DFConfig ExcludeTools) `
        -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs))
    # ShowBanner: the first line now, the rest's slow parts in the background while tools load.
    $banner = Start-DFBanner -Tools @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)

    # A second call only adds; a tool that is no longer requested can't be
    # cleanly undone (aliases, environment, prompt hooks), so say so.
    if ($script:DFSessionStatus) {
        $still = @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)
        $dropped = @($script:DFSessionStatus.Values | Where-Object { $_.State -eq 'Active' -and $_.Name -notin $still } | ForEach-Object Name)
        if ($dropped) {
            Write-Warning "DotForge: $($dropped -join ', ') $(if ($dropped.Count -eq 1) { 'is' } else { 'are' }) no longer requested but stay active until you open a new shell."
        }
    }

    $shown = $false
    try {
        $null = Invoke-DFSessionActivation -Request $request @pathArgs
        # Before the notices, so warnings print under the banner.
        Show-DFBanner -State $banner
        $shown = $true
    } finally {
        # A failed or stopped load leaves no banner work running.
        if (-not $shown) { Stop-DFBanner -State $banner }
        Set-DFBannerSessionStarted
    }

    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) {
        $activeNames = @($script:DFSessionStatus.Values | Where-Object State -eq 'Active' | ForEach-Object Name)
        $active = if ($activeNames) { @((Import-DFToolDb -Name $activeNames @pathArgs).Values) } else { @() }
        Write-DFConflictNotice -Tools $active
    }
    Write-DFSessionNotice
}

# ---- Public/Update-DFTool.ps1
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
        them the way Install-DFTool does. A failed update shows the manager's
        last lines; -Verbose shows all of its output.

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
    if (-not $toUpdate) {
        # Only when every named tool was checked and is current: an unknown name already warned.
        if ($rows -and @($rows | Where-Object State -ne 'UpToDate').Count -eq 0 -and $rows.Count -eq @($targets).Count) { Write-Host 'Everything is up to date.' }
        return $results.ToArray()
    }

    foreach ($group in $toUpdate | Group-Object { "$($_.Found.Manager.name)|$($_.Found.Source)" }) {
        $found = $group.Group[0].Found
        $tools = @($group.Group.Tool)
        if (-not $PSCmdlet.ShouldProcess("$($tools -join ', ') through $($found.Manager.name)", 'Update')) { continue }
        $outcomes = @(Invoke-DFManagerOperation -Operation update -Found $found -Tool @($tools | ForEach-Object { $db[$_] }) -Ids ([string[]]@($group.Group.Found.Id)) -ToolDb $db)
        $outcomes = @(Resolve-DFPartialUpdate -Found $found -Rows @($group.Group) -Outcomes $outcomes)
        for ($n = 0; $n -lt $tools.Count; $n++) {
            $results.Add((ConvertTo-DFManagerResult -Tool $tools[$n] -Outcome $outcomes[$n] -Manager $found.Manager.name -Success 'Updated'))
        }
        if ($found.Block.reactivate -and @($outcomes | Where-Object ExitCode -eq 0).Count) { Register-DFTool -Name $found.Manager.name @pathArgs 3>$null }
    }
    $results.ToArray()
}
