#Requires -Version 7.0

function Test-DFToolSchema {
    <#
    .SYNOPSIS
        Validates a tool PSCustomObject against the DotForge tool schema.
        Returns $true if valid; populates -Errors with any violation messages.
    .DESCRIPTION
        Private validator for tool JSON records: required fields, enum values, and the
        shapes of picker, aliases, env, themeMap, dependsOn, requires, prewarm and role blocks.
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
    $validMethods = @('default', 'env', 'config', 'wrapper', 'manual')
    $xdgMethod = PSProp (PSProp $Tool 'xdg') 'method'
    if ($xdgMethod -and $xdgMethod -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$xdgMethod'. Valid: $($validMethods -join ', ')")
    }

    # executableExclude: glob patterns of install locations to skip.
    # Read the property directly: returning it through PSProp would unroll a
    # one-element array into a bare string and fail the array check.
    $exclude = $Tool.PSObject.Properties['executableExclude']?.Value
    if ($null -ne $exclude -and ($exclude -isnot [array] -or @($exclude | Where-Object { $_ -isnot [string] }).Count)) {
        $errs.Add('executableExclude must be an array of strings')
    }

    # scoopBucket: { name; url } naming a third-party scoop bucket.
    $bucket = PSProp $Tool 'scoopBucket'
    if ($null -ne $bucket -and (-not (PSProp $bucket 'name') -or -not (PSProp $bucket 'url'))) {
        $errs.Add('scoopBucket must be an object with non-empty name and url')
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

    $dependsOn = $Tool.PSObject.Properties['dependsOn']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $dependsOn -and ($dependsOn -isnot [array] -or @($dependsOn | Where-Object { $_ -isnot [string] }).Count)) {
        $errs.Add('dependsOn must be an array of tool names')
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
                 'picker', 'dependsOn', 'roles', 'themeMap', 'settings', 'scoopBucket', 'executableExclude',
                 'prewarm', 'role', 'requires'
        picker = 'function', 'alias', 'list', 'list_accepts_path', 'preview', 'preview_window', 'ansi',
                 'header', 'action', 'parse'
        xdg    = 'method', 'vars', 'dirs', 'config_path', 'config_content', 'instructions', 'compliance'
        role   = 'priority', 'optIn', 'aliases', 'env'
    }
    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add(@('', $Tool, ''))
    if ($picker -is [pscustomobject]) { $sections.Add(@('picker', $picker, 'picker.')) }
    $xdg = PSProp $Tool 'xdg'
    if ($xdg -is [pscustomobject]) { $sections.Add(@('xdg', $xdg, 'xdg.')) }
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
