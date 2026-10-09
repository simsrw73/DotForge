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
        [switch]$Force
    )

    $explicitToolsPath = $PSBoundParameters.ContainsKey('ToolsPath')

    if (-not $explicitToolsPath -and -not $Force -and $script:DFToolDb) { return $script:DFToolDb }

    $db = @{}

    if (Test-Path $ToolsPath -PathType Container) {
        Get-ChildItem $ToolsPath -Filter '*.json' -ErrorAction Ignore |
            ForEach-Object {
                try {
                    $tool = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $errors = @()
                    if (Test-DFToolSchema -Tool $tool -Errors ([ref]$errors)) {
                        $db[$tool.name] = ConvertTo-DFToolRecord $tool
                    } else {
                        Write-Warning "DotForge: $($_.Name) schema errors: $($errors -join '; ')"
                    }
                } catch {
                    Write-Warning "DotForge: Failed to parse $($_.Name): $($_.Exception.Message)"
                }
            }
    }

    if (-not $explicitToolsPath) { $script:DFToolDb = $db }
    return $db
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

            type 'exe', description '', tags @(), dependsOn @(), prewarm $true,
            packages / xdg / env / aliases / picker / themeMap /
            settings / scoopBucket $null, roles an empty object, executableExclude @()

        roles is an object keyed by role name; each value is { priority
        (default 0); optIn (default $false); aliases (same shape as top-level
        aliases, or $null); env; legacy }. An opt-in member is considered only
        when $DFConfig.Defaults selects it for that role. A legacy "role": "x"
        string becomes roles.x with priority 0 and legacy $true.

        Nested shapes are normalized too: xdg always has method, vars, dirs,
        config_path, config_content and instructions; each alias is
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
            config_path    = & $get $xdg 'config_path' $null
            config_content = & $get $xdg 'config_content' $null
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
        dependsOn   = [object[]]@(& $get $Tool 'dependsOn' @())
        roles       = [pscustomobject]$roles
        themeMap    = & $get $Tool 'themeMap' $null
        settings    = & $get $Tool 'settings' $null
        scoopBucket = & $get $Tool 'scoopBucket' $null
        executableExclude = [object[]]@(& $get $Tool 'executableExclude' @())
        prewarm     = [bool](& $get $Tool 'prewarm' $true)
    }
    # Keep fields DotForge doesn't model, so tool authors can carry extra data.
    foreach ($p in $Tool.PSObject.Properties) {
        if (-not $record.Contains($p.Name) -and $p.Name -ne 'role') { $record[$p.Name] = $p.Value }
    }
    [pscustomobject]$record
}
