# Companion for starship — prompt engine init
# Dot-sourced by Register-DFTool when starship is registered. The config path
# comes from STARSHIP_CONFIG (starship.json xdg.vars), applied before this runs.
# Invoke-Expression is required by starship's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
# --print-full-init emits the whole script instead of a stub that re-spawns
# starship to fetch it. The output is a pure function of starship's own build
# (verified byte-identical across runs; the session key is generated at
# runtime inside the script), so it is cached keyed to the binary's identity
# and a starship upgrade regenerates it. starship must init before zoxide,
# which wraps the prompt function — zoxide.json's "after" enforces the order.
function Get-DFStarshipConfigPath {
    # The config starship should read for -Palette: -Source itself when its top-level palette line
    # already names it (or it has none), else -Copy, rewritten as -Source with only that line
    # changed (plus the palette's table from -PalettesFile when -Source lacks it). The user's
    # file is never written. Nothing for a missing -Source.
    param([string]$Source, [Parameter(Mandatory)][string]$Palette, [Parameter(Mandatory)][string]$Copy, [string]$PalettesFile)
    if (-not $Source -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $text = [System.IO.File]::ReadAllText($Source)
    $lines = $text -split '(?<=\n)'
    $index = -1
    $inString = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # A multi-line string ("""...""" or '''...''') can hold lines that start with "[":
        # skip its body. An odd count of delimiters on a line opens or closes one.
        $delimiters = ([regex]::Matches($lines[$i], '"""|''''''')).Count
        $wasInString = $inString
        if ($delimiters % 2) { $inString = -not $inString }
        if ($wasInString) { continue }
        if ($lines[$i] -match '^\s*\[') { break }   # the first table ends the top level
        if ($lines[$i] -match '^\s*palette\s*=') { $index = $i; break }
    }
    if ($index -lt 0) { return $Source }
    $line = $lines[$index]
    # The line keeps its own ending (a split after each \n leaves it on the line).
    if ($line -notmatch '^(\s*palette\s*=\s*)(["''])([^"'']*)\2([^\r\n]*)(\r?\n?)$') { return $Source }
    if ($Matches[3] -ceq $Palette) { return $Source }
    $lines[$index] = $Matches[1] + $Matches[2] + $Palette + $Matches[2] + $Matches[4] + $Matches[5]
    $newText = -join $lines
    if ($newText -notmatch "(?m)^\s*\[palettes\.$([regex]::Escape($Palette))\]" -and $PalettesFile -and (Test-Path -LiteralPath $PalettesFile)) {
        $table = [regex]::Match([System.IO.File]::ReadAllText($PalettesFile), "(?ms)^\[palettes\.$([regex]::Escape($Palette))\]\r?\n.*?(?=^\[|\z)").Value
        if ($table) { $newText = $newText.TrimEnd() + "`n`n" + $table.TrimEnd() + "`n" }
    }
    $current = if (Test-Path -LiteralPath $Copy) { [System.IO.File]::ReadAllText($Copy) }
    if ($current -cne $newText) {
        New-DFDirectory (Split-Path $Copy) | Out-Null
        [System.IO.File]::WriteAllText($Copy, $newText, [System.Text.UTF8Encoding]::new($false))
    }
    $Copy
}

# The theme runs only when DotForge loads this companion ($DFCurrentTool set).
# The source is decided once, at load: a STARSHIP_CONFIG the user set, else the XDG path. A value
# pointing into DotForge's own cache (a nested shell inherited it) is not the user's.
if ($DFCurrentTool) {
$_starshipCache = Join-Path (Get-DFXdgPath Cache) 'dotforge' 'starship'

$_starshipPalettes = Join-Path $PSScriptRoot 'starship' 'catppuccin-palettes.toml'
$_starshipOwn = { param($Path) [bool]$Path -and $Path.StartsWith($_starshipCache, [System.StringComparison]::OrdinalIgnoreCase) }.GetNewClosure()
$_starshipSource = if ($Env:STARSHIP_CONFIG -and -not (& $_starshipOwn $Env:STARSHIP_CONFIG)) { $Env:STARSHIP_CONFIG }
    else { ConvertTo-DFPath (Expand-DFXdgPath '${XDG_CONFIG_HOME}/starship/starship.toml') }
$_starshipConfigPath = ${function:Get-DFStarshipConfigPath}
$_setEnv = ${function:Set-DFEnv}
$_envState = ${function:Get-DFEnvState}

Set-Item -Path 'function:global:Invoke-DFApplyStarshipTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a catppuccin palette to starship for this session without editing your starship.toml.
    .DESCRIPTION
        When your starship.toml sets a top-level palette other than -Name,
        DotForge writes a copy of it to
        $XDG_CACHE_HOME\dotforge\starship\starship-<palette>.toml with only that
        palette line changed (adding the palette's table when your
        file lacks it) and points STARSHIP_CONFIG at the copy. When the palette
        already matches, or your file sets none, STARSHIP_CONFIG stays on your
        file, so your edits show at once.

        Defined by DotForge's starship companion. It runs at startup with
        StarshipTheme, then Theme; Set-DFToolTheme starship <flavor> calls it.
    .PARAMETER Name
        The starship palette name, e.g. catppuccin_latte.
    .PARAMETER Implicit
        The theme came from the default, not a choice. A STARSHIP_CONFIG you set to your own
        config is themed either way; one pointing elsewhere is kept unless the theme was chosen.
    .EXAMPLE
        Set-DFToolTheme starship catppuccin-latte

        Switches the prompt to latte colors from the next prompt on.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)
    # One copy per palette: a shell using another palette never rewrites this one.
    $copy = Join-Path $_starshipCache "starship-$Name.toml"
    $path = & $_starshipConfigPath -Source $_starshipSource -Palette $Name -Copy $copy -PalettesFile $_starshipPalettes
    if (-not $path) { return }
    if (& $_starshipOwn $Env:STARSHIP_CONFIG) { Remove-Item Env:STARSHIP_CONFIG -ErrorAction Ignore }
    # 3. Your own STARSHIP_CONFIG is the source DotForge themes, not a value it competes with:
    # mark it as DotForge's, so switching to the derived copy neither keeps it nor warns.
    if ($Env:STARSHIP_CONFIG -and $Env:STARSHIP_CONFIG -eq $_starshipSource) { (& $_envState).Written['STARSHIP_CONFIG'] = $Env:STARSHIP_CONFIG }
    $explicit = if (-not $Implicit) { "starship theme '$Name' was applied" }
    & $_setEnv -Name 'STARSHIP_CONFIG' -Value $path -Tool 'starship' -ExplicitReason $explicit
}.GetNewClosure())

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
if ($_theme -and $_theme.Value) { Invoke-DFApplyStarshipTheme -Name $_theme.Value -Implicit:(-not $_theme.Explicit) }
}

function Initialize-DFRolePrompt {
    # Called by DotForge only when starship wins the prompt role.
    param([PSCustomObject]$Tool, [string]$Role)
    Invoke-Expression (Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship' -Generate {
        starship init powershell --print-full-init | Out-String
    })
    # The init script wraps its helpers in a dynamic module ('starship', exporting
    # Enable-/Disable-TransientPrompt). New-Module imports into the calling scope,
    # which here is DotForge's module scope, so the user could never call them.
    # Re-import it globally via the command's own module (a dynamic module that was
    # never Import-Module'd is not listed by Get-Module). prompt itself is declared
    # global: and is unaffected. Missing command = older/newer starship: skip quietly.
    $starshipModule = (Get-Command Enable-TransientPrompt -ErrorAction Ignore)?.Module
    if ($starshipModule) { Import-Module -ModuleInfo $starshipModule -Global }
    Remove-Variable starshipModule
}
