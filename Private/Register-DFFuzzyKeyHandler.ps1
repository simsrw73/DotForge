#Requires -Version 7.2

# Ctrl+R / Ctrl+T for fzf-compatible engines that ship no PowerShell bindings
# (fzf, skim). Each tool's role hook passes its own executable; nothing here names
# a tool. Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.

# How a multi-line history entry is shown on one line in the picker.
$script:DFHistoryLineMark = ' ␤ '

function Register-DFFuzzyKeyHandler {
    <#
    .SYNOPSIS
        Binds Ctrl+R (history) or Ctrl+T (paths) to an fzf-compatible engine.
    .DESCRIPTION
        History: PSReadLine's saved history, newest first and without repeats,
        is piped to <engine> --no-sort --query <line>, and the pick replaces
        the line. Path: the engine runs its own default command
        (FZF_DEFAULT_COMMAND / SKIM_DEFAULT_COMMAND) with --multi, and the
        picks are inserted at the cursor. Esc changes nothing. Binds through
        Set-DFRoleKeyHandler, so a binding the user made is kept.
    .PARAMETER Engine
        The executable, e.g. fzf or sk.
    .PARAMETER Key
        History (Ctrl+r, role history-search) or Path (Ctrl+t, role path-insert).
    .PARAMETER Tool
        The tool's name, for its status.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][ValidateSet('History', 'Path')][string]$Key,
        [Parameter(Mandatory)][string]$Tool
    )
    $role = if ($Key -eq 'History') { 'history-search' } else { 'path-insert' }
    $chord = if ($Key -eq 'History') { 'Ctrl+r' } else { 'Ctrl+t' }
    # The handler runs later, outside the module: carry the private function along.
    $invoke = ${function:Invoke-DFFuzzyKey}
    $handler = { & $invoke -Engine $Engine -Key $Key }.GetNewClosure()
    # -Bind runs at once, inside Set-DFRoleKeyHandler, so it needs no closure.
    Set-DFRoleKeyHandler -Role $role -Chord $chord -Tool $Tool -Bind {
        Set-PSReadLineKeyHandler -Chord $chord -BriefDescription "DotForge $role ($Engine)" -Description "Fuzzy $role with $Engine (DotForge)" -ScriptBlock $handler
    }
}

function Invoke-DFFuzzyKey {
    <#
    .SYNOPSIS
        Runs one fuzzy key press: picks with the engine, then edits the command line.
    .PARAMETER Engine
        The executable.
    .PARAMETER Key
        History or Path.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][ValidateSet('History', 'Path')][string]$Key)
    $buffer = Get-DFReadLineBuffer
    if ($Key -eq 'History') {
        $shown = [ordered]@{}
        foreach ($entry in @(Get-DFHistoryCandidate -Path (Get-PSReadLineOption).HistorySavePath)) {
            $shown[$entry.Replace("`n", $script:DFHistoryLineMark)] = $entry
        }
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--no-sort', '--query', $buffer.Line) -InputObject ([string[]]@($shown.Keys)))
        if ($picked.Count -and $shown.Contains([string]$picked[0])) { Update-DFReadLineBuffer -Replace $shown[[string]$picked[0]]; return }
    } else {
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--multi'))
        if ($picked.Count) { Update-DFReadLineBuffer -Insert (Format-DFPathInsert -Path $picked); return }
    }
    Update-DFReadLineBuffer
}

function Get-DFHistoryCandidate {
    <#
    .SYNOPSIS
        PSReadLine's saved history, newest first, without repeats; a multi-line entry stays one entry.
    .DESCRIPTION
        PSReadLine saves a multi-line command with a backtick ending every line
        but the last; those lines are joined with a newline.
    .PARAMETER Path
        The history file (Get-PSReadLineOption).HistorySavePath.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $entries = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Text.StringBuilder]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.EndsWith('`')) { [void]$pending.Append($line.Substring(0, $line.Length - 1)).Append("`n"); continue }
        $entries.Add($pending.ToString() + $line)
        [void]$pending.Clear()
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        if ($entry.Trim() -and $seen.Add($entry)) { $entry }
    }
}

function Format-DFPathInsert {
    <#
    .SYNOPSIS
        Joins picked paths into PowerShell arguments, single-quoting any that isn't plainly a path.
    .DESCRIPTION
        A file name can hold $( ), ;, &, a backtick and more, which PowerShell
        would run when the line is entered. Only names made of letters, digits
        and . / \ : _ + - (not starting with -) stay bare; every other name is
        single-quoted, with every kind of single quote doubled.
    .PARAMETER Path
        The picked paths.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Path)
    @(foreach ($p in $Path) { if ($p -cmatch '^[\w./\\:+][\w./\\:+-]*$') { $p } else {
        # PowerShell also ends a single-quoted string at ‘ ’ ‚ ‛; its own escaper doubles them all.
        "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($p) + "'"
    } }) -join ' '
}

function Invoke-DFFuzzyEngine {
    <#
    .SYNOPSIS
        Runs the engine: on the given items, or on its own default command when none are given.
    .PARAMETER Engine
        The executable.
    .PARAMETER Arguments
        Its arguments.
    .PARAMETER InputObject
        Lines to pick from; omit it to let the engine list files itself.
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [string[]]$InputObject)
    # PowerShell sends the items as UTF-8 ($OutputEncoding) but decodes the picks with the console's
    # code page (437 by default), which garbles any non-ASCII pick: read them as UTF-8 too.
    $consoleEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        if ($PSBoundParameters.ContainsKey('InputObject')) { $InputObject | & $Engine @Arguments } else { & $Engine @Arguments }
    } finally {
        [Console]::OutputEncoding = $consoleEncoding
    }
}

function Get-DFReadLineBuffer {
    <#
    .SYNOPSIS
        The command line being edited and the cursor position.
    .OUTPUTS
        PSCustomObject: Line, Cursor.
    #>
    [CmdletBinding()]
    param()
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
}

function Update-DFReadLineBuffer {
    <#
    .SYNOPSIS
        Replaces the command line or inserts text at the cursor, then redraws the prompt.
    .PARAMETER Replace
        The new command line.
    .PARAMETER Insert
        Text to insert at the cursor.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([string]$Replace, [string]$Insert)
    if ($Replace) {
        $buffer = Get-DFReadLineBuffer
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $buffer.Line.Length, $Replace)
    } elseif ($Insert) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Insert)
    }
    # A full-screen picker leaves the prompt half-drawn.
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
}

function Remove-DFKeyHandlerCall {
    <#
    .SYNOPSIS
        Removes every Set-PSReadLineKeyHandler call from a tool's init script, so only role winners bind keys.
    .DESCRIPTION
        Parses the script and cuts out each outermost Set-PSReadLineKeyHandler
        command. A script that doesn't parse returns $null: loading nothing is
        safer than loading a script whose bindings couldn't be removed.
    .PARAMETER Script
        The init script text.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return $null }
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-PSReadLineKeyHandler' }, $true))
    $outermost = @($calls | Where-Object {
        $parent = $_.Parent
        while ($parent) { if ($parent -in $calls) { return $false }; $parent = $parent.Parent }
        $true
    })
    $text = $Script
    foreach ($call in @($outermost | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $text = $text.Remove($call.Extent.StartOffset, $call.Extent.EndOffset - $call.Extent.StartOffset)
    }
    $text
}
