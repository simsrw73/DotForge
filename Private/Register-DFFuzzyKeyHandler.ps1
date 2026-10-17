#Requires -Version 7.2

# Ctrl+R / Ctrl+T / Alt+C for fzf-compatible engines that ship no PowerShell bindings
# (fzf, skim). Each tool's role hook passes its own executable; nothing here names
# a tool. Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.

# How a multi-line history entry is shown on one line in the picker.
$script:DFHistoryLineMark = ' ␤ '
# Set by Write-DFKeyMessage: the next redraw goes below the message instead of over it.
$script:DFKeyMessageShown = $false

function Register-DFFuzzyKeyHandler {
    <#
    .SYNOPSIS
        Binds Ctrl+R (history), Ctrl+T (paths) or Alt+C (folders) to an fzf-compatible engine.
    .DESCRIPTION
        History: PSReadLine's saved history, newest first and without repeats,
        is piped to <engine> --no-sort --query <line>, and the pick replaces
        the line. Path: the engine runs its own default command
        (FZF_DEFAULT_COMMAND / SKIM_DEFAULT_COMMAND) with --multi, and the
        picks are inserted at the cursor. Directory: the Alt+C folder list
        (Get-DFDirectoryJumpCandidate) is streamed to <engine> --tiebreak=index,
        and the shell moves to the pick (Enter-DFDirectory). Esc changes nothing. Binds through
        Set-DFRoleKeyHandler, so a binding the user made is kept.
    .PARAMETER Engine
        The executable, e.g. fzf or sk.
    .PARAMETER Key
        History (Ctrl+r, role history-search), Path (Ctrl+t, role path-insert) or
        Directory (Alt+c, role directory-jump).
    .PARAMETER Tool
        The tool's name, for its status.
    .PARAMETER Accent
        Directory only: the #rrggbb color the ranked (zoxide) folders are drawn
        in, usually the engine's theme prompt color; without one they are bold.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][ValidateSet('History', 'Path', 'Directory')][string]$Key,
        [Parameter(Mandatory)][string]$Tool,
        [string]$Accent
    )
    $role, $chord = switch ($Key) {
        'History' { 'history-search', 'Ctrl+r' }
        'Path' { 'path-insert', 'Ctrl+t' }
        'Directory' { 'directory-jump', 'Alt+c' }
    }
    # The handler runs later, outside the module: carry the private function along.
    $invoke = ${function:Invoke-DFFuzzyKey}
    $handler = { & $invoke -Engine $Engine -Key $Key -Accent $Accent }.GetNewClosure()
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
        History, Path or Directory.
    .PARAMETER Accent
        Directory only: the ranked folders' color (see Register-DFFuzzyKeyHandler).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][ValidateSet('History', 'Path', 'Directory')][string]$Key, [string]$Accent)
    if ($Key -eq 'Directory') { Invoke-DFDirectoryKey -Engine $Engine -Accent $Accent; return }
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

function Invoke-DFDirectoryKey {
    <#
    .SYNOPSIS
        Alt+C: streams the folder list to the engine and moves the shell to the pick; the typed line stays.
    .PARAMETER Engine
        The executable.
    .PARAMETER Accent
        The ranked folders' #rrggbb color; anything else draws them bold.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string]$Accent)
    # Shown text -> full path, filled as the lines go out; the pick is mapped back, never parsed.
    # The engine runs with --ansi, so it shows the color and returns the plain text.
    $paths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $escape = [char]27
    $highlight = if ($Accent -cmatch '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        '{0}[38;2;{1};{2};{3}m' -f $escape, [Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16)
    } else { "$escape[1m" }
    $reset = "$escape[0m"
    # Not a closure: it runs inside this call (through Invoke-DFFuzzyEngine), in the
    # module, so it finds the private function and $paths there (and tests can mock it).
    $source = {
        param($StopWhen)
        Get-DFDirectoryJumpCandidate -StopWhen $StopWhen | ForEach-Object {
            $paths[$_.Shown] = $_.Path
            if ($_.Ranked) { "$highlight$($_.Shown)$reset" } else { $_.Shown }
        }
    }
    $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--ansi', '--tiebreak=index') -Stream $source)
    if ($picked.Count -and $paths.ContainsKey([string]$picked[0])) { [void](Enter-DFDirectory -Path $paths[[string]$picked[0]]) }
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
        and . / \ : _ + - (not starting with -) stay bare, unless PowerShell
        would read them as a number (1kb, 0x10, 1e3); every other name is
        single-quoted, with every kind of single quote doubled.
    .PARAMETER Path
        The picked paths.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Path)
    @(foreach ($p in $Path) { if ($p -cmatch '^[\w./\\:+][\w./\\:+-]*$' -and -not (Test-DFNumericArgument $p)) { $p } else {
        # PowerShell also ends a single-quoted string at ‘ ’ ‚ ‛; its own escaper doubles them all.
        "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($p) + "'"
    } }) -join ' '
}

function Test-DFNumericArgument {
    <#
    .SYNOPSIS
        Tells whether PowerShell reads a bare command argument as a number (1kb, 0x10, 1e3, +5).
    .PARAMETER Text
        The bare argument.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -notmatch '^[+.]?\d') { return $false }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput("echo $Text", [ref]$tokens, [ref]$errors)
    $argument = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[1]
    -not ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst])
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
    .PARAMETER Stream
        A source to stream lines from instead, called with one argument: a
        scriptblock that returns $true once the engine has exited, so the source
        can stop early (Invoke-DFFuzzyEngineStream).
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [string[]]$InputObject, [scriptblock]$Stream)
    if ($Stream) { return Invoke-DFFuzzyEngineStream -Engine $Engine -Arguments $Arguments -Source $Stream }
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

function Invoke-DFFuzzyEngineStream {
    <#
    .SYNOPSIS
        Runs the engine as a process and writes the source's lines to it as they come, stopping the source when the engine exits.
    .DESCRIPTION
        A PowerShell pipeline keeps running its upstream after a native
        command at its end exits, so a pick made before a long scan ends would
        wait for the scan. Here the source gets a stop check
        ({ engine exited }) and the lines go to the engine's stdin directly,
        UTF-8 both ways.
    .PARAMETER Engine
        The executable name.
    .PARAMETER Arguments
        Its arguments.
    .PARAMETER Source
        Called with the stop check; writes the lines.
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [Parameter(Mandatory)][scriptblock]$Source)
    $exe = (Get-Command -Name $Engine -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    if (-not $exe) { Write-Verbose "DotForge: $Engine not found"; return }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $stopWhen = { $process.HasExited }.GetNewClosure()
        try {
            & $Source $stopWhen | ForEach-Object {
                if (-not $process.HasExited) {
                    try { $process.StandardInput.WriteLine([string]$_); $process.StandardInput.Flush() } catch [System.IO.IOException] { Write-Verbose 'DotForge: the engine closed its input' }
                }
            }
        } finally {
            try { $process.StandardInput.Close() } catch [System.IO.IOException] { Write-Verbose 'DotForge: the engine closed its input' }
        }
        $process.WaitForExit()
        [string[]]@($output.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ })
    } finally {
        $process.Dispose()
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
    # A full-screen picker leaves the prompt half-drawn. After a message, redraw below it:
    # a plain redraw starts on the prompt's first row and would wipe it.
    $below = $script:DFKeyMessageShown
    $script:DFKeyMessageShown = $false
    Invoke-DFPromptRedraw -Below:$below
}

function Write-DFKeyMessage {
    <#
    .SYNOPSIS
        Writes one red line from a key handler, on a line of its own, and has the next redraw keep it on screen.
    .PARAMETER Text
        The message.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Red
    $script:DFKeyMessageShown = $true
}

function Invoke-DFPromptRedraw {
    <#
    .SYNOPSIS
        Redraws the prompt and the line being typed: in place, or (-Below) starting on the cursor's row.
    .PARAMETER Below
        Start on the cursor's row, below a message just written.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([switch]$Below)
    if ($Below) { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, [Console]::CursorTop) }
    else { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() }
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
