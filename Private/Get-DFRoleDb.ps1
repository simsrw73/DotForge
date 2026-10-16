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
        Normalizes a role's behaviors block: words, aliases (name -> words) and pickers (list as words).
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
    $used = @($aliases.Values | ForEach-Object { $_ }) + @($pickers | ForEach-Object { @($_.list) }) + @($env.Values | ForEach-Object { $_ })
    $undefined = @($used | Where-Object { $_ -notin $words } | Select-Object -Unique)
    $problem = if ($undefined) { "behaviors use undefined word(s): $($undefined -join ', ')" }
    [pscustomobject]@{
        Value   = [pscustomobject]@{ words = $words; aliases = $aliases; pickers = $pickers; env = $env }
        Problem = $problem
    }
}
