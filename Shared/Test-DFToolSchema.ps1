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
        Schema errors in xdg.native: each key names something DotForge relocates; move and block were retired (existing data is linked, never moved).
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
            foreach ($retired in 'move', 'block') {
                if ($entry.PSObject.Properties[$retired]) { "xdg.native.$($p.Name).$retired was retired: DotForge links existing data instead of moving it" }
            }
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