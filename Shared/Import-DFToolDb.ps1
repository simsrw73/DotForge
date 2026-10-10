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
