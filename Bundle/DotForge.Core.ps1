# DotForge startup core, bundled by build/Build-DFCoreBundle.ps1. Do not edit: edit the sources.
# sources-sha256: daf2f81f48ba4b5d570048e756e7f1a6a6c2ad09397a9fefbce2effe2167bdca

# ---- Shared/ConvertTo-DFPath.ps1
#Requires -Version 7.0

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

# ---- Shared/DFInstallSource.ps1
#Requires -Version 7.0

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
    $system = @($managers | Where-Object { $_.roles.PSObject.Properties['package-manager'] } |
        Sort-Object @{ Expression = { $_.roles.'package-manager'.priority }; Descending = $true }, name |
        ForEach-Object { $_.installs[0].from })
    $other = @($managers | ForEach-Object { $_.installs | ForEach-Object { $_.from } } | Where-Object { $_ -notin $system } | Sort-Object -Unique)
    [string[]]@($system + $other | Select-Object -Unique)
}

function Get-DFInstallSourceOrder {
    <#
    .SYNOPSIS
        Orders one tool's candidate sources: InstallVia, the tool's install.prefer, InstallOrder, then DotForge's order.
    .DESCRIPTION
        Only sources the tool has a package for are returned. ExcludeSources
        removes a source unless InstallVia names it for this tool. An
        InstallVia source the tool has no package for warns and is ignored.
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
    $excluded = @(Get-DFConfig ExcludeSources)
    $ordered = @(@($pinned) + @($Tool.install?.prefer) + @(Get-DFConfig InstallOrder) + (Get-DFBuiltInSourceOrder -ToolDb $ToolDb) + $have |
        Where-Object { $_ -and $_ -in $have } | Select-Object -Unique)
    [string[]]@($ordered | Where-Object { $_ -eq $pinned -or $_ -notin $excluded })
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
        block for Source), Ref, Gap, Options, and Sources (the candidate order
        it walked).
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
    $result = [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Ref = $null; Gap = $null; Options = @(); Sources = [string[]]$sources }
    if (-not $sources) {
        $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties.Name })
        $result.Gap = if (-not $have) { 'no package in any source' }
                      else { "no source left (only $($have -join ', ') $(if ($have.Count -eq 1) { 'has' } else { 'have' }) it, and ExcludeSources removes $(if ($have.Count -eq 1) { 'it' } else { 'them' }))" }
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

# ---- Shared/Format-DFInstallCommand.ps1
#Requires -Version 7.0

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
        return (@($i.function) + $fnArgs) -join ' '
    }
    (@($i.command | ForEach-Object { if ($_ -eq '{id}') { $idText } else { $_ } })) -join ' '
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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

$script:DFToolDb = $null

function Import-DFToolDb {
    <#
    .SYNOPSIS
        Loads Tools/*.json files into a cached hashtable keyed by tool name.
        Validates each file with Test-DFToolSchema; invalid files are skipped with a warning.
        Valid records are normalized with ConvertTo-DFToolRecord, so every known
        field exists and callers use plain property access.
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
        Supplying this parameter always forces a fresh, uncached read and never
        populates the shared cache -- only calls using the default location
        participate in caching, so a caller with its own directory never sees
        (or clobbers) another caller's registry.
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
                $file = Join-Path $ToolsPath "$n.json"
                if (-not (Test-Path $file -PathType Leaf)) {
                    Write-Warning "DotForge: no tool record for '$n' ($file)."
                    continue
                }
                $record = Read-DFToolRecordFile -Path $file
                if (-not $record) { continue }
                if (-not $explicitToolsPath) { $script:DFToolRecordCache[$record.name] = $record }
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
    .OUTPUTS
        pscustomobject (a ConvertTo-DFToolRecord record), or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $leaf = Split-Path $Path -Leaf
    try {
        $text = [IO.File]::ReadAllText($Path)
        # Unchanged shipped record: already validated and normalized at build time.
        $entry = (Get-DFToolRegistry)[[IO.Path]::GetFileNameWithoutExtension($Path)]
        if ($entry -and $entry.sha256 -eq (Get-DFToolRecordHash -Text $text)) { return $entry.record }
        $tool = $text | ConvertFrom-Json
    } catch {
        Write-Warning "DotForge: Failed to parse $leaf`: $($_.Exception.Message)"
        return $null
    }
    $errors = @(); $warnings = @()
    if (-not (Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) -Warnings ([ref]$warnings))) {
        Write-Warning "DotForge: $leaf schema errors: $($errors -join '; ')"
        return $null
    }
    foreach ($w in $warnings) { Write-Warning "DotForge: $leaf`: $w" }
    ConvertTo-DFToolRecord $tool
}

function Get-DFToolNames {
    <#
    .SYNOPSIS
        Lists the names of every tool DotForge has a record for, from file names alone.
    .DESCRIPTION
        Reads no file: a record's name equals its file name (tests enforce it),
        so request resolution can validate names without loading records.
    .PARAMETER ToolsPath
        The tools folder. Default: the module's Tools/.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'))
    @(Get-ChildItem $ToolsPath -Filter '*.json' -File -ErrorAction Ignore | ForEach-Object BaseName)
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
            packages / xdg / env / aliases / picker / themeMap /
            settings / setup $null, roles an empty object, executableExclude @()

        roles is an object keyed by role name; each value is { priority
        (default 0); optIn (default $false); aliases (same shape as top-level
        aliases, or $null); env; legacy }. An opt-in member is considered only
        when $DFConfig.Defaults selects it for that role. A legacy "role": "x"
        string becomes roles.x with priority 0 and legacy $true.

        Nested shapes are normalized too: xdg always has method, vars, dirs,
        instructions and compliance; setup, when present, has seed (an object
        mapping destination path template to a file under Tools/, or $null);
        installs, when present, is a list of blocks (a single object in the
        JSON becomes a one-block list), each with from, command (string[] or
        $null), function, args, batch, elevate and reactivate ($false by
        default) and feeds ($null, or { list; add; id = '{feed}/{id}' }); install, when
        present, has prefer (string[]); each alias is
        { command; args[] } with a missing args meaning none; an object picker
        has every field, with preview '', preview_window 'right:60%',
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

    $get = { param($obj, $name, $default) $p = $obj.PSObject.Properties[$name]; if ($p) { $p.Value } else { $default } }

    $xdg = & $get $Tool 'xdg' $null
    if ($xdg) {
        $xdg = [pscustomobject]@{
            method         = & $get $xdg 'method' $null
            vars           = & $get $xdg 'vars' $null
            dirs           = @(& $get $xdg 'dirs' @())
            instructions   = & $get $xdg 'instructions' $null
            compliance     = & $get $xdg 'compliance' $null
        }
    }

    $normalizeAliases = {
        param($raw)
        if (-not $raw) { return $null }
        $normalized = [ordered]@{}
        foreach ($a in $raw.PSObject.Properties) {
            $rawArgs = & $get $a.Value 'args' $null
            $normalized[$a.Name] = [pscustomobject]@{
                command = & $get $a.Value 'command' $null
                # @() around the whole if: a one-element array assigned from an
                # if-expression would otherwise unwrap to a bare string.
                args    = [object[]]@(if ($null -ne $rawArgs) { $rawArgs })
            }
        }
        [pscustomobject]$normalized
    }
    $aliases = & $normalizeAliases (& $get $Tool 'aliases' $null)

    $roles = [ordered]@{}
    $rawRoles = & $get $Tool 'roles' $null
    if ($rawRoles) {
        foreach ($r in $rawRoles.PSObject.Properties) {
            $roles[$r.Name] = [pscustomobject]@{
                priority = [int](& $get $r.Value 'priority' 0)
                optIn    = [bool](& $get $r.Value 'optIn' $false)
                aliases  = & $normalizeAliases (& $get $r.Value 'aliases' $null)
                env      = & $get $r.Value 'env' $null
                legacy   = $false
            }
        }
    }
    # Role v1 declared a single "role" string; read it as a priority-0 membership.
    # legacy marks it so registration keeps v1 behavior: no hook expected, and a
    # loser's top-level aliases that the role reserves are left out.
    $legacyRole = & $get $Tool 'role' $null
    if ($legacyRole -and -not $roles.Contains($legacyRole)) {
        $roles[$legacyRole] = [pscustomobject]@{ priority = 0; optIn = $false; aliases = $null; env = $null; legacy = $true }
    }

    $picker = & $get $Tool 'picker' $null
    if ($picker -is [pscustomobject]) {
        $picker = [pscustomobject]@{
            function          = & $get $picker 'function' $null
            alias             = & $get $picker 'alias' $null
            list              = & $get $picker 'list' $null
            list_accepts_path = [bool](& $get $picker 'list_accepts_path' $false)
            preview           = & $get $picker 'preview' ''
            preview_window    = & $get $picker 'preview_window' 'right:60%'
            ansi              = [bool](& $get $picker 'ansi' $false)
            header            = & $get $picker 'header' ''
            action            = & $get $picker 'action' $null
            parse             = & $get $picker 'parse' $null
        }
    }

    $setup = & $get $Tool 'setup' $null
    if ($setup) { $setup = [pscustomobject]@{ seed = & $get $setup 'seed' $null } }

    # A package manager's installs blocks (install spec section 1): one object,
    # or a list when it installs from several sources (uv: PyPI tools and Python).
    $installs = & $get $Tool 'installs' $null
    if ($null -ne $installs) {
        $installs = [object[]]@(foreach ($blk in @($installs)) {
            $feeds = & $get $blk 'feeds' $null
            if ($feeds) {
                $feeds = [pscustomobject]@{
                    list = [string[]]@(& $get $feeds 'list' @())
                    add  = [string[]]@(& $get $feeds 'add' @())
                    id   = & $get $feeds 'id' '{feed}/{id}'
                }
            }
            $command = & $get $blk 'command' $null
            [pscustomobject]@{
                from       = & $get $blk 'from' $null
                command    = $(if ($null -ne $command) { [string[]]@($command) })
                function   = & $get $blk 'function' $null
                args       = & $get $blk 'args' $null
                batch      = [bool](& $get $blk 'batch' $false)
                elevate    = [bool](& $get $blk 'elevate' $false)
                reactivate = [bool](& $get $blk 'reactivate' $false)
                feeds      = $feeds
            }
        })
    }
    $install = & $get $Tool 'install' $null
    if ($install) { $install = [pscustomobject]@{ prefer = [string[]]@(& $get $install 'prefer' @()) } }

    $record = [ordered]@{
        name        = $Tool.name
        executable  = $Tool.executable
        type        = & $get $Tool 'type' 'exe'
        description = & $get $Tool 'description' ''
        tags        = [object[]]@(& $get $Tool 'tags' @())
        packages    = & $get $Tool 'packages' $null
        xdg         = $xdg
        env         = & $get $Tool 'env' $null
        aliases     = $aliases
        picker      = $picker
        after       = [object[]]@(& $get $Tool 'after' @())
        requires    = [object[]]@(& $get $Tool 'requires' @())
        roles       = [pscustomobject]$roles
        themeMap    = & $get $Tool 'themeMap' $null
        settings    = & $get $Tool 'settings' $null
        executableExclude = [object[]]@(& $get $Tool 'executableExclude' @())
        prewarm     = [bool](& $get $Tool 'prewarm' $true)
        setup       = $setup
        installs    = $installs
        install     = $install
    }
    # Keep fields DotForge doesn't model, so tool authors can carry extra data.
    foreach ($p in $Tool.PSObject.Properties) {
        if (-not $record.Contains($p.Name) -and $p.Name -ne 'role') { $record[$p.Name] = $p.Value }
    }
    [pscustomobject]$record
}

# ---- Shared/Invoke-DFFzf.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
    if ($rest -match '["\x27]') {
        Write-Warning "DotForge: Quoted arguments in `$Env:Pager are not supported. Use --key=value form (e.g. bat --theme=Dracula)."
    }
    [string[]] $pagerArgs = if ($rest) { $rest -split '\s+' } else { @() }
    $Lines | & $program @pagerArgs
}

# ---- Shared/Test-DFOutputPiped.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

function Test-DFToolSchema {
    <#
    .SYNOPSIS
        Validates a tool PSCustomObject against the DotForge tool schema.
        Returns $true if valid; populates -Errors with any violation messages.
    .DESCRIPTION
        Private validator for tool JSON records: required fields, enum values, and the
        shapes of picker, aliases, env, themeMap, after, requires, setup, prewarm and role blocks.
        Errors are collected into a list and returned via the -Errors reference parameter.
    .PARAMETER Tool
        The tool PSCustomObject to validate (typically parsed from JSON).
    .PARAMETER Errors
        Reference to an array that will be populated with validation error messages.
        If validation passes, this array will be empty.
    .PARAMETER Warnings
        Reference to an array that receives non-fatal findings: field names that look
        like misspellings of known fields. A tool with only warnings is still valid.
    .OUTPUTS
        [bool] - $true if valid, $false if any violations found.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [ref]$Errors,
        [ref]$Warnings
    )

    $errs  = [System.Collections.Generic.List[string]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()

    # Helper: safely read a property from a PSCustomObject without throwing under StrictMode
    function PSProp ([PSCustomObject]$obj, [string]$key) {
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

    # Required fields
    if (-not (PSProp $Tool 'name'))       { $errs.Add("Missing required field: name") }
    if (-not (PSProp $Tool 'executable')) { $errs.Add("Missing required field: executable") }

    # type valid values
    $validToolTypes = @('exe', 'module')
    $toolType = PSProp $Tool 'type'
    if ($toolType -and $toolType -notin $validToolTypes) {
        $errs.Add("Invalid type '$toolType'. Valid: $($validToolTypes -join ', ')")
    }

    # xdg.method valid values
    $validMethods = @('default', 'env', 'wrapper', 'manual')
    $xdgMethod = PSProp (PSProp $Tool 'xdg') 'method'
    if ($xdgMethod -and $xdgMethod -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$xdgMethod'. Valid: $($validMethods -join ', ')$(if ($xdgMethod -eq 'config') { ". Seed a default config file with setup.seed instead" })")
    }

    # executableExclude: glob patterns of install locations to skip.
    # Read the property directly: returning it through PSProp would unroll a
    # one-element array into a bare string and fail the array check.
    $exclude = $Tool.PSObject.Properties['executableExclude']?.Value
    if ($null -ne $exclude -and ($exclude -isnot [array] -or @($exclude | Where-Object { $_ -isnot [string] }).Count)) {
        $errs.Add('executableExclude must be an array of strings')
    }

    # packages: source -> an id, or { id, feed: { name, url } } for a third-party feed.
    $pk = PSProp $Tool 'packages'
    if ($pk -is [pscustomobject]) {
        foreach ($p in $pk.PSObject.Properties) {
            $v = $p.Value
            $feed = if ($v -is [pscustomobject]) { PSProp $v 'feed' }
            $ok = ($v -is [string]) -or ($v -is [pscustomobject] -and (PSProp $v 'id') -is [string] -and (PSProp $v 'id') -and
                  ($null -eq $feed -or ((PSProp $feed 'name') -and (PSProp $feed 'url'))))
            if (-not $ok) { $errs.Add("packages.$($p.Name) must be an id, or { id, feed: { name, url } }") }
        }
    }
    if ($Tool.PSObject.Properties['scoopBucket']) {
        $errs.Add('scoopBucket was replaced: put { id, feed: { name, url } } in packages.scoop')
    }

    # roles: an object keyed by role name; priority is an integer and optIn is a boolean when present.
    $roles = PSProp $Tool 'roles'
    if ($null -ne $roles) {
        if ($roles -isnot [pscustomobject]) {
            $errs.Add('roles must be an object keyed by role name')
        } else {
            foreach ($r in $roles.PSObject.Properties) {
                $priority = PSProp $r.Value 'priority'
                if ($null -ne $priority -and $priority -isnot [int] -and $priority -isnot [long]) {
                    $errs.Add("roles.$($r.Name).priority must be an integer")
                }
                $optIn = PSProp $r.Value 'optIn'
                if ($null -ne $optIn -and $optIn -isnot [bool]) {
                    $errs.Add("roles.$($r.Name).optIn must be a boolean")
                }
            }
        }
    }


    # aliases (top level and in role blocks): name -> { command: string; args: [string] }
    $checkAliases = {
        param($aliases, $path)
        if ($null -eq $aliases) { return }
        if ($aliases -isnot [pscustomobject]) { $errs.Add("$path must be an object keyed by alias name"); return }
        foreach ($a in $aliases.PSObject.Properties) {
            if ($a.Value -isnot [pscustomobject] -or (PSProp $a.Value 'command') -isnot [string] -or -not (PSProp $a.Value 'command')) {
                $errs.Add("$path.$($a.Name) must be an object with a string command"); continue
            }
            $args_ = $a.Value.PSObject.Properties['args']?.Value
            if ($null -ne $args_ -and @($args_ | Where-Object { $_ -isnot [string] }).Count) {
                $errs.Add("$path.$($a.Name).args must be strings")
            }
        }
    }
    # env and themeMap: name -> plain value
    $checkMap = {
        param($map, $path, [switch]$StringsOnly)
        if ($null -eq $map) { return }
        if ($map -isnot [pscustomobject]) { $errs.Add("$path must be an object"); return }
        foreach ($p in $map.PSObject.Properties) {
            $v = $p.Value
            $ok = if ($StringsOnly) { $v -is [string] } else { $v -is [string] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [bool] }
            if (-not $ok) { $errs.Add("$path.$($p.Name) must be a $(if ($StringsOnly) { 'string' } else { 'string, number or boolean' })") }
        }
    }

    # Startup cost matters (this runs for every tool on every shell start), so the
    # checkers are only invoked when there is something to check.
    $v = PSProp $Tool 'aliases';  if ($null -ne $v -and ($v -isnot [pscustomobject] -or @($v.PSObject.Properties).Count)) { & $checkAliases $v 'aliases' }
    $v = PSProp $Tool 'env';      if ($null -ne $v) { & $checkMap $v 'env' }
    $v = PSProp $Tool 'themeMap'; if ($null -ne $v) { & $checkMap $v 'themeMap' -StringsOnly }
    if ($roles -is [pscustomobject]) {
        foreach ($r in $roles.PSObject.Properties) {
            $v = PSProp $r.Value 'aliases'; if ($null -ne $v) { & $checkAliases $v "roles.$($r.Name).aliases" }
            $v = PSProp $r.Value 'env';     if ($null -ne $v) { & $checkMap $v "roles.$($r.Name).env" }
        }
    }

    if ($Tool.PSObject.Properties['dependsOn']) {
        $errs.Add('dependsOn was replaced: use after (ordering only) or requires (the tool cannot work without it)')
    }
    $after = $Tool.PSObject.Properties['after']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $after -and ($after -isnot [array] -or @($after | Where-Object { $_ -isnot [string] -or $_ -notmatch '^(role:)?[A-Za-z0-9][A-Za-z0-9._-]*$' }).Count)) {
        $errs.Add('after must be an array of tool names or role:<role> entries')
    }
    $setup = $Tool.PSObject.Properties['setup']?.Value
    if ($null -ne $setup) {
        $seed = $setup.PSObject.Properties['seed']?.Value
        if ($setup -isnot [pscustomobject]) {
            $errs.Add('setup must be an object')
        } elseif ($null -ne $seed -and ($seed -isnot [pscustomobject] -or @($seed.PSObject.Properties | Where-Object { $_.Value -isnot [string] -or -not $_.Value }).Count)) {
            $errs.Add('setup.seed must map destination paths to files under Tools/')
        }
    }
    # installs: a package manager's install recipe; install.prefer: this tool's preferred sources.
    $insRaw = $Tool.PSObject.Properties['installs']?.Value   # read directly: a helper would unroll [ ... ]
    if ($null -ne $insRaw) {
        $isList = $insRaw -is [array]
        $blocks = @($insRaw)
        for ($n = 0; $n -lt $blocks.Count; $n++) {
            $ins = $blocks[$n]
            $at = if ($isList) { "installs[$n]" } else { 'installs' }
            if ($ins -isnot [pscustomobject]) { $errs.Add("$at must be an object"); continue }
            if (-not ((PSProp $ins 'from') -is [string] -and (PSProp $ins 'from'))) { $errs.Add("$at.from must name the source this manager installs from") }
            $cmd = $ins.PSObject.Properties['command']?.Value   # read directly: a helper would unroll ["x"]
            $hasCmd = $null -ne $cmd
            $hasFn = $null -ne (PSProp $ins 'function')
            if ($hasCmd -eq $hasFn) { $errs.Add("$at needs exactly one of command or function") }
            if ($hasCmd -and $cmd -isnot [array]) { $errs.Add("$at.command must be an array (argv)") }
        }
    }
    $inst = PSProp $Tool 'install'
    if ($null -ne $inst) {
        $have = @((PSProp $Tool 'packages')?.PSObject.Properties.Name)
        $bad = @(@($inst.PSObject.Properties['prefer']?.Value) | Where-Object { $_ -and $_ -notin $have })
        if ($bad) { $errs.Add("install.prefer names sources the tool has no package for: $($bad -join ', ')") }
    }
    $requires = $Tool.PSObject.Properties['requires']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $requires -and ($requires -isnot [array] -or @($requires | Where-Object { $_ -isnot [string] -or $_ -notmatch '^(role:)?[A-Za-z0-9][A-Za-z0-9._-]*$' }).Count)) {
        $errs.Add('requires must be an array of tool names or role:<role> entries')
    }
    $prewarm = PSProp $Tool 'prewarm'
    if ($null -ne $prewarm -and $prewarm -isnot [bool]) { $errs.Add('prewarm must be a boolean (true/false, not a string)') }

    # picker: null, "custom" (the companion defines its own), or a declarative object.
    $picker = PSProp $Tool 'picker'
    if ($picker -is [string] -and $picker -ne 'custom') {
        $errs.Add("picker must be null, ""custom"" or an object (got ""$picker"")")
    } elseif ($null -ne $picker -and $picker -isnot [string]) {
        if ($picker -isnot [pscustomobject]) {
            $errs.Add('picker must be null, "custom" or an object')
        } else {
            foreach ($req in 'function', 'list') {
                $v = PSProp $picker $req
                if ($v -isnot [string] -or -not $v) { $errs.Add("picker.$req is required (a string)") }
            }
            foreach ($b in 'ansi', 'list_accepts_path') {
                $v = PSProp $picker $b
                if ($null -ne $v -and $v -isnot [bool]) { $errs.Add("picker.$b must be a boolean (true/false, not a string)") }
            }
            # These become scriptblocks when the picker is built; catch a syntax error
            # here, at load, instead of when the profile runs.
            $action = PSProp $picker 'action'
            if ($action -is [string] -and $action -and $action -ne 'output') {
                try { $null = [scriptblock]::Create('param($v) ' + $action.Replace('{}', '$v')) }
                catch { $errs.Add("picker.action is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)") }
            }
            $parse = PSProp $picker 'parse'
            if ($parse -is [string] -and $parse) {
                try { $null = [scriptblock]::Create($parse) }
                catch { $errs.Add("picker.parse is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)") }
            }
        }
    }

    # Typo warnings. Unknown fields are allowed (tool authors may carry extra
    # data), so only a name that looks like a misspelling of a known one warns.
    $known = @{
        ''     = 'name', 'executable', 'type', 'description', 'tags', 'packages', 'xdg', 'env', 'aliases',
                 'picker', 'after', 'roles', 'themeMap', 'settings', 'executableExclude',
                 'prewarm', 'role', 'requires', 'setup', 'installs', 'install'
        picker = 'function', 'alias', 'list', 'list_accepts_path', 'preview', 'preview_window', 'ansi',
                 'header', 'action', 'parse'
        xdg    = 'method', 'vars', 'dirs', 'instructions', 'compliance'
        setup  = 'seed'
        installs = 'from', 'command', 'function', 'args', 'batch', 'elevate', 'reactivate', 'feeds'
        install = 'prefer'
        role   = 'priority', 'optIn', 'aliases', 'env'
    }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add(@('', $Tool, ''))
    if ($picker -is [pscustomobject]) { $sections.Add(@('picker', $picker, 'picker.')) }
    $xdg = PSProp $Tool 'xdg'
    if ($xdg -is [pscustomobject]) { $sections.Add(@('xdg', $xdg, 'xdg.')) }
    $setupObj = PSProp $Tool 'setup'
    if ($setupObj -is [pscustomobject]) { $sections.Add(@('setup', $setupObj, 'setup.')) }
    foreach ($o in @($Tool.PSObject.Properties['installs']?.Value)) {
        if ($o -is [pscustomobject]) { $sections.Add(@('installs', $o, 'installs.')) }
    }
    $o = PSProp $Tool 'install'
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
            if ($suggestion) { $warns.Add("unknown field '$($s[2])$($p.Name)' — did you mean '$($s[2])$suggestion'?") }
        }
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    if ($Warnings) { $Warnings.Value = $warns.ToArray() }
    return $errs.Count -eq 0
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

# ---- Shared/Write-DFFileAtomic.ps1
#Requires -Version 7.0

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

# ---- Private/DFInstallHost.ps1
#Requires -Version 7.0

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

# ---- Private/DFSessionConfig.ps1
#Requires -Version 7.0

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
    InstallVia          = 'Tool -> source to install it from (beats everything, including ExcludeSources)'
    InstallOrder        = 'Preferred source order for Install-DFTool (ordering only)'
    ExcludeSources      = 'Sources Install-DFTool never uses (unless InstallVia names one)'
    BatTheme           = 'bat theme'
    DeltaTheme         = 'delta theme'
    FzfTheme           = 'fzf theme'
    GlowTheme          = 'glow theme'
    MdcatTheme         = 'mdcat theme'
    MdvTheme           = 'mdv theme'
    MoorTheme          = 'moor theme'
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

# ---- Private/Expand-DFXdgPath.ps1
#Requires -Version 7.0

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

# ---- Private/Get-DFCachedCommandOutput.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
        Looks, in order, for -Name as an existing absolute file path; then
        <XDG config>\<Tool>\themes\<Name>.json; then <BundledDir>\<Name>.json.
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
        return (Test-Path $Name -PathType Leaf) ? $Name : $null
    }
    foreach ($candidate in (Join-Path (Get-DFXdgPath Config) $Tool 'themes' "$Name.json"), (Join-Path $BundledDir "$Name.json")) {
        if (Test-Path $candidate -PathType Leaf) { return $candidate }
    }
    $null
}

# ---- Private/Get-DFCoreutilsShadowSet.ps1
#Requires -Version 7.0

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

# ---- Private/Get-DFGroupDb.ps1
#Requires -Version 7.0

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

# ---- Private/Get-DFRoleDb.ps1
#Requires -Version 7.0

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
        reserved names or emptyMembership. Invalid entries warn and return nothing.
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
    $record = [pscustomobject]@{
        name            = $Name
        kind            = $props['kind']?.Value
        exclusive       = [bool]$props['exclusive']?.Value
        hook            = $props['hook']?.Value
        emptyMembership = [bool]$props['emptyMembership']?.Value
        reserved        = [pscustomobject]@{
            env     = [string[]]@(if ($null -ne $resProps) { $resProps['env']?.Value })
            aliases = [string[]]@(if ($null -ne $resProps) { $resProps['aliases']?.Value })
            code    = [string[]]@(if ($null -ne $resProps) { $resProps['code']?.Value })
        }
        requires        = [string]$props['requires']?.Value
        description     = [string]$props['description']?.Value
    }

    $problem = switch ($record.kind) {
        'single' {
            # The hook name is derived from the role name (project-env -> ProjectEnv),
            # so no two roles can share one and a sidecar's function serves one role.
            $pascal = -join ($Name -split '-' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
            $expected = "Initialize-DFRole$pascal"
            if ($record.hook -cne $expected) { "hook '$($record.hook)' must be $expected" }
        }
        'category' {
            if ($record.hook -or $record.emptyMembership -or $record.exclusive -or
                $record.reserved.env.Count -or $record.reserved.aliases.Count -or $record.reserved.code.Count) {
                'a category role cannot declare a hook, exclusive, emptyMembership or reserved names'
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

# ---- Private/Get-DFToolSetupState.ps1
#Requires -Version 7.0

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

# ---- Private/Invoke-DFInstallCommand.ps1
#Requires -Version 7.0

function Expand-DFInstallArgv {
    <#
    .SYNOPSIS
        Fills a manager's argv template: {id} becomes every id, other {name} tokens come from -Values.
    .PARAMETER Template
        The argv template from installs.command or installs.feeds. A token
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

function Invoke-DFInstallCommand {
    <#
    .SYNOPSIS
        Runs one package-manager command and returns its exit code and output. The only place DotForge runs a manager.
    .DESCRIPTION
        An argv runs as a native command; a function (installs.function, e.g.
        Install-PSResource) is called with -Arguments splatted. -Elevate runs
        the argv through -ElevateWith (the elevator role's executable, e.g.
        gsudo). Tests mock this function.
    .PARAMETER Manager
        The manager's tool record (for messages).
    .PARAMETER Argv
        The command line, already expanded.
    .PARAMETER Function
        A PowerShell command to call instead of an argv.
    .PARAMETER Arguments
        Parameters for -Function.
    .PARAMETER Elevate
        Run through -ElevateWith.
    .PARAMETER ElevateWith
        The elevator's executable.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [string[]]$Argv = @(),
        [string]$Function,
        [hashtable]$Arguments = @{},
        [switch]$Elevate,
        [string]$ElevateWith
    )
    if ($Function) {
        try {
            $out = & $Function @Arguments -ErrorAction Stop 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = 0; Output = $out }
        } catch {
            return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
        }
    }
    $exe, $rest = if ($Elevate) { $ElevateWith, $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
    # A manager can resolve to a .ps1 shim (scoop.ps1) that runs in-process and
    # never sets an exit code: don't read a stale one from an earlier command.
    $global:LASTEXITCODE = 0
    $out = & $exe @rest 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# ---- Private/Invoke-DFInstallPlan.ps1
#Requires -Version 7.0

function Invoke-DFInstallPlan {
    <#
    .SYNOPSIS
        Runs an install plan stage by stage and reports each tool's result.
    .DESCRIPTION
        For each stage, each manager batch:
          - its feeds are added if missing (listed first, added once);
          - the batch runs as one command when the manager supports batch,
            else one command per tool;
          - a batch the plan marked Elevate runs through its ElevateWith
            executable (the elevator role, e.g. gsudo);
          - when a batch fails, each of its tools is re-checked: one bad id
            doesn't fail the tools that did install.
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
            $elevate = [bool]$batch.Elevate
            if ($elevate -and -not $batch.ElevateWith) {
                foreach ($it in $ready) { & $set $it.Tool 'Skipped' "$($m.name) needs an elevated shell: rerun as administrator, or install an elevator such as gsudo" }
                continue
            }
            # Feeds first, each once, and only those the manager doesn't list yet.
            if ($blk.feeds) {
                $feeds = @($ready | Where-Object { $_.Ref.Feed } | ForEach-Object { $_.Ref.Feed } | Sort-Object name -Unique)
                if ($feeds) {
                    $listed = (Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.list -Values @{})).Output
                    $names = @($listed -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
                    foreach ($f in $feeds | Where-Object { $_.name -notin $names }) {
                        $r = Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.add -Values @{ name = $f.name; url = $f.url })
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
            # (A List, not `if { ,$ready }`: statement output would unroll the wrapper.)
            $groups = [System.Collections.Generic.List[object]]::new()
            if ($blk.batch) { $groups.Add($ready) } else { foreach ($it in $ready) { $groups.Add(@($it)) } }
            foreach ($group in $groups) {
                $ids = [string[]]@($group | ForEach-Object { & $idOf $_ })
                $r = if ($blk.function) {
                    $fnArgs = @{}
                    foreach ($p in $blk.args.PSObject.Properties) { $fnArgs[$p.Name] = if ($p.Value -eq '{id}') { $ids } else { $p.Value } }
                    Invoke-DFInstallCommand -Manager $m -Function $blk.function -Arguments $fnArgs
                } else {
                    Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.command -Values @{ ids = $ids }) -Elevate:$elevate -ElevateWith $batch.ElevateWith
                }
                foreach ($it in $group) {
                    $t = $ToolDb[$it.Tool]
                    # A failed batch may still have installed some of its tools.
                    $ok = $r.ExitCode -eq 0 -or ($group.Count -gt 1 -and (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force))
                    if ($ok) { & $set $it.Tool 'Installed' "via $($m.name)" }
                    else {
                        $tail = @("$($r.Output)".Trim() -split "`r?`n" | Select-Object -Last 3) -join ' / '
                        & $set $it.Tool 'Failed' "$($m.name) failed: $tail"
                    }
                }
                if ($r.ExitCode -eq 0 -and $blk.reactivate -and -not $reactivate.Contains($m.name)) { $reactivate.Add($m.name) }
            }
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

# ---- Private/Invoke-DFPackageManagerPicker.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
            $blocker = Get-DFActivationBlocker -Tool $tool -Requirements $requirements @pathArgs
            if ($blocker) {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Missing -RequestedBy $requestedBy[$tool.name] -Detail $blocker
                continue
            }
            # One tool's failure (a throwing companion, or any error under a
            # profile's $ErrorActionPreference = 'Stop') must not stop the rest.
            try {
                Invoke-DFToolRegistration -Tool $tool -Context $context
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name]
            } catch {
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Failed -RequestedBy $requestedBy[$tool.name] -Detail $_.Exception.Message
            }
        }
    } finally {
        if ($prewarmJob) { $prewarmJob | Remove-Job -Force -ErrorAction Ignore }
    }

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
        foreach ($afterEntry in @($record.after | Where-Object { $_ -like 'role:*' })) {
            $role = $afterEntry.Substring(5)
            foreach ($member in @($ToolDb.Values | Where-Object { $_.name -ne $record.name -and $_.roles.PSObject.Properties[$role] })) {
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
            (Test-DFToolAvailable -Executable $tool.executable -Type 'module')) { $tool.executable }
    })
    if ($prewarmModules) { Start-DFModulePrewarm -ModuleNames $prewarmModules }
}

function Get-DFActivationBlocker {
    <#
    .SYNOPSIS
        Says why a tool can't be activated now, or returns an empty string when nothing blocks it.
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
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
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
        if ($req -and $req -notlike 'role:*' -and $status.Contains($req) -and -not (Test-DFToolActive $req)) { $req }
    })
    if ($unmet) { return "requires $($unmet -join ', '), which is not available" }
    if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return '' }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $detail = "'$($Tool.executable)' is not installed"
    if ($Requirements.RoleHint.ContainsKey($Tool.name)) {
        $detail += "; $(Get-DFRoleRequirementHint -Role $Requirements.RoleHint[$Tool.name] @pathArgs)"
    }
    $detail
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
            $preferred.Detail = "$($preferred.Detail); using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"
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
            if (-not $req) { continue }
            if ($req -like 'role:*') {
                $role = $req.Substring(5)
                $members = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties[$role] })
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
        $names = @($all.Values | Where-Object { $_.roles.PSObject.Properties[$r] } | ForEach-Object name | Sort-Object)
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
            $st.Detail = "$($st.Detail); Install-DFTool -Missing will install it $how"
        }
        foreach ($g in $plan.Gaps) {
            $st = $script:DFSessionStatus[$g.Tool]
            if ($st -and $st -in $todo) { $st.Detail = "$($st.Detail); can't install yet: $($g.Reason)" }
        }
    } catch {
        Write-Verbose "DotForge: couldn't work out how missing tools would install: $($_.Exception.Message)"
    }
}

# ---- Private/Invoke-DFToolCompanion.ps1
#Requires -Version 7.0

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
        The resolved Tools/ directory to look for companions in.
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

        [switch]$SetupOnly
    )

    # The companion body and its hooks are dot-sourced into this scope, so they
    # can overwrite any local here ($Tool, $companion, ...). Everything this
    # function needs afterwards is captured first under one unlikely name.
    $__dfCall = @{
        Tool      = $Tool
        Name      = $Tool.name
        Companion = Join-Path $ToolsPath "$($Tool.name).ps1"
        Setup     = Join-Path $ToolsPath "$($Tool.name).setup.ps1"
        SkipSetup = @($SkipSetup)
        WonRoles  = @($WonRoles)
        SetupOnly = [bool]$SetupOnly
    }
    $__dfCall.HasCompanion = Test-Path $__dfCall.Companion -PathType Leaf

    # The one-time setup step runs first, so the companion can rely on what it
    # created: setup.seed files, then Tools/<name>.setup.ps1, which records its
    # own completion. With no script, the seeds are recorded here.
    $__dfCall.HasSetupScript = Test-Path $__dfCall.Setup -PathType Leaf
    $__dfCall.HasSeed = [bool]$__dfCall.Tool.PSObject.Properties['setup']?.Value?.seed
    if (($__dfCall.HasSetupScript -or $__dfCall.HasSeed) -and
        $__dfCall.Name -notin $__dfCall.SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$__dfCall.Name]) {
        try {
            $__dfCall.Seeded = @(Invoke-DFToolSeed -Tool $__dfCall.Tool -ToolsPath $ToolsPath)
            if ($__dfCall.HasSetupScript) {
                $DFCurrentTool = $__dfCall.Tool
                . ($__dfCall.Setup)
            } else {
                Complete-DFToolSetup -Name $__dfCall.Name -Actions $__dfCall.Seeded
            }
        } catch {
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

# ---- Private/Invoke-DFTopoSort.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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

    # A manager that needs admin rights runs only in an elevated shell or
    # through an elevator (the elevator role, e.g. gsudo) that is installed or
    # installed earlier in this run.
    $elevated = Test-DFElevated
    $elevators = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties['elevator'] } | Sort-Object name)
    $elevatorNow = $elevators | Where-Object { & $IsAvailable $_ } | Select-Object -First 1
    $elevatorPlanned = if (-not $elevatorNow) { $elevators | Where-Object { $want.Contains($_.name) } | Select-Object -First 1 }
    $elevator = if ($elevatorNow) { $elevatorNow } else { $elevatorPlanned }
    $canElevate = $elevated -or [bool]$elevator

    $items = [ordered]@{}
    $gaps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $want.Count; $i++) {
        $t = $ToolDb[$want[$i]]
        if (-not $t) { continue }
        $required = @($t.requires | Where-Object { $_ -and $_ -notlike 'role:*' -and $want.Contains($_) })
        # (@($null?.X) is a one-element array, so test the object first.)
        $hasPackages = $t.packages -and @($t.packages.PSObject.Properties).Count -gt 0
        if (-not $hasPackages -and $required) {
            $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $null; Manager = $null; Ref = $null; ProvidedBy = $required[0]; DependsOn = [string[]]$required; Stage = 0 }
            continue
        }
        # No packages, and what it comes with isn't being installed: say what to add.
        $providers = @($t.requires | Where-Object { $_ -and $_ -notlike 'role:*' })
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
        $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $r.Source; Manager = $r.Manager; Block = $r.Block; Ref = $r.Ref; ProvidedBy = $null; DependsOn = [string[]]$deps; Stage = 0 }
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
            $elev = [bool]$blk.elevate -and -not $elevated
            [pscustomobject]@{
                Manager = $m; Source = $b.Group[0].Source; Block = $blk; Items = @($b.Group)
                Elevate = $elev; ElevateWith = $(if ($elev -and $elevator) { $elevator.executable })
            }
        })
        [pscustomobject]@{ Number = [int]$g.Name; Batches = $batches; Provided = @($g.Group | Where-Object ProvidedBy) }
    })
    [pscustomobject]@{ Items = @($items.Values); Stages = $stages; Gaps = @($gaps) }
}

# ---- Private/New-DFToolPickerFunction.ps1
#Requires -Version 7.0

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs one tool's declarative fzf picker as a global
        function (and alias, if declared).
    .DESCRIPTION
        Reads $Tool.picker (a normalized record from ConvertTo-DFToolRecord)
        and defines a global function that calls Invoke-DFPicker with it.
        When picker.list_accepts_path is true, the function takes a -Path
        parameter (default '.') appended to the list command, which is split on
        whitespace (so quoted arguments in the list command are not supported;
        see TODO.md). No-ops when $Tool has no object picker, or the picker
        lacks a function/list pair.
    .PARAMETER Tool
        The normalized tool record declaring the picker.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $picker = $Tool.picker
    if ($picker -isnot [PSCustomObject] -or -not ($picker.function -and $picker.list)) { return }

    # Everything except the list source is the same for both shapes, so the
    # Invoke-DFPicker call is built once. GetNewClosure captures these locals.
    $action = if ($picker.action -and $picker.action -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $picker.action.Replace('{}', '$v'))
    }
    $parse = if ($picker.parse) { [scriptblock]::Create($picker.parse) }
    $show = {
        param([scriptblock]$List)
        Invoke-DFPicker -List $List -Preview $picker.preview -PreviewWindow $picker.preview_window `
            -Ansi:$picker.ansi -Header $picker.header -Parse $parse -Action $action
    }.GetNewClosure()

    $fn = if ($picker.list_accepts_path) {
        $listParts = @($picker.list -split '\s+')
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            & $show { & $listParts[0] @($listParts[1..($listParts.Count - 1)]) $Path }.GetNewClosure()
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

# ---- Private/Register-DFToolAliases.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

# The per-session steps Invoke-DFSessionActivation runs: resolve role winners,
# register each tool, and report coreutils conflicts.

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

    foreach ($roleName in @($defaults.Keys)) {
        if (-not $RoleDb.ContainsKey($roleName)) {
            Write-Warning "DotForge: Defaults['$roleName'] names an unknown role — ignoring. See Get-DFRole for the list."
        } elseif ($RoleDb[$roleName].kind -eq 'category') {
            Write-Warning "DotForge: Defaults['$roleName']: '$roleName' is a category, which has no winner — every member is configured. Ignoring."
        }
    }

    # One pass over the registration set builds role -> candidates; this runs
    # at every startup, so it avoids a pipeline per role. Topo-sorting an
    # empty set can hand back a lone $null, hence the null check.
    $candidatesByRole = @{}
    foreach ($t in $Tools) {
        if (-not $t) { continue }
        $available = $null
        foreach ($rp in $t.roles.PSObject.Properties) {
            $rn = $rp.Name
            if (-not $RoleDb.ContainsKey($rn)) {
                # Stay quiet when no definitions loaded at all (Get-DFRoleDb already
                # warned), and for a legacy v1 role string, which was free-form.
                if ($RoleDb.Count -and -not $rp.Value.legacy) { Write-Warning "DotForge: $($t.name) declares unknown role '$rn' — ignored." }
                continue
            }
            if ($RoleDb[$rn].kind -ne 'single') { continue }
            # optIn is generic role metadata: an optional member joins the
            # candidate set only when the user selected it for this role.
            if ($rp.Value.optIn -and $defaults[$rn] -ine $t.name) { continue }
            if ($null -eq $available) { $available = Test-DFToolAvailable -Executable $t.executable -Type $t.type }
            if (-not $available) { continue }
            if (-not $candidatesByRole.ContainsKey($rn)) { $candidatesByRole[$rn] = [System.Collections.Generic.List[object]]::new() }
            $candidatesByRole[$rn].Add($t)
        }
    }

    foreach ($roleName in @($RoleDb.Keys)) {
        if ($RoleDb[$roleName].kind -ne 'single') { continue }
        $candidates = if ($candidatesByRole.ContainsKey($roleName)) { $candidatesByRole[$roleName] } else { @() }

        $winner = $null
        $reason = $null
        $chosen = $defaults[$roleName]
        if (-not [string]::IsNullOrWhiteSpace($chosen)) {
            $chosenTool = $ToolDb[$chosen]
            if (-not $chosenTool) {
                # A role is only ever filled by a tool the user asked for.
                Write-Warning "DotForge: Defaults['$roleName'] names '$chosen', which is not requested in Tools — using priority. Add '$chosen' to Tools to use it."
            } elseif (-not $chosenTool.roles.PSObject.Properties[$roleName]) {
                $members = @(foreach ($t in $ToolDb.Values) { if ($t.roles.PSObject.Properties[$roleName]) { $t.name } }) | Sort-Object
                Write-Warning "DotForge: Defaults['$roleName'] names '$chosen', which is not a $roleName tool (requested ones: $($members -join ', ')) — using priority."
            } else {
                # Report the tool's own spelling, not the user's (names compare case-insensitively).
                foreach ($c in $candidates) { if ($c.name -eq $chosen) { $winner = $c.name; $reason = 'Defaults'; break } }
            }
        }
        if ($candidates.Count -eq 0) { continue }
        # Rank by priority (highest first), ties by name. An insertion sort over
        # the usual one to three candidates; no pipeline, since this runs at startup.
        $ranked = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $candidates) {
            $i = 0
            while ($i -lt $ranked.Count) {
                $o = $ranked[$i]
                $cp = $c.roles.$roleName.priority
                $op = $o.roles.$roleName.priority
                if ($cp -gt $op -or ($cp -eq $op -and [string]::Compare($c.name, $o.name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { break }
                $i++
            }
            $ranked.Insert($i, $c)
        }
        # The user's preferred member, when it is requested and really in the role.
        $preferred = if (-not [string]::IsNullOrWhiteSpace($chosen) -and $ToolDb[$chosen] -and
            $ToolDb[$chosen].roles.PSObject.Properties[$roleName]) { $ToolDb[$chosen].name }
        if (-not $winner) {
            $winner = $ranked[0].name
            # The preferred tool is requested but unavailable: another requested
            # tool stands in, and the end-of-load notice says so.
            $reason = if ($preferred) { 'fallback' } elseif ($candidates.Count -eq 1) { 'sole' } else { 'priority' }
        }
        $names = [string[]]@(foreach ($c in $candidates) { $c.name })
        [array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        $winners[$roleName] = [pscustomobject]@{
            Role       = $roleName
            Winner     = $winner
            Reason     = $reason
            Candidates = $names
            Ranked     = [string[]]@(foreach ($c in $ranked) { $c.name })
            Preferred  = $preferred
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
        Applies one installed tool's configuration: XDG, environment, aliases, picker, won roles, companion.
    .DESCRIPTION
        The per-tool body of Register-DFTool. For each role the tool won, its role
        block's env (through Set-DFRoleEnv) and aliases are applied before the
        companion runs, and its role hook is called right after it (by
        Invoke-DFToolCompanion). Roles it lost are skipped entirely. Anything a
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
    Set-DFToolXdgConfig -Tool $Tool

    # Non-XDG settings apply regardless of xdg.method. Expand-DFXdgPath expands
    # ${XDG_*} and passes flag strings through byte-for-byte.
    if ($Tool.env) {
        foreach ($var in $Tool.env.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($var.Name, (Expand-DFXdgPath $var.Value), 'Process')
        }
    }

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

    # Enumerate properties rather than .Name: on a tool with no roles,
    # member enumeration would yield a single $null.
    $roleNames = @(foreach ($rp in $Tool.roles.PSObject.Properties) { $rp.Name }) | Sort-Object
    $wonRoles = foreach ($roleName in $roleNames) {
        $won = $RoleWinners[$roleName]
        if (-not $won -or $won.Winner -ne $Tool.name) { continue }
        $block = $Tool.roles.$roleName
        if ($block.env) {
            foreach ($var in $block.env.PSObject.Properties) {
                # ${DF_TOOL_EXE}: the winner's own executable path (see Resolve-DFToolExecutable).
                $value = [string]$var.Value
                if ($value.Contains('${DF_TOOL_EXE}')) { $value = $value.Replace('${DF_TOOL_EXE}', (ConvertTo-DFToolExePathToken -Tool $Tool)) }
                Set-DFRoleEnv -Name $var.Name -Value (Expand-DFXdgPath $value) -Role $roleName -Winner $won.Winner -Reason $won.Reason
            }
        }
        if ($block.aliases) { Register-DFToolAliases -Tool $Tool -Aliases $block.aliases }
        [pscustomobject]@{
            Role         = $roleName
            Hook         = $RoleDb[$roleName].hook
            # An empty {} block is still an object, so count what it holds.
            HookRequired = -not ((Test-DFHasEntries $block.env) -or (Test-DFHasEntries $block.aliases) -or
                $block.legacy -or $RoleDb[$roleName].emptyMembership)
        }
    }

    Invoke-DFToolCompanion -Tool $Tool -ToolsPath $Context.ToolsPath -SkipSetup @($Context.SkipSetup) -WonRoles @($wonRoles)
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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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

# ---- Private/Set-DFRoleEnv.ps1
#Requires -Version 7.0

function Get-DFRoleEnvState {
    <#
    .SYNOPSIS
        Returns this session's record of role variables DotForge wrote and conflicts it warned about.
    .DESCRIPTION
        Kept in a session global, not a $script: variable, so Import-Module
        DotForge -Force doesn't forget which values DotForge itself wrote.
        Written maps variable -> the value DotForge last wrote: a current value
        that differs was set outside DotForge (profile, parent shell, system
        environment). Warned holds the conflicts already reported this session.
    .OUTPUTS
        System.Collections.Hashtable. @{ Written = @{}; Warned = @{} }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($global:DFRoleEnvState -isnot [hashtable]) {
        $global:DFRoleEnvState = @{ Written = @{}; Warned = @{} }
    }
    $global:DFRoleEnvState
}

function Set-DFRoleEnv {
    <#
    .SYNOPSIS
        Sets a role's reserved environment variable for the role's winner, without overriding the user's own choice.
    .DESCRIPTION
        Precedence, highest first: an explicit $DFConfig.Defaults choice
        (-Reason Defaults); then a value set outside DotForge; then an
        auto-picked winner (-Reason priority or sole). When a Defaults choice
        replaces a different outside value, warns with both settings, once per
        session for each conflict: the user's config contradicts itself. A
        value equal to -Value is left as is. Called only by core, from a role
        block's declarative env. What DotForge wrote is kept in
        Get-DFRoleEnvState.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        The winner's value (already expanded).
    .PARAMETER Role
        The role name, for the warning.
    .PARAMETER Winner
        The winning tool, for the warning.
    .PARAMETER Reason
        How the winner was chosen: Defaults, priority or sole.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Winner,
        [Parameter(Mandatory)][ValidateSet('Defaults', 'priority', 'sole')][string]$Reason
    )
    $state = Get-DFRoleEnvState
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $state.Written[$Name] = $Value
        return
    }
    $setOutside = $current -and $state.Written[$Name] -cne $current
    if ($setOutside) {
        if ($Reason -ne 'Defaults') {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Role winner $Winner."
            return
        }
        # Once per session: `. $PROFILE` re-runs the profile's own assignment,
        # and the same contradiction needs reporting only once.
        $conflict = "$Name|$current|$Winner"
        if (-not $state.Warned.ContainsKey($conflict)) {
            $state.Warned[$conflict] = $true
            Write-Warning ("DotForge: $Name was '$current' but `$DFConfig.Defaults.$Role is '$Winner'; using $Winner.`n" +
                '  Remove one of the two settings to silence this.')
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $state.Written[$Name] = $Value
}

# ---- Private/Set-DFToolXdgConfig.ps1
#Requires -Version 7.0

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars that aren't already set and creates xdg.dirs;
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
            $vars = $xdg.vars
            if ($vars) {
                # A tool's vars are defaults: a variable the user already set (in
                # their profile, or system-wide) is never overwritten.
                $vars.PSObject.Properties | ForEach-Object {
                    $current = [System.Environment]::GetEnvironmentVariable($_.Name, 'Process')
                    if ($current) {
                        Write-Verbose "DotForge: $($Tool.name) keeps $($_.Name) as already set ($current)"
                        return
                    }
                    [System.Environment]::SetEnvironmentVariable(
                        $_.Name,
                        (Expand-DFXdgPath $_.Value),
                        'Process'
                    )
                }
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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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

# ---- Private/Write-DFInstallPlan.ps1
#Requires -Version 7.0

function Write-DFInstallPlan {
    <#
    .SYNOPSIS
        Prints an install plan: stages, manager batches, feeds to add, elevation, and gaps.
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
            $elev = if ($b.Elevate) { " (needs admin: 1 UAC prompt via $([IO.Path]::GetFileNameWithoutExtension($b.ElevateWith)))" } else { '' }
            "$($b.Manager.name)$elev`: $((@($feeds) + @($b.Items | ForEach-Object { "$($_.Tool) ($($_.Ref.Id))" })) -join ' · ')"
        })
        $parts += @($s.Provided | ForEach-Object { "$($_.Tool) (comes with $($_.ProvidedBy))" })
        Write-Host ("  stage {0}  {1}" -f $s.Number, ($parts -join "`n           "))
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

# ---- Private/Write-DFRoleNotice.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
        forever, until the state file is deleted or the entry is removed. See
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
        actions = @($Actions)
    }
    $state | Add-Member -MemberType NoteProperty -Name $Name -Value $entry -Force

    $stateFile = Get-DFToolSetupStatePath
    Write-DFFileAtomic -Path $stateFile -Value ($state | ConvertTo-Json -Depth 10)
}

# ---- Public/DFAliases.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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

    # A session passes its active tools; run on its own, every known tool is checked.
    $checked = if ($PSBoundParameters.ContainsKey('Tools')) { @($Tools) } else {
        $dbParams = @{}
        if ($ToolsPath) { $dbParams['ToolsPath'] = $ToolsPath }
        @((Import-DFToolDb @dbParams -ErrorAction Ignore).Values)
    }
    foreach ($tool in $checked) {
        if (-not $tool) { continue }
        if ($tool.aliases) {
            $owned.AddRange([string[]]@($tool.aliases.PSObject.Properties.Name))
        }
        # A role's aliases (ls, ll, ...) are defined only by the role's winner,
        # but any member may win, so all of them can be shadowed.
        foreach ($role in $tool.roles.PSObject.Properties) {
            if ($role.Value.aliases) {
                $owned.AddRange([string[]]@($role.Value.aliases.PSObject.Properties.Name))
            }
        }
        if ($tool.picker -is [PSCustomObject] -and $tool.picker.alias) {
            $owned.Add([string]$tool.picker.alias)
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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
        DotForge.Role. Name, Kind, Exclusive, Description, Members, Candidates, Winner, Reason, Overridden.
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
        $members = @($db.Values | Where-Object { $_.roles.PSObject.Properties[$role.name] } | ForEach-Object name | Sort-Object)
        $w = $winners[$role.name]
        $overridden = @(if ($w) {
            $block = $db[$w.Winner].roles.($role.name)
            if ($block.env) {
                foreach ($var in $block.env.PSObject.Properties) {
                    $current = [Environment]::GetEnvironmentVariable($var.Name, 'Process')
                    if ($current -and $current -cne (Expand-DFXdgPath $var.Value)) {
                        $source = if ((Get-DFRoleEnvState).Written[$var.Name] -ceq $current) { 'DotForge (earlier winner)' } else { 'outside DotForge' }
                        [pscustomobject]@{ Name = $var.Name; Value = $current; Source = $source }
                    }
                }
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
            Overridden  = $overridden
        }
    }
}

# ---- Public/Get-DFTool.ps1
#Requires -Version 7.0

function Get-DFTool {
    <#
    .SYNOPSIS
        Queries the DotForge tool registry.
    .DESCRIPTION
        Returns tool records from the JSON tool database (one per Tools/*.json
        file), whether or not the tool is installed. With no parameters, returns
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
#Requires -Version 7.0

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
#Requires -Version 7.0

function Get-DFToolStatus {
    <#
    .SYNOPSIS
        Shows what this session's Start-DFSession decided for each requested tool.
    .DESCRIPTION
        One object per requested (or excluded) tool:
            Name         the tool
            State        Active, Missing (not installed), Failed (setup or
                         activation threw), or Excluded (by ExcludeTools)
            RequestedBy  Tools, the +group that requested it, or Register-DFTool
            Roles        roles it won this session, e.g. prompt
            Detail       why it is Missing or Failed, or the tool standing in for it
        It reports what already happened, so it is instant. Pipe -Missing
        into Install-DFTool to install those tools.
    .PARAMETER Name
        Only these tools.
    .PARAMETER Missing
        Only tools that aren't installed.
    .PARAMETER Failed
        Only tools that failed to load.
    .EXAMPLE
        Get-DFToolStatus

        Lists every requested tool and what happened to it.
    .EXAMPLE
        Get-DFToolStatus -Missing

        Lists the requested tools that aren't installed; Install-DFTool -Missing installs them.
    .OUTPUTS
        DotForge.ToolStatus objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [switch]$Missing,
        [switch]$Failed
    )
    if (-not $script:DFSessionStatus) {
        Write-Warning 'DotForge: no session yet. Start-DFSession -Config @{ Tools = @(...) } configures the tools you request.'
        return
    }
    Add-DFInstallHint
    foreach ($s in $script:DFSessionStatus.Values) {
        if ($Name -and $s.Name -notin $Name) { continue }
        if ($Missing -and $s.State -ne 'Missing') { continue }
        if ($Failed -and $s.State -ne 'Failed') { continue }
        $s
    }
}

# ---- Public/Install-DFTool.ps1
#Requires -Version 7.0

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
#Requires -Version 7.0

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
#Requires -Version 7.0

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
    Clear-DFToolSetupState -Name $Name
    Invoke-DFToolCompanion -Tool $tool -ToolsPath $toolsDir -SetupOnly
}

# ---- Public/New-DFDirectory.ps1
#Requires -Version 7.0

function New-DFDirectory {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent and silent.
    .DESCRIPTION
        Wraps New-Item -ItemType Directory -Force, creating any missing parent
        directories. Succeeds silently if the directory already exists, and stays
        silent on failure too (errors are suppressed), so check with Test-Path
        when creation must succeed. An absolute path is canonicalized with
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
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---- Public/New-DFShim.ps1
#Requires -Version 7.0

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
        Where-Object { (ConvertTo-DFPath $_) -eq $shimsDir }
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
#Requires -Version 7.0

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
    $active = @(Invoke-DFSessionActivation -Request $request.ToArray() -Reactivate $reapply @pathArgs)
    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) { Write-DFConflictNotice -Tools $active }
    Write-DFSessionNotice
}

# ---- Public/Start-DFSession.ps1
#Requires -Version 7.0

function Start-DFSession {
    <#
    .SYNOPSIS
        Configures the tools you request for this PowerShell session. Call it once, from your profile.
    .DESCRIPTION
        Start-DFSession is DotForge's profile entry point:
          1. Stores -Config as the session's configuration (unknown keys warn).
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
        The session configuration hashtable. Required.
    .PARAMETER ToolsPath
        Read tool records and companions from this folder instead of the
        module's Tools/. For testing and custom tool sets.
    .EXAMPLE
        Import-Module DotForge
        Start-DFSession -Config @{ Tools = @('+core', 'starship'); ExcludeTools = @('less') }

        Configures every +core tool except less, plus starship.
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
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }

    Set-DFSessionConfig -Config $Config
    Set-DFXdgEnvironment

    $request = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -ExcludeTools @(Get-DFConfig ExcludeTools) `
        -GroupDb (Get-DFGroupDb) -KnownTools @(Get-DFToolNames @pathArgs))

    # A second call only adds; a tool that is no longer requested can't be
    # cleanly undone (aliases, environment, prompt hooks), so say so.
    if ($script:DFSessionStatus) {
        $still = @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)
        $dropped = @($script:DFSessionStatus.Values | Where-Object { $_.State -eq 'Active' -and $_.Name -notin $still } | ForEach-Object Name)
        if ($dropped) {
            Write-Warning "DotForge: $($dropped -join ', ') $(if ($dropped.Count -eq 1) { 'is' } else { 'are' }) no longer requested but stay active until you open a new shell."
        }
    }

    $null = Invoke-DFSessionActivation -Request $request @pathArgs

    if (-not (Get-DFConfig SkipConflictCheck -Default $false)) {
        $activeNames = @($script:DFSessionStatus.Values | Where-Object State -eq 'Active' | ForEach-Object Name)
        $active = if ($activeNames) { @((Import-DFToolDb -Name $activeNames @pathArgs).Values) } else { @() }
        Write-DFConflictNotice -Tools $active
    }
    Write-DFSessionNotice
}
