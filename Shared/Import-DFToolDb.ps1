#Requires -Version 7.2

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
    $schema = Test-DFToolSchema -Tool $tool
    if (-not $schema.Valid) {
        Write-Warning "DotForge: $leaf schema errors: $($schema.Errors -join '; ')"
        return $null
    }
    foreach ($w in $schema.Warnings) { Write-Warning "DotForge: $leaf`: $w" }
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
    }
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
                legacy   = $false
            }
        }
    }

    # Role v1 declared a single "role" string; read it as a priority-0 membership.
    # legacy marks it so registration keeps v1 behavior: no hook expected, and a
    # loser's top-level aliases that the role reserves are left out.
    $legacyRole = Get-DFToolRecordProperty $Tool 'role' $null
    if ($legacyRole -and -not $roles.Contains($legacyRole)) {
        $roles[$legacyRole] = [pscustomobject]@{ priority = 0; optIn = $false; aliases = $null; env = $null; legacy = $true }
    }

    [pscustomobject]$roles
}

function ConvertTo-DFPickerBlock {
    <#
    .SYNOPSIS
        Normalizes a declarative picker object; null and "custom" pass through.
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

    [pscustomobject]@{ seed = Get-DFToolRecordProperty $RawSetup 'seed' $null }
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
        $command = Get-DFToolRecordProperty $block 'command' $null
        [pscustomobject]@{
            from       = Get-DFToolRecordProperty $block 'from' $null
            command    = $(if ($null -ne $command) { [string[]]@($command) })
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

function ConvertTo-DFInstallBlock {
    <#
    .SYNOPSIS
        Normalizes a tool record's install block (its preferred sources).
    .PARAMETER RawInstall
        See the synopsis.
    #>
    param($RawInstall)

    if (-not $RawInstall) { return $null }

    [pscustomobject]@{ prefer = [string[]]@(Get-DFToolRecordProperty $RawInstall 'prefer' @()) }
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
        settings          = Get-DFToolRecordProperty $Tool 'settings' $null
        executableExclude = [object[]]@(Get-DFToolRecordProperty $Tool 'executableExclude' @())
        prewarm           = [bool](Get-DFToolRecordProperty $Tool 'prewarm' $true)
        setup             = $setup
        installs          = $installs
        install           = $install
    }

    # Keep fields DotForge doesn't model, so tool authors can carry extra data.
    foreach ($property in $Tool.PSObject.Properties) {
        if (-not $record.Contains($property.Name) -and $property.Name -ne 'role') {
            $record[$property.Name] = $property.Value
        }
    }
    [pscustomobject]$record
}
