# Show-DFCliHelp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Show-DFCliHelp` helper (aliases `clh` / `clhp`) that runs an external CLI tool's help, auto-detecting the help flag when not given, caching the discovery, and colorizing the output like `hm`.

**Architecture:** Three new units plus a mock seam. A pure colorizer (`Format-DFCliHelpText`), a flag detector with a JSON cache (`Resolve-DFCliHelpFlag`), a thin mockable command-runner (`Invoke-DFCommandCapture`), and the public orchestrator (`Show-DFCliHelp`) plus its paged wrapper (`Show-DFCliHelpPaged`). The orchestrator wires them together; the privates do the work.

**Tech Stack:** PowerShell 7+, Pester 5. ANSI VT escape sequences. JSON cache under `$XDG_CACHE_HOME/dotforge`.

---

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `Private/Invoke-DFCommandCapture.ps1` | Create | Run `& <cmd> <args> 2>&1`, return `{ Text; ExitCode }`. Mock seam (mirrors `Invoke-DFFzf`). |
| `Private/Format-DFCliHelpText.ps1` | Create | Pure text→text colorizer (headers + faint flag tint). |
| `Private/Resolve-DFCliHelpFlag.ps1` | Create | Detect working help flag; read/write flag cache. |
| `Public/DFHelpers.Help.ps1` | Modify (append) | `Show-DFCliHelp` + `Show-DFCliHelpPaged` + `clh`/`clhp` aliases. |
| `DotForge.psd1` | Modify | Export the two functions + two aliases. |
| `tests/Invoke-DFCommandCapture.Tests.ps1` | Create | Seam tests. |
| `tests/Format-DFCliHelpText.Tests.ps1` | Create | Colorizer unit tests. |
| `tests/Resolve-DFCliHelpFlag.Tests.ps1` | Create | Detection + cache tests. |
| `tests/Show-DFCliHelp.Tests.ps1` | Create | Orchestration tests. |
| `README.md` | Modify | Document `clh`/`clhp`. |
| `examples/02-standard.ps1` | Modify | Mention in a profile example. |

> **Note (beyond spec):** `Invoke-DFCommandCapture` is an added internal testability seam. The spec described running `& $cmd $flag` inline; isolating it in a private wrapper lets `Resolve-DFCliHelpFlag` and `Show-DFCliHelp` be tested without spawning real processes, exactly as `Invoke-DFPicker` uses `Invoke-DFFzf` (documented in CLAUDE.md "Key Design Decisions").

---

## Task 1: Command-capture seam (`Invoke-DFCommandCapture`)

**Files:**
- Create: `Private/Invoke-DFCommandCapture.ps1`
- Test: `tests/Invoke-DFCommandCapture.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/Invoke-DFCommandCapture.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
}

Describe 'Invoke-DFCommandCapture' {
    It 'captures stdout text and a zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'echo', 'dotforge-capture-test')
        $r.Text     | Should -Match 'dotforge-capture-test'
        $r.ExitCode | Should -Be 0
    }

    It 'reports a non-zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'exit', '3')
        $r.ExitCode | Should -Be 3
    }

    It 'returns an object with Text and ExitCode properties' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'echo', 'x')
        $r.PSObject.Properties.Name | Should -Contain 'Text'
        $r.PSObject.Properties.Name | Should -Contain 'ExitCode'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Invoke-DFCommandCapture.Tests.ps1 -Output Detailed"`
Expected: FAIL — "The term 'Invoke-DFCommandCapture' is not recognized".

- [ ] **Step 3: Write minimal implementation**

Create `Private/Invoke-DFCommandCapture.ps1`:

```powershell
#Requires -Version 7.0

function Invoke-DFCommandCapture {
    <#
    .SYNOPSIS
        Private seam — runs an external command and returns its combined output + exit code.
    .DESCRIPTION
        Exists so tests can mock command execution without spawning a real process
        (mirrors the Invoke-DFFzf wrapper). Runs `& $Name @Arguments 2>&1`, joins the
        result into one string, and returns it alongside $LASTEXITCODE.
    .PARAMETER Name
        The executable or command to run.
    .PARAMETER Arguments
        Arguments to pass to the command.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string[]]$Arguments = @()
    )
    $global:LASTEXITCODE = 0
    $text = (& $Name @Arguments 2>&1 | Out-String)
    [pscustomobject]@{
        Text     = $text
        ExitCode = $LASTEXITCODE
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Invoke-DFCommandCapture.Tests.ps1 -Output Detailed"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Private/Invoke-DFCommandCapture.ps1 tests/Invoke-DFCommandCapture.Tests.ps1
git commit -m "feat: add Invoke-DFCommandCapture seam for mockable CLI execution"
```

---

## Task 2: Pure colorizer (`Format-DFCliHelpText`)

**Files:**
- Create: `Private/Format-DFCliHelpText.ps1`
- Test: `tests/Format-DFCliHelpText.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/Format-DFCliHelpText.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Format-DFCliHelpText.ps1"
    $script:HEADER = "`e[1;33m"
    $script:FAINT  = "`e[2m"
    $script:RESET  = "`e[0m"
}

Describe 'Format-DFCliHelpText' {
    It 'returns text unchanged when Color is false' {
        $t = "USAGE`n  -f  do it"
        Format-DFCliHelpText -Text $t -Color $false | Should -BeExactly $t
    }

    It 'returns empty string unchanged' {
        Format-DFCliHelpText -Text '' -Color $true | Should -BeExactly ''
    }

    It 'colors an ALL-CAPS header at start of file' {
        $out = Format-DFCliHelpText -Text "USAGE`nstuff" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "$HEADER`USAGE$RESET"
    }

    It 'colors an ALL-CAPS header preceded by a blank line' {
        $out = Format-DFCliHelpText -Text "intro`n`nGLOBAL OPTIONS`nx" -Color $true
        ($out -split "`n")[2] | Should -BeExactly "$HEADER`GLOBAL OPTIONS$RESET"
    }

    It 'colors a header ending in a colon' {
        $out = Format-DFCliHelpText -Text "Options:`n  -h" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "$HEADER`Options:$RESET"
    }

    It 'does NOT color an indented colon line' {
        $out = Format-DFCliHelpText -Text "intro`n`n  Options:`n" -Color $true
        ($out -split "`n")[2] | Should -BeExactly '  Options:'
    }

    It 'does NOT color a header-looking line that is not preceded by a blank line' {
        $out = Format-DFCliHelpText -Text "foo`nBAR" -Color $true
        ($out -split "`n")[1] | Should -BeExactly 'BAR'
    }

    It 'faintly tints only the flag portion of an option line' {
        $out = Format-DFCliHelpText -Text "  -f, --force   overwrite" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "  $FAINT-f, --force`e[22m   overwrite"
    }

    It 'tints a lone flag with no description' {
        $out = Format-DFCliHelpText -Text "  --version" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "  $FAINT--version`e[22m"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Format-DFCliHelpText.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `Private/Format-DFCliHelpText.ps1`:

```powershell
#Requires -Version 7.0

function Format-DFCliHelpText {
    <#
    .SYNOPSIS
        Pure colorizer for external CLI help text. Returns the (optionally) colorized text.
    .DESCRIPTION
        Adds bold-yellow to section headers and a faint tint to option flags. Headers are
        non-indented lines, preceded by a blank line or start-of-file, that are ALL-CAPS or
        end in a colon. Flag tinting applies to indented option lines and covers only the
        flag portion before the description gap. With Color = $false the text is returned
        unchanged (NO_COLOR / non-VT passthrough).
    .PARAMETER Text
        The raw help text to colorize.
    .PARAMETER Color
        When false, returns Text unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory, Position = 1)]
        [bool]$Color
    )
    if (-not $Color -or [string]::IsNullOrEmpty($Text)) { return $Text }

    $header   = "`e[1;33m"
    $reset    = "`e[0m"
    $faint    = "`e[2m"
    $faintOff = "`e[22m"

    $lines = $Text -split "`r?`n", -1
    $prevBlank = $true   # start-of-file counts as "preceded by a blank line"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $isBlank = [string]::IsNullOrWhiteSpace($line)

        if (-not $isBlank -and $prevBlank -and $line -notmatch '^\s') {
            if ($line -cmatch '^[A-Z][A-Z0-9 ./_-]+$' -or $line -match '^\S.*:\s*$') {
                $lines[$i] = "$header$line$reset"
                $prevBlank = $isBlank
                continue
            }
        }

        if ($line -match '^\s+-') {
            $m = [regex]::Match($line, '^(\s+)(\S.*?)(\s{2,}.*)?$')
            if ($m.Success) {
                $indent = $m.Groups[1].Value
                $flags  = $m.Groups[2].Value
                $rest   = $m.Groups[3].Value
                $lines[$i] = "$indent$faint$flags$faintOff$rest"
            }
        }

        $prevBlank = $isBlank
    }

    return ($lines -join "`n")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Format-DFCliHelpText.Tests.ps1 -Output Detailed"`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Private/Format-DFCliHelpText.ps1 tests/Format-DFCliHelpText.Tests.ps1
git commit -m "feat: add Format-DFCliHelpText pure colorizer for CLI help"
```

---

## Task 3: Flag detection + cache (`Resolve-DFCliHelpFlag`)

**Files:**
- Create: `Private/Resolve-DFCliHelpFlag.ps1`
- Test: `tests/Resolve-DFCliHelpFlag.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/Resolve-DFCliHelpFlag.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCliHelpFlag.ps1"
}

Describe 'Resolve-DFCliHelpFlag' {
    BeforeEach {
        $script:SavedCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
    }

    It 'returns the first candidate that produces help-looking output' {
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n  thing`n  more`n  lines"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '--help'
    }

    It 'rejects an unknown-option error and moves to the next candidate' {
        Mock Invoke-DFCommandCapture {
            param($Name, $Arguments)
            if ($Arguments[0] -eq '--help') {
                [pscustomobject]@{ Text = "error: unknown option '--help'"; ExitCode = 1 }
            } else {
                [pscustomobject]@{ Text = "Usage:`n  demo`n  -x do"; ExitCode = 0 }
            }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-help'
    }

    It 'tries -h last' {
        $script:tried = @()
        Mock Invoke-DFCommandCapture {
            param($Name, $Arguments)
            $script:tried += $Arguments[0]
            if ($Arguments[0] -eq '-h') {
                [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
            } else {
                [pscustomobject]@{ Text = "error: unrecognized flag"; ExitCode = 1 }
            }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-h'
        $script:tried[-1] | Should -Be '-h'
        $script:tried[0]  | Should -Be '--help'
    }

    It 'writes the discovered flag to the cache' {
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Out-Null
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge/cli-help-flags.json'
        Test-Path $cacheFile | Should -BeTrue
        (Get-Content $cacheFile -Raw | ConvertFrom-Json).demo | Should -Be '--help'
    }

    It 'returns the cached flag without running the command' {
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '{ "demo": "-?" }' | Set-Content (Join-Path $cacheDir 'cli-help-flags.json')
        Mock Invoke-DFCommandCapture { throw 'should not run' }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-?'
        Should -Invoke Invoke-DFCommandCapture -Times 0
    }

    It 're-guesses when -Force is passed even with a cache entry' {
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '{ "demo": "-?" }' | Set-Content (Join-Path $cacheDir 'cli-help-flags.json')
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' -Force | Should -Be '--help'
        Should -Invoke Invoke-DFCommandCapture -Times 1
    }

    It 'returns $null when every candidate produces empty output' {
        Mock Invoke-DFCommandCapture { [pscustomobject]@{ Text = ''; ExitCode = 1 } }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Resolve-DFCliHelpFlag.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `Private/Resolve-DFCliHelpFlag.ps1`:

```powershell
#Requires -Version 7.0

function Resolve-DFCliHelpFlag {
    <#
    .SYNOPSIS
        Detects the help flag for an external command and caches the result.
    .DESCRIPTION
        Returns a cached flag from $XDG_CACHE_HOME/dotforge/cli-help-flags.json when present
        (unless -Force). Otherwise tries --help, -help, -?, help, -h (in that order; -h last
        because it collides with real flags) and accepts the first candidate whose output
        looks like help and is not an unknown-option error, caching the winner. Returns the
        best-output candidate uncached when none validate cleanly, or $null when every
        candidate produced no output.
    .PARAMETER Name
        The command name to resolve a help flag for.
    .PARAMETER Force
        Ignore (and overwrite) any cached flag and re-detect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [switch]$Force
    )

    $cacheDir  = if ($Env:XDG_CACHE_HOME) { Join-Path $Env:XDG_CACHE_HOME 'dotforge' } else { $null }
    $cacheFile = if ($cacheDir) { Join-Path $cacheDir 'cli-help-flags.json' } else { $null }

    $cache = @{}
    if ($cacheFile -and (Test-Path $cacheFile)) {
        try {
            $loaded = Get-Content $cacheFile -Raw | ConvertFrom-Json -AsHashtable
            if ($loaded) { $cache = $loaded }
        } catch { $cache = @{} }
    }
    if (-not $Force -and $cache.ContainsKey($Name)) {
        return $cache[$Name]
    }

    $candidates = '--help', '-help', '-?', 'help', '-h'
    $best = $null
    $bestLines = -1

    foreach ($flag in $candidates) {
        $text = (Invoke-DFCommandCapture -Name $Name -Arguments @($flag)).Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $isError = ($text -match '(?i)(unknown|unrecognized|invalid|unexpected)\b.{0,30}\b(option|flag|argument|switch|command)') -or
                   ($text -match '(?im)^error\b')
        $lineCount = ($text -split "`r?`n").Where({ $_.Trim() }).Count
        $looksHelp = ($lineCount -ge 3) -or
                     ($text -match '(?im)^\s*(usage|options|commands|flags|synopsis)\b')

        if ($looksHelp -and -not $isError) {
            if ($cacheFile) {
                New-DFDirectory $cacheDir
                $cache[$Name] = $flag
                $cache | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
            }
            return $flag
        }

        if ($lineCount -gt $bestLines) { $bestLines = $lineCount; $best = $flag }
    }

    return $best
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Resolve-DFCliHelpFlag.Tests.ps1 -Output Detailed"`
Expected: PASS (7 tests). Note: the last test ("returns `$null`") passes because all candidates return empty, so `$best` stays `$null`.

- [ ] **Step 5: Commit**

```bash
git add Private/Resolve-DFCliHelpFlag.ps1 tests/Resolve-DFCliHelpFlag.Tests.ps1
git commit -m "feat: add Resolve-DFCliHelpFlag with validate-output detection and cache"
```

---

## Task 4: Orchestrator + paged wrapper + aliases (`Show-DFCliHelp`)

**Files:**
- Modify: `Public/DFHelpers.Help.ps1` (append at end of file)
- Test: `tests/Show-DFCliHelp.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/Show-DFCliHelp.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
    . "$PSScriptRoot/../Private/Format-DFCliHelpText.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCliHelpFlag.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Help.ps1"
}

Describe 'Show-DFCliHelp' {
    BeforeEach {
        Mock Get-Command { [pscustomobject]@{ Name = 'demo' } } -ParameterFilter { $Name -eq 'demo' }
        Mock Invoke-DFCommandCapture { [pscustomobject]@{ Text = "USAGE`n body"; ExitCode = 0 } }
        Mock Resolve-DFCliHelpFlag { '--help' }
        Mock Format-DFCliHelpText { 'COLORIZED' }
        Mock Invoke-DFWithPager {}
    }

    It 'warns and returns when the command is not found' {
        Mock Get-Command { $null }
        Show-DFCliHelp -Name 'nope' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
    }

    It 'uses an explicit -Flag and does not call the resolver' {
        Show-DFCliHelp -Name 'demo' -Flag '--tree' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
        Should -Invoke Invoke-DFCommandCapture -ParameterFilter { $Arguments[0] -eq '--tree' }
    }

    It 'calls the resolver when no flag is given' {
        Show-DFCliHelp -Name 'demo' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 1
    }

    It 'writes colorized output to the pipeline by default' {
        Show-DFCliHelp -Name 'demo' | Should -Be 'COLORIZED'
        Should -Invoke Invoke-DFWithPager -Times 0
    }

    It 'routes through the pager when -Paged is set' {
        Show-DFCliHelp -Name 'demo' -Paged | Out-Null
        Should -Invoke Invoke-DFWithPager -Times 1
    }

    It 'warns when the resolver returns no flag' {
        Mock Resolve-DFCliHelpFlag { $null }
        Show-DFCliHelp -Name 'demo' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-DFCommandCapture -Times 0
    }

    It 'Show-DFCliHelpPaged delegates with -Paged' {
        Show-DFCliHelpPaged -Name 'demo' | Out-Null
        Should -Invoke Invoke-DFWithPager -Times 1
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Show-DFCliHelp.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Show-DFCliHelp` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `Public/DFHelpers.Help.ps1` (after the final `Set-Alias -Name fh ...` line):

```powershell

function Show-DFCliHelp {
    <#
    .SYNOPSIS
        Displays colorized help for an external CLI tool, auto-detecting the help flag.
    .DESCRIPTION
        Runs an external command with a help flag and colorizes the output: bold-yellow
        section headers and a faint tint on option flags. When -Flag is omitted the help
        flag is auto-detected (and cached) via Resolve-DFCliHelpFlag. Colorization is
        suppressed when $Env:NO_COLOR is set or the terminal lacks VT support. With -Paged
        the result is sent through Invoke-DFWithPager.
    .PARAMETER Name
        The external command to show help for (e.g. git, eza, docker).
    .PARAMETER Flag
        Explicit help flag to use. Skips auto-detection and caching.
    .PARAMETER Paged
        Send the colorized output through the configured pager.
    .PARAMETER Force
        Re-detect the help flag, ignoring and overwriting any cached value.
    .EXAMPLE
        Show-DFCliHelp eza
        Detects eza's help flag, colorizes the help, prints it to the terminal.
    .EXAMPLE
        clh git --tree
        Uses the clh alias; -Flag '--tree' style positional is shown via Show-DFCliHelp git -Flag --tree.
    .EXAMPLE
        clhp docker
        Shows colorized docker help through the pager.
    .OUTPUTS
        System.String — the colorized help text (unless -Paged, which writes to the pager).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Flag,

        [switch]$Paged,

        [switch]$Force
    )

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Warning "Show-DFCliHelp: '$Name' was not found on PATH."
        return
    }

    if ($PSBoundParameters.ContainsKey('Flag')) {
        $useFlag = $Flag
    } else {
        $useFlag = Resolve-DFCliHelpFlag -Name $Name -Force:$Force
    }

    if ($null -eq $useFlag) {
        Write-Warning "Show-DFCliHelp: could not determine a help flag for '$Name'."
        return
    }

    $raw = (Invoke-DFCommandCapture -Name $Name -Arguments @($useFlag)).Text
    $color = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    $out = Format-DFCliHelpText -Text $raw -Color $color

    if ($Paged) { $out | Invoke-DFWithPager } else { $out }
}
Set-Alias -Name clh -Value Show-DFCliHelp -Scope Global -Force

function Show-DFCliHelpPaged {
    <#
    .SYNOPSIS
        Paged variant of Show-DFCliHelp — colorized CLI help through the pager.
    .DESCRIPTION
        Thin wrapper that calls Show-DFCliHelp with -Paged. Exists as a function (not an
        alias) because a PowerShell alias cannot inject the -Paged argument.
    .PARAMETER Name
        The external command to show help for.
    .PARAMETER Flag
        Explicit help flag to use. Skips auto-detection.
    .PARAMETER Force
        Re-detect the help flag, ignoring any cached value.
    .EXAMPLE
        Show-DFCliHelpPaged eza
        Shows colorized eza help through the configured pager.
    .EXAMPLE
        clhp git
        Same as above using the clhp alias.
    .OUTPUTS
        None. Output is written to the pager.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Flag,

        [switch]$Force
    )
    $params = @{ Name = $Name; Paged = $true }
    if ($PSBoundParameters.ContainsKey('Flag')) { $params.Flag = $Flag }
    if ($Force) { $params.Force = $true }
    Show-DFCliHelp @params
}
Set-Alias -Name clhp -Value Show-DFCliHelpPaged -Scope Global -Force
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/Show-DFCliHelp.Tests.ps1 -Output Detailed"`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Public/DFHelpers.Help.ps1 tests/Show-DFCliHelp.Tests.ps1
git commit -m "feat: add Show-DFCliHelp/Show-DFCliHelpPaged (clh/clhp)"
```

---

## Task 5: Export from manifest

**Files:**
- Modify: `DotForge.psd1`

- [ ] **Step 1: Add the functions to FunctionsToExport**

In `DotForge.psd1`, locate the `# General Helpers — Help & Discovery` block under `FunctionsToExport` and add the two functions after `'Invoke-DFHelp',`:

```powershell
        # General Helpers — Help & Discovery
        'Invoke-DFHelp',
        'Show-DFCliHelp',
        'Show-DFCliHelpPaged',
        'Select-DFCommand',
```

- [ ] **Step 2: Add the aliases to AliasesToExport**

In the same file, add `'clh', 'clhp'` to the `AliasesToExport` array, on the line with the other help aliases:

```powershell
        'hm', 'clh', 'clhp', 'fcmd', 'fverb', 'fmod', 'fh',
```

- [ ] **Step 3: Verify the module loads and exports them**

Run:
```
pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Command -Module DotForge -Name Show-DFCliHelp,Show-DFCliHelpPaged,clh,clhp | Select-Object Name,CommandType"
```
Expected: four rows — `Show-DFCliHelp` (Function), `Show-DFCliHelpPaged` (Function), `clh` (Alias), `clhp` (Alias).

- [ ] **Step 4: Verify comment-based help renders fully**

Run:
```
pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Help Show-DFCliHelp -Full | Out-String | Select-String -Pattern 'SYNOPSIS','PARAMETER','EXAMPLE','OUTPUTS'"
```
Expected: matches for SYNOPSIS, PARAMETER, EXAMPLE, OUTPUTS (help block is complete).

- [ ] **Step 5: Commit**

```bash
git add DotForge.psd1
git commit -m "feat: export Show-DFCliHelp/Show-DFCliHelpPaged and clh/clhp aliases"
```

---

## Task 6: Documentation

**Files:**
- Modify: `README.md`
- Modify: `examples/02-standard.ps1`

- [ ] **Step 1: Locate the General Helpers reference in README**

Run: `pwsh -NoProfile -Command "Select-String -Path README.md -Pattern 'hm','Invoke-DFHelp' -Context 1,1"`
Expected: shows the help-helpers table/section where `hm` is documented.

- [ ] **Step 2: Add clh / clhp to the README help section**

In `README.md`, in the same table or list where `hm` (`Invoke-DFHelp`) is described, add two rows mirroring its format. Example (adapt columns to the existing table shape):

```markdown
| `clh`  | `Show-DFCliHelp`      | Colorized help for an external CLI tool (auto-detects the help flag) |
| `clhp` | `Show-DFCliHelpPaged` | Same as `clh`, through the pager                                     |
```

Add a short usage example near the existing `hm` example:

```markdown
```powershell
clh eza            # colorized eza help (flag auto-detected + cached)
clh git --tree     # force a specific flag
clhp docker        # colorized docker help through the pager
```
```

- [ ] **Step 3: Mention in the standard profile example**

In `examples/02-standard.ps1`, find the comment block that lists helper aliases (near the General Helpers registration) and add a line noting `clh`/`clhp`. If there is an inline comment enumerating help aliases like `hm`, append:

```powershell
# clh / clhp — colorized help for external CLI tools (eza, git, docker, ...)
```

- [ ] **Step 4: Run the full test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester ./tests/ -Output Minimal"`
Expected: all tests pass (prior 222 + the new Invoke-DFCommandCapture, Format-DFCliHelpText, Resolve-DFCliHelpFlag, Show-DFCliHelp tests).

- [ ] **Step 5: Smoke-test against a real tool**

Run (if `eza` is installed): `pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; clh eza"`
Expected: eza help prints with a bold-yellow header line and faint flags; second run is faster (flag cached). Inspect the cache:
`pwsh -NoProfile -Command "Get-Content \$Env:XDG_CACHE_HOME/dotforge/cli-help-flags.json"`

- [ ] **Step 6: Commit**

```bash
git add README.md examples/02-standard.ps1
git commit -m "docs: document clh/clhp colorized CLI help helpers"
```

---

## Self-Review Notes

- **Spec coverage:** flag detection (Task 3), validate-output heuristic + `-h` last (Task 3), per-command JSON cache + `-Force` (Task 3), header rule + faint flag tint + NO_COLOR gate (Task 2), `Show-DFCliHelp`/`clh`/`clhp` with paged variant (Task 4), manifest exports (Task 5), edge cases — not-found + cache-unset + failed-guess (Tasks 3 & 4), docs + tests (Tasks 2–6). The added `Invoke-DFCommandCapture` seam (Task 1) realizes the spec's `& $cmd $flag` step in a mockable form.
- **CHANGELOG:** add an entry under `[Unreleased] / Added` during Task 6 if desired (not strictly required by the spec; the repo keeps a changelog).
- **Naming consistency:** functions `Show-DFCliHelp`, `Show-DFCliHelpPaged`; privates `Invoke-DFCommandCapture`, `Format-DFCliHelpText`, `Resolve-DFCliHelpFlag`; aliases `clh`, `clhp`; cache `cli-help-flags.json` — used identically across all tasks.
