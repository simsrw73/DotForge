#Requires -Version 7.0
# Shared logic for the documentation checks (tests/Docs.Examples.Tests.ps1 and
# tests/Docs.Links.Tests.ps1). Author-time only: the module never loads this file.
#
# Code-block modes. The HTML comment on the line before a ```powershell fence
# sets how the block is checked; every block must parse regardless.
#   (none)               run it in a sandbox; it must exit 0 with nothing on stderr
#   <!-- fragment -->    a deliberately partial snippet: parse only
#   <!-- interactive --> needs a person at the keyboard (fzf, prompts): parse only
#   <!-- network -->     reads from the network (catalog lookups, downloads into
#                        the sandbox): parse only, run as well when
#                        $Env:DF_DOCS_NETWORK = '1'. Never use it for installs.
#   <!-- system -->      changes the machine outside the sandbox (installs,
#                        elevation, scheduled tasks, global git config,
#                        clipboard, coreutils-manager): parse only, never run
#
# Expected output. A ```text fence right after a run block is compared with the
# block's stdout (ANSI stripped, trailing whitespace ignored). A line that is
# exactly '...' matches any number of lines; '...' inside a line matches any text
# on that line (machine-specific paths, versions). Put <!-- output: varies -->
# before the ```text fence to show illustrative output that is not compared.

$script:DFDocFence = '^(\s*)```(\w*)\s*$'

function Get-DFDocCodeBlock {
    <#
    .SYNOPSIS
        Returns every fenced code block in a Markdown file, with its mode and any expected output.
    .PARAMETER Path
        The Markdown file.
    .OUTPUTS
        PSCustomObject with File, Line, Lang, Code, Mode, Expected (string or $null), OutputVaries.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $lines = (Get-Content $Path -Raw) -replace '\r', '' -split '\n'
    $blocks = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match $script:DFDocFence) {
            $lang = $Matches[2]
            $start = $i
            $body = [System.Collections.Generic.List[string]]::new()
            $i++
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*```\s*$') { $body.Add($lines[$i]); $i++ }
            # The marker is the nearest non-blank line above the fence.
            $j = $start - 1
            while ($j -ge 0 -and -not $lines[$j].Trim()) { $j-- }
            $marker = if ($j -ge 0 -and $lines[$j] -match '^\s*<!--\s*(fragment|interactive|network|system)\s*-->\s*$') { $Matches[1] } else { $null }
            $blocks.Add([pscustomobject]@{
                File = $Path; Line = $start + 1; Lang = $lang; Code = ($body -join "`n")
                Mode = $marker ?? 'run'; Expected = $null; OutputVaries = $false; EndLine = $i
            })
        }
        $i++
    }
    # Pair each powershell block with a ```text block that directly follows it.
    for ($b = 0; $b -lt $blocks.Count - 1; $b++) {
        $cur = $blocks[$b]; $next = $blocks[$b + 1]
        if ($cur.Lang -ne 'powershell' -or $next.Lang -ne 'text') { continue }
        # Lines strictly between this block's closing fence (index EndLine) and the
        # next opening fence (index Line - 1). Guard the empty case: PowerShell's
        # a..b counts down when b < a.
        $from = $cur.EndLine + 1; $to = $next.Line - 2
        # @() around the whole if: assigning an if-expression unwraps a one-element
        # array to a bare string, and then [0] would be its first character.
        $between = @(if ($to -ge $from) { $lines[$from..$to] | Where-Object { $_.Trim() } })
        $varies = $false
        if ($between.Count -eq 1 -and $between[0] -match '^\s*<!--\s*output:\s*varies\s*-->\s*$') { $varies = $true }
        elseif ($between.Count -gt 0) { continue }
        $cur.Expected = $next.Code
        $cur.OutputVaries = $varies
    }
    $blocks | Where-Object Lang -EQ 'powershell'
}

function New-DFDocModuleCopy {
    <#
    .SYNOPSIS
        Copies the module's runtime files into <Destination>\DotForge and returns <Destination>.
    .DESCRIPTION
        A copy rather than a link to the repo, so cleaning up a sandbox can never
        reach the working tree. Only what the module loads is copied.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER Destination
        Folder to put the DotForge module folder in; add it to PSModulePath.
    .OUTPUTS
        System.String.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Destination)
    $target = Join-Path $Destination 'DotForge'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($item in 'DotForge.psd1', 'DotForge.psm1', 'Shared', 'Public', 'Private', 'Modules', 'Tools', 'data') {
        Copy-Item -Path (Join-Path $RepoRoot $item) -Destination $target -Recurse -Force
    }
    $Destination
}

function Get-DFDocToolVariable {
    <#
    .SYNOPSIS
        Returns every environment variable name a tool record manages (its xdg.vars and env keys).
    .DESCRIPTION
        The sandbox removes these so a value persisted in your user environment
        (e.g. MDV_CONFIG_PATH pointing at your real config folder) can't lead an
        example to read or write outside the throwaway home.
    .PARAMETER RepoRoot
        The repository root.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $names = foreach ($f in Get-ChildItem (Join-Path $RepoRoot 'Tools') -Filter '*.json') {
        $t = Get-Content $f.FullName -Raw | ConvertFrom-Json
        $xdg = $t.PSObject.Properties['xdg']?.Value
        $vars = if ($xdg) { $xdg.PSObject.Properties['vars']?.Value }
        if ($vars) { $vars.PSObject.Properties.Name }
        $env = $t.PSObject.Properties['env']?.Value
        if ($env) { $env.PSObject.Properties.Name }
    }
    @($names | Sort-Object -Unique)
}

function Invoke-DFDocExample {
    <#
    .SYNOPSIS
        Runs one code block in a fresh pwsh with a throwaway home directory.
    .DESCRIPTION
        The child gets: USERPROFILE/HOME set to a new empty folder (so $HOME and
        every XDG default land there), no XDG_* variables and none of the
        -RemoveVariable names (pass Get-DFDocToolVariable), GIT_CONFIG_GLOBAL
        pointing at an empty file in that folder (so nothing can touch your real
        git config), NO_COLOR=1, no Pager, an already-closed stdin, and the
        module copy first on PSModulePath. The working directory is the
        sandbox's 'work' folder.
    .PARAMETER Code
        The PowerShell source to run.
    .PARAMETER ModulesRoot
        Folder holding the DotForge module copy (New-DFDocModuleCopy).
    .PARAMETER SandboxRoot
        Parent folder for this run's sandbox.
    .PARAMETER RemoveVariable
        More environment variable names to remove from the child.
    .PARAMETER TimeoutSeconds
        Kill the child after this long. Default: 120.
    .OUTPUTS
        PSCustomObject with ExitCode, StdOut, StdErr, TimedOut.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$ModulesRoot,
        [Parameter(Mandatory)][string]$SandboxRoot,
        [string[]]$RemoveVariable = @(),
        [int]$TimeoutSeconds = 120
    )
    $box = Join-Path $SandboxRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $home_ = Join-Path $box 'home'
    $work = Join-Path $box 'work'
    New-Item -ItemType Directory -Path $home_, $work -Force | Out-Null
    $gitConfig = Join-Path $home_ '.gitconfig'
    New-Item -ItemType File -Path $gitConfig -Force | Out-Null
    $script = Join-Path $box 'example.ps1'
    # The child writes in its console's code page (437 on many Windows
    # terminals, which turns an em dash into '-') while we read UTF-8: make it
    # write UTF-8. Prefixed to the first line so line numbers don't shift.
    $prefix = '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
    Set-Content -Path $script -Value ($prefix + $Code) -Encoding utf8

    $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', $script) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $work
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # A closed stdin, so nothing in an example can block reading the test run's
    # own stdin (an inherited pipe that never closes made glow hang).
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($k in @($psi.Environment.Keys)) {
        if ($k -like 'XDG_*' -or $k -in 'Pager', 'PAGER', 'DFConfig' -or $k -in $RemoveVariable) { $psi.Environment.Remove($k) | Out-Null }
    }
    $psi.Environment['USERPROFILE'] = $home_
    $psi.Environment['HOME'] = $home_
    $psi.Environment['GIT_CONFIG_GLOBAL'] = $gitConfig
    $psi.Environment['NO_COLOR'] = '1'
    $psi.Environment['PSModulePath'] = $ModulesRoot + [IO.Path]::PathSeparator + $psi.Environment['PSModulePath']

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { try { $proc.Kill($true) } catch { } ; $proc.WaitForExit() }
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $out.Result
        StdErr   = $err.Result
        TimedOut = $timedOut
    }
}

function Test-DFDocLine([string]$Pattern, [string]$Line) {
    # Exact, case-sensitive match, except that '...' matches any run of text.
    if ($Pattern -notlike '*...*') { return $Pattern -ceq $Line }
    $rx = '^' + (($Pattern -split '\.\.\.' | ForEach-Object { [regex]::Escape($_) }) -join '.*') + '$'
    $Line -cmatch $rx
}

function Compare-DFDocOutput {
    <#
    .SYNOPSIS
        Compares actual output with a doc's expected output; returns $null on a match, else a message.
    .PARAMETER Expected
        The expected text. A line that is exactly '...' matches any number of
        lines; '...' inside a line matches any text on that line.
    .PARAMETER Actual
        The captured stdout.
    .OUTPUTS
        System.String or $null.
    #>
    param([string]$Expected, [string]$Actual)
    $norm = { param($t) @((($t -replace '\x1b\[[0-9;?]*[A-Za-z]', '') -replace '\r', '').TrimEnd() -split '\n' | ForEach-Object TrimEnd) }
    $exp = & $norm $Expected
    $act = & $norm $Actual
    # Leading blank lines in actual output are noise from the host.
    while ($act.Count -and -not $act[0]) { $act = @($act | Select-Object -Skip 1) }

    # Glob-style match with '...' as a multi-line wildcard (memoized recursion).
    $memo = @{}
    $match = $null
    $match = {
        param([int]$e, [int]$a)
        $key = "$e,$a"
        if ($memo.ContainsKey($key)) { return $memo[$key] }
        $r = if ($e -eq $exp.Count) { $a -eq $act.Count }
             elseif ($exp[$e] -eq '...') { (& $match ($e + 1) $a) -or ($a -lt $act.Count -and (& $match $e ($a + 1))) }
             else { $a -lt $act.Count -and (Test-DFDocLine $exp[$e] $act[$a]) -and (& $match ($e + 1) ($a + 1)) }
        $memo[$key] = $r
        $r
    }
    if (& $match 0 0) { return $null }
    "Output differs.`n--- expected ---`n$($exp -join "`n")`n--- actual ---`n$($act -join "`n")"
}

function Get-DFDocHeadingSlug {
    <#
    .SYNOPSIS
        Returns the GitHub anchor slugs for every heading in a Markdown file.
    .PARAMETER Path
        The Markdown file.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$Path)
    $seen = @{}
    $inFence = $false
    foreach ($line in ((Get-Content $Path -Raw) -replace '\r', '' -split '\n')) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence -or $line -notmatch '^#{1,6}\s+(.+?)\s*#*\s*$') { continue }
        $text = $Matches[1] -replace '`', '' -replace '\[([^\]]*)\]\([^)]*\)', '$1'
        $slug = ($text.ToLowerInvariant() -replace '[^\p{L}\p{Nd} _-]', '') -replace ' ', '-'
        if ($seen.ContainsKey($slug)) { $seen[$slug]++; "$slug-$($seen[$slug])" } else { $seen[$slug] = 0; $slug }
    }
    # Explicit anchors: <a id="..."></a>
    foreach ($m in [regex]::Matches((Get-Content $Path -Raw), '<a\s+(?:id|name)="([^"]+)"')) { $m.Groups[1].Value }
}

function Get-DFDocLink {
    <#
    .SYNOPSIS
        Returns every relative link and image in a Markdown file (outside code), resolved against the file.
    .PARAMETER Path
        The Markdown file.
    .OUTPUTS
        PSCustomObject with File, Line, Target, TargetPath (or $null for same-page), Anchor.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path $Path -Parent
    $lines = (Get-Content $Path -Raw) -replace '\r', '' -split '\n'
    $inFence = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $line = $lines[$n]
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $line = $line -replace '`[^`]*`', ''   # links inside code spans aren't links
        $targets = @(
            [regex]::Matches($line, '\]\(([^)\s]+)(?:\s+"[^"]*")?\)') | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches($line, '<img\s[^>]*src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        )
        foreach ($t in $targets) {
            if ($t -match '^(https?:|mailto:)') { continue }
            $file, $anchor = $t -split '#', 2
            [pscustomobject]@{
                File       = $Path
                Line       = $n + 1
                Target     = $t
                TargetPath = if ($file) { [IO.Path]::GetFullPath((Join-Path $dir ([uri]::UnescapeDataString($file)))) } else { $null }
                Anchor     = $anchor
            }
        }
    }
}
