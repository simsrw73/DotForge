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
    if ($null -ne $after -and ($after -isnot [array] -or @($after | Where-Object { $_ -isnot [string] -or $_ -notmatch '^(role:)?[A-Za-z0-9][A-Za-z0-9._-]*$' }).Count)) {
        'after must be an array of tool names or role:<role> entries'
    }
}

function Get-DFSetupSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in setup and setup.seed.
    #>
    $setup = $Tool.PSObject.Properties['setup']?.Value
    if ($null -ne $setup) {
        $seed = $setup.PSObject.Properties['seed']?.Value
        if ($setup -isnot [pscustomobject]) {
            'setup must be an object'
        } elseif ($null -ne $seed -and ($seed -isnot [pscustomobject] -or @($seed.PSObject.Properties | Where-Object { $_.Value -isnot [string] -or -not $_.Value }).Count)) {
            'setup.seed must map destination paths to files under Tools/'
        }
    }
}

function Get-DFActivationSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in requires and prewarm.
    #>
    $requires = $Tool.PSObject.Properties['requires']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $requires -and ($requires -isnot [array] -or @($requires | Where-Object { $_ -isnot [string] -or $_ -notmatch '^(role:)?[A-Za-z0-9][A-Za-z0-9._-]*$' }).Count)) {
        'requires must be an array of tool names or role:<role> entries'
    }
    $prewarm = Get-DFSchemaProperty $Tool 'prewarm'
    if ($null -ne $prewarm -and $prewarm -isnot [bool]) { 'prewarm must be a boolean (true/false, not a string)' }
}

function Get-DFInstallsSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in installs (one block or a list) and install.prefer.
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
            $cmd = $ins.PSObject.Properties['command']?.Value   # read directly: a helper would unroll ["x"]
            $hasCmd = $null -ne $cmd
            $hasFn = $null -ne (Get-DFSchemaProperty $ins 'function')
            if ($hasCmd -eq $hasFn) { "$at needs exactly one of command or function" }
            if ($hasCmd -and $cmd -isnot [array]) { "$at.command must be an array (argv)" }
        }
    }
    $inst = Get-DFSchemaProperty $Tool 'install'
    if ($null -ne $inst) {
        $have = @((Get-DFSchemaProperty $Tool 'packages')?.PSObject.Properties.Name)
        $bad = @(@($inst.PSObject.Properties['prefer']?.Value) | Where-Object { $_ -and $_ -notin $have })
        if ($bad) { "install.prefer names sources the tool has no package for: $($bad -join ', ')" }
    }
}

function Get-DFPickerSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in picker, including action and parse code that does not compile.
    #>
    # picker: null, "custom" (the companion defines its own), or a declarative object.
    $picker = Get-DFSchemaProperty $Tool 'picker'
    if ($picker -is [string] -and $picker -ne 'custom') {
        "picker must be null, ""custom"" or an object (got ""$picker"")"
    } elseif ($null -ne $picker -and $picker -isnot [string]) {
        if ($picker -isnot [pscustomobject]) {
            'picker must be null, "custom" or an object'
        } else {
            foreach ($req in 'function', 'list') {
                $v = Get-DFSchemaProperty $picker $req
                if ($v -isnot [string] -or -not $v) { "picker.$req is required (a string)" }
            }
            foreach ($b in 'ansi', 'list_accepts_path') {
                $v = Get-DFSchemaProperty $picker $b
                if ($null -ne $v -and $v -isnot [bool]) { "picker.$b must be a boolean (true/false, not a string)" }
            }
            # These become scriptblocks when the picker is built; catch a syntax error
            # here, at load, instead of when the profile runs.
            $action = Get-DFSchemaProperty $picker 'action'
            if ($action -is [string] -and $action -and $action -ne 'output') {
                try { $null = [scriptblock]::Create('param($v) ' + $action.Replace('{}', '$v')) }
                catch { "picker.action is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
            }
            $parse = Get-DFSchemaProperty $picker 'parse'
            if ($parse -is [string] -and $parse) {
                try { $null = [scriptblock]::Create($parse) }
                catch { "picker.parse is not valid PowerShell: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
            }
        }
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
    $xdg = Get-DFSchemaProperty $Tool 'xdg'
    if ($xdg -is [pscustomobject]) { $sections.Add(@('xdg', $xdg, 'xdg.')) }
    $setupObj = Get-DFSchemaProperty $Tool 'setup'
    if ($setupObj -is [pscustomobject]) { $sections.Add(@('setup', $setupObj, 'setup.')) }
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
        shapes of picker, aliases, env, themeMap, after, requires, setup, prewarm and role blocks.
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
        Get-DFOrderingSchemaError $Tool
        Get-DFSetupSchemaError $Tool
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
