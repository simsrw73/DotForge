#Requires -Version 7.0
<#
.SYNOPSIS
    Generates docs/reference.md from the comment-based help of DotForge's exported
    functions and of the global functions its Tools/*.ps1 companions define.
.DESCRIPTION
    The reference is generated, never hand-edited: change a function's help, then
    rerun this script. tests/Docs.Reference.Tests.ps1 fails when the committed file
    is out of date.

    Everything is read from source with the PowerShell parser: help text, parameter
    types, defaults and attributes, and Set-Alias calls. The module is imported only
    to list exported functions and to render their syntax. Sidecars are never run,
    so none of the tools need to be installed. Output is deterministic (sorted, LF
    line endings, no timestamps).
.PARAMETER OutputPath
    Where to write the Markdown. Default: docs/reference.md in the repository.
.EXAMPLE
    ./build/Build-DFReferenceDocs.ps1

    Regenerates docs/reference.md.
.OUTPUTS
    None. Writes the file and prints its path.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..' 'docs' 'reference.md')
)

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Ast = [System.Management.Automation.Language.Ast]

# Public/*.ps1 basename -> reference section.
$sectionByFile = [ordered]@{
    'Add-DFToPath'               = 'Core'
    'Complete-DFToolSetup'       = 'Core'
    'Find-DFTool'                = 'Core'
    'Get-DFRole'                 = 'Core'
    'Get-DFTool'                 = 'Core'
    'Get-DFToolGroup'            = 'Core'
    'Start-DFSession'            = 'Core'
    'Get-DFToolStatus'           = 'Core'
    'Install-DFTool'             = 'Core'
    'Invoke-DFPicker'            = 'Core'
    'New-DFDirectory'            = 'Core'
    'New-DFShim'                 = 'Core'
    'Register-DFTool'            = 'Core'
    'DFHelpers.Help'             = 'Help and discovery'
    'DFHelpers.Navigation'       = 'Navigation'
    'DFHelpers.FileSystem'       = 'Files'
    'DFHelpers.Process'          = 'Processes'
    'DFHelpers.Environment'      = 'Environment and profile'
    'DFHelpers.Clipboard'        = 'Clipboard, pager and utilities'
    'DFHelpers.Pager'            = 'Core'
    'DFHelpers.Utility'          = 'Clipboard, pager and utilities'
    'Find-DFPackage'             = 'Package catalog'
    'Get-DFCategoryList'         = 'Package catalog'
    'Get-DFCommandConflict'      = 'Core'
    'Select-DFPackage'           = 'Package catalog'
    'Update-DFCategoryDb'        = 'Package catalog'
    'Update-DFPackageCache'      = 'Package catalog'
    'Update-DFToolIdentityGuide' = 'Package catalog'
}
$sectionOrder = @('Core', 'Help and discovery', 'Navigation', 'Files', 'Processes',
                  'Environment and profile', 'Clipboard, pager and utilities', 'Package catalog')

function Get-Slug([string]$Heading) {
    # GitHub's heading anchors: lowercase, drop punctuation except '-' and ' ', spaces to '-'.
    ($Heading.ToLowerInvariant() -replace '[^\p{L}\p{Nd} _-]', '') -replace ' ', '-'
}

function ConvertTo-MdInline([string]$Text) {
    # Escape Markdown outside `code spans`, which are kept as written.
    $parts = $Text -split '(`[^`]*`)'
    ($parts | ForEach-Object {
        if ($_ -like '`*`') { $_ }
        else { $_ -replace '\\', '\\' -replace '\*', '\*' -replace '<', '&lt;' -replace '>', '&gt;' -replace '\|', '\|' }
    }) -join ''
}

function ConvertTo-MdBlock([string]$Text) {
    # Paragraphs with indented continuation lines (key tables, aligned lists) stay
    # preformatted; everything else is reflowed into one Markdown paragraph.
    $paras = ($Text.Trim() -replace '\r', '') -split '\n\s*\n'
    $out = foreach ($p in $paras) {
        $lines = $p -split '\n'
        if (@($lines | Select-Object -Skip 1 | Where-Object { $_ -match '^\s' }).Count -gt 0 -or $lines[0] -match '^\s') {
            "``````text`n$p`n``````"
        } else {
            ConvertTo-MdInline (($lines | ForEach-Object Trim) -join ' ')
        }
    }
    $out -join "`n`n"
}

function Get-TypeName($ParamAst) {
    $tc = $ParamAst.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } |
        Select-Object -First 1
    if (-not $tc) { return 'Object' }
    $name = $tc.TypeName.Name
    switch -Regex ($name) {
        '^switch$|SwitchParameter' { return 'switch' }
        default { return ($name -replace '^System\.', '') }
    }
}

function Get-ParamRow($ParamAst, $Help) {
    $name = $ParamAst.Name.VariablePath.UserPath
    $attrs = @($ParamAst.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] })
    $paramAttr = $attrs | Where-Object { $_.TypeName.Name -eq 'Parameter' }
    $named = @($paramAttr.NamedArguments)
    $isTrue = { param($arg) $arg -and ($arg.ExpressionOmitted -or $arg.Argument.Extent.Text -eq '$true') }
    $required = [bool](& $isTrue ($named | Where-Object ArgumentName -EQ 'Mandatory' | Select-Object -First 1))
    $pipeline = @(
        if (& $isTrue ($named | Where-Object ArgumentName -EQ 'ValueFromPipeline' | Select-Object -First 1)) { 'value' }
        if (& $isTrue ($named | Where-Object ArgumentName -EQ 'ValueFromPipelineByPropertyName' | Select-Object -First 1)) { 'by name' }
        if (& $isTrue ($named | Where-Object ArgumentName -EQ 'ValueFromRemainingArguments' | Select-Object -First 1)) { 'remaining args' }
    ) -join ', '
    $validateSet = $attrs | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | Select-Object -First 1
    $desc = if ($Help -and $Help.Parameters[$name.ToUpperInvariant()]) {
        (($Help.Parameters[$name.ToUpperInvariant()].Trim() -replace '\r', '') -split '\s*\n\s*') -join ' '
    } else { '' }
    if ($validateSet) {
        $values = $validateSet.PositionalArguments | ForEach-Object { $_.Value }
        $desc += " Allowed: $($values -join ', ')."
    }
    $default = if ($ParamAst.DefaultValue) { '`' + $ParamAst.DefaultValue.Extent.Text + '`' } else { '' }
    '| `-{0}` | {1} | {2} | {3} | {4} | {5} |' -f $name, (Get-TypeName $ParamAst), $default,
        ($required ? 'yes' : ''), $pipeline, (ConvertTo-MdInline $desc.Trim())
}

function Get-FunctionMarkdown {
    param(
        [string]$Name,
        [System.Management.Automation.Language.ScriptBlockAst]$Body,
        [string[]]$Aliases,
        [string]$Syntax,
        [string]$HeadingLevel
    )
    $help = $Body.GetHelpContent()
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("$HeadingLevel $Name").AppendLine()
    if ($Aliases) { $null = $sb.AppendLine("Alias: " + (($Aliases | ForEach-Object { "``$_``" }) -join ', ')).AppendLine() }
    $null = $sb.AppendLine((ConvertTo-MdInline (($help.Synopsis.Trim() -replace '\s*\r?\n\s*', ' ')))).AppendLine()
    if ($Syntax) { $null = $sb.AppendLine('```text').AppendLine($Syntax.Trim()).AppendLine('```').AppendLine() }
    if ($help.Description) { $null = $sb.AppendLine((ConvertTo-MdBlock $help.Description)).AppendLine() }

    $params = @($Body.ParamBlock?.Parameters)
    if ($params) {
        $null = $sb.AppendLine('| Parameter | Type | Default | Required | Pipeline | Description |')
        $null = $sb.AppendLine('| --- | --- | --- | --- | --- | --- |')
        foreach ($p in $params) { $null = $sb.AppendLine((Get-ParamRow $p $help)) }
        $null = $sb.AppendLine()
    }
    if ($help.Outputs) {
        $null = $sb.AppendLine('**Outputs:** ' + (ConvertTo-MdInline (($help.Outputs.Trim() -replace '\s*\r?\n\s*', ' ')))).AppendLine()
    }
    $i = 0
    foreach ($ex in @($help.Examples)) {
        $i++
        $pieces = ($ex.Trim() -replace '\r', '') -split '\n\s*\n', 2
        $null = $sb.AppendLine("**Example $i**").AppendLine()
        $null = $sb.AppendLine('```powershell').AppendLine($pieces[0].TrimEnd()).AppendLine('```').AppendLine()
        if ($pieces.Count -gt 1 -and $pieces[1].Trim()) {
            $null = $sb.AppendLine((ConvertTo-MdBlock $pieces[1])).AppendLine()
        }
    }
    $links = @($help.Links | Where-Object { $_ -match '^https?://' })
    if ($links) {
        $guide = $links | ForEach-Object {
            $page = $_ -replace '^https://github\.com/simsrw73/DotForge/blob/main/docs/', ''
            if ($page -ne $_) { "[$($page -replace '^guide/', '' -replace '\.md$', '')]($page)" } else { "<$_>" }
        }
        $null = $sb.AppendLine('**See also:** ' + ($guide -join ', ')).AppendLine()
    }
    $sb.ToString()
}

function Get-AliasMap([string[]]$Files) {
    # Set-Alias -Name <alias> -Value <function> calls -> function -> aliases.
    $map = @{}
    foreach ($f in $Files) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Alias' }, $true)) {
            $els = $cmd.CommandElements
            $get = { param($pname) for ($i = 0; $i -lt $els.Count - 1; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $pname) { return $els[$i + 1].Extent.Text.Trim("'`"") } } }
            $alias = & $get 'Name'; $target = & $get 'Value'
            if ($alias -and $target) {
                if (-not $map[$target]) { $map[$target] = [System.Collections.Generic.List[string]]::new() }
                $map[$target].Add($alias)
            }
        }
    }
    $map
}

# ── Exported functions ─────────────────────────────────────────────────────────
Import-Module (Join-Path $repo 'DotForge.psd1') -Force 3>$null
$publicFiles = @(Get-ChildItem (Join-Path $repo 'Public') -Filter '*.ps1' | ForEach-Object FullName)
$publicAliases = Get-AliasMap $publicFiles

$exported = foreach ($cmd in Get-Command -Module DotForge -CommandType Function) {
    $file = [IO.Path]::GetFileNameWithoutExtension($cmd.ScriptBlock.File)
    [pscustomobject]@{
        Name    = $cmd.Name
        Section = $sectionByFile[$file] ?? $(throw "Public file '$file' is not mapped to a reference section in `$sectionByFile.")
        Body    = $cmd.ScriptBlock.Ast.Body
        Aliases = @($publicAliases[$cmd.Name] | Sort-Object)
        Syntax  = ((Get-Command $cmd.Name -Syntax) -replace '\r', '').Trim()
    }
}

# ── Sidecar globals ────────────────────────────────────────────────────────────
$sidecarFiles = @(Get-ChildItem (Join-Path $repo 'Tools') -Filter '*.ps1' | Sort-Object Name)
$sidecarAliases = Get-AliasMap ($sidecarFiles.FullName)
$sidecar = foreach ($file in $sidecarFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $tool = $file.BaseName
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'global:*' }, $true)) {
        $name = $fn.Name -replace '^global:'
        [pscustomobject]@{ Tool = $tool; Name = $name; Body = $fn.Body; Aliases = @($sidecarAliases[$name] | Sort-Object) }
    }
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Item' }, $true)) {
        $path = $cmd.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -like 'function:global:*' } |
            Select-Object -First 1
        $sbe = $cmd.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        if ($path -and $sbe) {
            $name = $path.Value -replace '^function:global:'
            [pscustomobject]@{ Tool = $tool; Name = $name; Body = $sbe.ScriptBlock; Aliases = @($sidecarAliases[$name] | Sort-Object) }
        }
    }
}

# ── Tool records ───────────────────────────────────────────────────────────────
function Get-ToolMarkdown($Tool, [string]$ToolsDir, [string[]]$ToolsWithFunctions) {
    $prop = { param($o, $n) if ($null -ne $o) { $o.PSObject.Properties[$n]?.Value } }
    $code = { param($v) '`' + (([string]$v -replace '\r?\n', ' ') -replace '`', "'") + '`' }
    $rows = [System.Collections.Generic.List[string]]::new()
    $add = { param($k, $v) if ($v) { $rows.Add("| $k | $v |") } }

    $type = & $prop $Tool 'type'
    & $add 'Detected by' ($(if ($type -eq 'module') { 'module ' } else { '' }) + (& $code $Tool.executable))
    & $add 'Tags' ((@(& $prop $Tool 'tags') | ForEach-Object { & $code $_ }) -join ', ')
    $pk = & $prop $Tool 'packages'
    if ($pk) { & $add 'Install ids' (($pk.PSObject.Properties | ForEach-Object { "$($_.Name): $(& $code $_.Value)" }) -join '<br>') }
    $xdg = & $prop $Tool 'xdg'
    if ($xdg) {
        $method = & $prop $xdg 'method'
        & $add 'XDG method' (& $code $method)
        $vars = & $prop $xdg 'vars'
        if ($vars) { & $add 'XDG variables' (($vars.PSObject.Properties | ForEach-Object { "$(& $code $_.Name) = $(& $code $_.Value)" }) -join '<br>') }
        $dirs = & $prop $xdg 'dirs'
        if ($dirs) { & $add 'Creates' ((@($dirs) | ForEach-Object { & $code $_ }) -join '<br>') }
    }
    $env = & $prop $Tool 'env'
    if ($env) { & $add 'Environment' (($env.PSObject.Properties | ForEach-Object { "$(& $code $_.Name) = $(& $code $_.Value)" }) -join '<br>') }
    $aliases = & $prop $Tool 'aliases'
    if ($aliases -and @($aliases.PSObject.Properties).Count) {
        & $add 'Aliases' (($aliases.PSObject.Properties | ForEach-Object {
            $cmd = (@($_.Value.command) + @($_.Value.PSObject.Properties['args']?.Value) | Where-Object { $_ }) -join ' '
            "$(& $code $_.Name) → $(& $code $cmd)" }) -join '<br>')
    }
    $picker = & $prop $Tool 'picker'
    if ($picker -is [pscustomobject]) {
        $action = & $prop $picker 'action'
        $what = if ($action -eq 'output') { 'outputs the selection' } else { 'runs ' + (& $code $action) }
        & $add 'Picker' "$(& $code (& $prop $picker 'alias')) ($(& $prop $picker 'function')): lists $(& $code (& $prop $picker 'list')); Enter $what"
    }
    $deps = & $prop $Tool 'dependsOn'
    if ($deps) { & $add 'Registers after' ((@($deps) | ForEach-Object { & $code $_ }) -join ', ') }
    $roles = & $prop $Tool 'roles'
    $roleNames = @(if ($roles) { $roles.PSObject.Properties.Name })
    if (& $prop $Tool 'role') { $roleNames += & $prop $Tool 'role' }
    & $add 'Roles' ((@($roleNames | Where-Object { $_ } | Sort-Object -Unique) | ForEach-Object { "[$(& $code $_)](#$(Get-Slug "$_ role"))" }) -join ', ')
    if ($roles) {
        foreach ($r in $roles.PSObject.Properties) {
            $renv = & $prop $r.Value 'env'
            if ($renv) { & $add "Sets, as the $($r.Name) tool" (($renv.PSObject.Properties | ForEach-Object { "$(& $code $_.Name) = $(& $code $_.Value)" }) -join '<br>') }
            $ral = & $prop $r.Value 'aliases'
            if ($ral -and @($ral.PSObject.Properties).Count) {
                & $add "Aliases, as the $($r.Name) tool" (($ral.PSObject.Properties | ForEach-Object {
                    $cmd = (@($_.Value.command) + @($_.Value.PSObject.Properties['args']?.Value) | Where-Object { $_ }) -join ' '
                    "$(& $code $_.Name) → $(& $code $cmd)" }) -join '<br>')
            }
        }
    }
    $companion = Test-Path (Join-Path $ToolsDir "$($Tool.name).ps1")
    $setup = Test-Path (Join-Path $ToolsDir "$($Tool.name).setup.ps1")
    & $add 'Companion' (@(
        # Link only when the companion defines functions, so its section exists below.
        if ($companion -and $Tool.name -in $ToolsWithFunctions) { "[``Tools/$($Tool.name).ps1``](#$(Get-Slug "$($Tool.name) companion"))" }
        elseif ($companion) { "``Tools/$($Tool.name).ps1``" }
        if ($setup) { "one-time ``Tools/$($Tool.name).setup.ps1``" }
    ) -join ', ')

    $sb = [System.Text.StringBuilder]::new()
    # "<name> tool", so the anchor can't collide with a same-named companion function (glow, fastfetch).
    $null = $sb.AppendLine("### $($Tool.name) tool").AppendLine()
    $null = $sb.AppendLine((ConvertTo-MdInline ([string](& $prop $Tool 'description')))).AppendLine()
    $null = $sb.AppendLine('| | |').AppendLine('| --- | --- |')
    foreach ($r in $rows) { $null = $sb.AppendLine($r) }
    $sb.AppendLine().ToString()
}

$toolsDir = Join-Path $repo 'Tools'
$toolRecords = Get-ChildItem $toolsDir -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    Sort-Object { $_.name.ToLowerInvariant() }

# ── Render ─────────────────────────────────────────────────────────────────────
$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine('<!-- Generated by build/Build-DFReferenceDocs.ps1 from comment-based help. Do not edit by hand. -->')
$null = $md.AppendLine('# DotForge reference').AppendLine()
$null = $md.AppendLine('**Audience:** anyone looking up a DotForge command, parameter or default.  ')
$null = $md.AppendLine('**Topic:** every exported cmdlet, and every function a tool companion defines when its tool is registered.  ')
$null = $md.AppendLine('**Goal:** find exact syntax, parameters, defaults and outputs. For walkthroughs, start with the [getting started guide](guide/getting-started.md).').AppendLine()
$null = $md.AppendLine('Everything here is also available in the shell: `Get-Help <name> -Full`.').AppendLine()

$null = $md.AppendLine('## Contents').AppendLine()
foreach ($section in $sectionOrder) {
    $inSection = @($exported | Where-Object Section -EQ $section | Sort-Object Name)
    if (-not $inSection) { continue }
    $null = $md.AppendLine("**$section**").AppendLine()
    $null = $md.AppendLine('| Command | Alias | Summary |').AppendLine('| --- | --- | --- |')
    foreach ($f in $inSection) {
        $syn = ConvertTo-MdInline ($f.Body.GetHelpContent().Synopsis.Trim() -replace '\s*\r?\n\s*', ' ')
        $null = $md.AppendLine(('| [{0}](#{1}) | {2} | {3} |' -f $f.Name, (Get-Slug $f.Name), (($f.Aliases | ForEach-Object { "``$_``" }) -join ', '), $syn))
    }
    $null = $md.AppendLine()
}
$null = $md.AppendLine('**Tool records**').AppendLine()
$null = $md.AppendLine(($toolRecords | ForEach-Object { "[$($_.name)](#$(Get-Slug "$($_.name) tool"))" }) -join ' · ').AppendLine()
$roleDefs = Get-Content (Join-Path $repo 'data' 'roles.json') -Raw | ConvertFrom-Json
$roleNamesSorted = @($roleDefs.PSObject.Properties.Name | Sort-Object)
$null = $md.AppendLine('**Roles**').AppendLine()
$null = $md.AppendLine(($roleNamesSorted | ForEach-Object { "[$_](#$(Get-Slug "$_ role"))" }) -join ' · ').AppendLine()
$null = $md.AppendLine('**Tool companion functions**').AppendLine()
$null = $md.AppendLine('| Command | Alias | Tool | Summary |').AppendLine('| --- | --- | --- | --- |')
foreach ($f in $sidecar | Sort-Object Tool, Name) {
    $syn = ConvertTo-MdInline ($f.Body.GetHelpContent().Synopsis.Trim() -replace '\s*\r?\n\s*', ' ')
    $null = $md.AppendLine(('| [{0}](#{1}) | {2} | {3} | {4} |' -f $f.Name, (Get-Slug $f.Name), (($f.Aliases | ForEach-Object { "``$_``" }) -join ', '), $f.Tool, $syn))
}
$null = $md.AppendLine()

foreach ($section in $sectionOrder) {
    $inSection = @($exported | Where-Object Section -EQ $section | Sort-Object Name)
    if (-not $inSection) { continue }
    $null = $md.AppendLine("## $section").AppendLine()
    foreach ($f in $inSection) {
        $null = $md.Append((Get-FunctionMarkdown -Name $f.Name -Body $f.Body -Aliases $f.Aliases -Syntax $f.Syntax -HeadingLevel '###'))
    }
}

$null = $md.AppendLine('## Roles').AppendLine()
$null = $md.AppendLine('A role is a job several tools can do. For a *single* role, one installed tool wins (`$DFConfig.Defaults`, else the highest priority) and only it sets the role''s variables and aliases and installs its hooks. A *category* only groups tools. Run `Get-DFRole` to see the winners on your machine.').AppendLine()
foreach ($roleName in $roleNamesSorted) {
    $def = $roleDefs.$roleName
    $members = @($toolRecords | Where-Object {
        $tr = $_.PSObject.Properties['roles']?.Value
        ($tr -and $tr.PSObject.Properties[$roleName]) -or $_.PSObject.Properties['role']?.Value -eq $roleName
    } | ForEach-Object { "[$($_.name)](#$(Get-Slug "$($_.name) tool"))" })
    $kind = if ($def.kind -eq 'single') { if ($def.PSObject.Properties['exclusive']?.Value) { 'single, exclusive' } else { 'single' } } else { 'category' }
    $null = $md.AppendLine("### $roleName role").AppendLine()
    $null = $md.AppendLine((ConvertTo-MdInline $def.description)).AppendLine()
    $null = $md.AppendLine('| | |').AppendLine('| --- | --- |')
    $null = $md.AppendLine("| Kind | $kind |")
    $null = $md.AppendLine("| Members | $($members -join ', ') |")
    $res = $def.PSObject.Properties['reserved']?.Value
    $resNames = @(@(if ($res) { @($res.env) + @($res.aliases) }) | Where-Object { $_ } | ForEach-Object { "``$_``" })
    if ($resNames) { $null = $md.AppendLine("| Only the winner sets | $($resNames -join ', ') |") }
    if ($def.PSObject.Properties['requires']) { $null = $md.AppendLine("| Requires | $(ConvertTo-MdInline $def.requires) |") }
    $null = $md.AppendLine()
}

$null = $md.AppendLine('## Tool records').AppendLine()
$null = $md.AppendLine('What `Register-DFTool` does for each tool, read from its `Tools/<name>.json` record. A tool is configured only when it is detected: its executable is on `PATH`, or for a module, the module is installed. For the record format, see [Writing a tool record](guide/writing-a-tool.md).').AppendLine()
$withFunctions = @($sidecar.Tool | Sort-Object -Unique)
foreach ($t in $toolRecords) { $null = $md.Append((Get-ToolMarkdown $t $toolsDir $withFunctions)) }

$null = $md.AppendLine('## Tool companion functions').AppendLine()
$null = $md.AppendLine('These are defined when their tool is registered (`Register-DFTool`), not when the module is imported. Each needs its tool installed.').AppendLine()
foreach ($group in $sidecar | Sort-Object Tool, Name | Group-Object Tool) {
    $null = $md.AppendLine("### $($group.Name) companion").AppendLine()
    foreach ($f in $group.Group) {
        $null = $md.Append((Get-FunctionMarkdown -Name $f.Name -Body $f.Body -Aliases $f.Aliases -HeadingLevel '####'))
    }
}

$text = ($md.ToString() -replace '\r', '').TrimEnd() + "`n"
# Collapse runs of blank lines the section joins can leave behind.
$text = $text -replace '\n{3,}', "`n`n"
$dir = Split-Path $OutputPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, $text, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath"
