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
