# Package-manager preview reorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the most useful fields (Name, Description, Version, last-updated date where available, Publisher, License, Homepage) to the top of the `wins`/`sins`/`cins` (and `wrm`/`srm`/`crm`, `wup`/`sup`/`cup`) fzf preview panes, by switching fzf's preview shell from `cmd` to `pwsh` and adding a small per-tool field-extraction summary block above each tool's unmodified `show`/`info` output.

**Architecture:** `Tools/fzf.json` sets `--with-shell='pwsh -NoProfile -Command'` in `FZF_DEFAULT_OPTS`, switching every DotForge picker's preview/execute shell from `cmd` to PowerShell 7+. Three new standalone scripts (`Tools/winget.preview.ps1`, `Tools/scoop.preview.ps1`, `Tools/choco.preview.ps1`) each run their tool's real `show`/`info` command, pull ~6 fields out independently via isolated regex (never a generic document reorder — `choco info`'s layout is too irregular for that to be safe), and render them as a summary block via a new shared `Private/Format-DFPreviewSummary.ps1` helper, above the tool's full unmodified output. Because pwsh startup (~230ms) is slower than cmd (~80ms), the existing debounce trick in `winget.ps1`/`scoop.ps1`/`choco.ps1` is rewritten from cmd syntax to `Start-Sleep -Milliseconds 1000;`, and the same debounce is added to three previously-undebounced previews (`posh-git.ps1`, `ripgrep.ps1`, `oh-my-posh.ps1`) so their live-as-you-scroll previews don't gain per-keystroke lag.

**Tech Stack:** PowerShell 7+, Pester 5/6, fzf, winget/scoop/choco CLIs.

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file.
- PowerShell regex on external CLI output: use `-match`/`-replace` with single-quoted patterns (avoid PowerShell backtick-escapes leaking into regex syntax).
- Every public function needs complete comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/`.EXAMPLE`/`.OUTPUTS`); `Format-DFPreviewSummary` is private but gets the same treatment for consistency with the rest of `Private/`.
- Design reference: `docs/superpowers/specs/2026-09-02-package-manager-preview-reorder-design.md`.
- Run tests from `pwsh -NoProfile` to avoid profile interference: `Invoke-Pester tests/<file>.Tests.ps1 -Output Detailed`.

---

### Task 1: Shared preview-summary formatting helper

**Files:**
- Create: `Private/Format-DFPreviewSummary.ps1`
- Test: `tests/Format-DFPreviewSummary.Tests.ps1`

**Interfaces:**
- Produces: `Format-DFPreviewSummary -Fields <ordered [string]->[string]> -Body <string[]>` → `string[]`. `$Fields` values may be `$null`/`''` (meaning "not found"); labels with no value are omitted. Returns `$Body` unchanged if no label has a value. Consumed by Tasks 3-5's `winget.preview.ps1`/`scoop.preview.ps1`/`choco.preview.ps1`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Format-DFPreviewSummary.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Format-DFPreviewSummary.ps1"
}

Describe 'Format-DFPreviewSummary' {
    It 'renders only populated labels, in the given order, above a separator and the body' {
        $fields = [ordered]@{ Name = 'git'; Description = $null; Version = '2.55.0' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('raw line 1', 'raw line 2')
        $result[0] | Should -Be 'Name: git'
        $result[1] | Should -Be 'Version: 2.55.0'
        $result[2] | Should -Be ''
        $result[3] | Should -Match '^-+$'
        $result[4] | Should -Be ''
        $result[5] | Should -Be 'raw line 1'
        $result[6] | Should -Be 'raw line 2'
    }

    It 'skips empty-string values the same as $null' {
        $fields = [ordered]@{ Name = 'git'; Description = '' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('body')
        ($result -join "`n") | Should -Not -Match 'Description'
    }

    It 'falls back to the plain body when no field has a value' {
        $fields = [ordered]@{ Name = $null; Version = '' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('raw', 'output')
        $result | Should -Be @('raw', 'output')
    }

    It 'falls back to the (empty) body when the body itself is empty and nothing matched' {
        $fields = [ordered]@{ Name = $null }
        $result = Format-DFPreviewSummary -Fields $fields -Body @()
        $result | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester tests/Format-DFPreviewSummary.Tests.ps1 -Output Detailed`
Expected: FAIL — `Format-DFPreviewSummary` is not recognized (the file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Private/Format-DFPreviewSummary.ps1`:

```powershell
function Format-DFPreviewSummary {
    <#
    .SYNOPSIS
        Prepends a label/value summary block above a body of fzf preview text.
    .DESCRIPTION
        Given an ordered set of labels to values (a value may be $null or empty
        to mean "not found for this item"), renders only the populated labels as
        "Label: value" lines, followed by a blank line, a separator, another
        blank line, and the original body. If no label has a value, returns the
        body unchanged — used by the winget/scoop/choco preview scripts so a
        tool's undocumented output format changing upstream degrades to plain
        passthrough instead of an error or a garbled summary.
    .PARAMETER Fields
        Ordered dictionary of label -> value, in display order. Null/empty
        values are skipped.
    .PARAMETER Body
        The original preview text, as an array of lines.
    .EXAMPLE
        Format-DFPreviewSummary -Fields ([ordered]@{ Name = 'git'; Version = $null }) -Body @('raw', 'output')
        Renders "Name: git", a separator, then "raw"/"output" — Version is omitted since its value is $null.
    .OUTPUTS
        System.String[] — the combined preview text, one element per line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Body
    )

    $summaryLines = foreach ($label in $Fields.Keys) {
        $value = $Fields[$label]
        if ($value) { "${label}: $value" }
    }

    if (-not $summaryLines) { return $Body }

    @($summaryLines) + '' + ('-' * 40) + '' + $Body
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester tests/Format-DFPreviewSummary.Tests.ps1 -Output Detailed`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add Private/Format-DFPreviewSummary.ps1 tests/Format-DFPreviewSummary.Tests.ps1
git commit -m "$(cat <<'EOF'
feat: add Format-DFPreviewSummary helper for fzf preview summary blocks

Tool-agnostic text formatting: renders only the populated labels from an
ordered field map above a separator and the original body, falling back to
plain passthrough when nothing matched. Shared by the winget/scoop/choco
preview scripts landing in the next few commits.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 2: Switch fzf's preview/execute shell to pwsh

**Files:**
- Modify: `Tools/fzf.json:21`
- Modify: `tests/XdgSplit.Tests.ps1:43-53`

**Interfaces:**
- Produces: every DotForge picker's `--preview`/`--bind execute()` commands now run under `pwsh -NoProfile -Command` instead of `cmd /s/c`. Tasks 3-6 depend on this being in place for their `-Preview` strings to work at the real fzf level (their own unit tests invoke the preview scripts directly and don't depend on this task).

- [ ] **Step 1: Update the exact-match test fixture first (so it fails against the still-unmodified JSON)**

In `tests/XdgSplit.Tests.ps1`, the block at line 43-53 currently reads:

```powershell
        $expectedFzfOpts = @(
            '--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8'
            '--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc'
            '--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8'
            '--exact'
            '--no-sort'
            '--layout=reverse'
            '--border'
            '--cycle'
            '--height 50%'
        ) -join "`n"
```

Change it to add the new option as the final element:

```powershell
        $expectedFzfOpts = @(
            '--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8'
            '--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc'
            '--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8'
            '--exact'
            '--no-sort'
            '--layout=reverse'
            '--border'
            '--cycle'
            '--height 50%'
            "--with-shell='pwsh -NoProfile -Command'"
        ) -join "`n"
```

- [ ] **Step 2: Run the test to verify it now fails**

Run: `Invoke-Pester tests/XdgSplit.Tests.ps1 -Output Detailed`
Expected: FAIL on the test containing `$j.env.FZF_DEFAULT_OPTS | Should -Be $expectedFzfOpts` (around line 54) — the JSON doesn't have the new line yet.

- [ ] **Step 3: Update `Tools/fzf.json`**

Line 21 currently reads:

```json
    "FZF_DEFAULT_OPTS": "--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8\n--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc\n--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8\n--exact\n--no-sort\n--layout=reverse\n--border\n--cycle\n--height 50%",
```

Change it to:

```json
    "FZF_DEFAULT_OPTS": "--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8\n--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc\n--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8\n--exact\n--no-sort\n--layout=reverse\n--border\n--cycle\n--height 50%\n--with-shell='pwsh -NoProfile -Command'",
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester tests/XdgSplit.Tests.ps1 -Output Detailed`
Expected: PASS (all tests in the file, including the one from Step 2 and `'sets FZF_DEFAULT_OPTS from fzf.json env'`).

- [ ] **Step 5: Commit**

```bash
git add Tools/fzf.json tests/XdgSplit.Tests.ps1
git commit -m "$(cat <<'EOF'
feat: switch fzf's preview/execute shell from cmd to pwsh

fzf's undocumented Windows default (verified against fzf 0.74.3's man page:
`cmd /s/c` when $SHELL/--with-shell are unset) runs every picker's
--preview/--bind execute() command through cmd.exe. Set --with-shell in
FZF_DEFAULT_OPTS so they run under PowerShell 7+ instead, needed by the
winget/scoop/choco preview scripts landing next.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 3: winget preview script

**Files:**
- Create: `Tools/winget.preview.ps1`
- Test: `tests/winget.preview.Tests.ps1`
- Modify: `Tools/winget.ps1:41-51,87-97,118-133`

**Interfaces:**
- Consumes: `Format-DFPreviewSummary` (Task 1).
- Produces: `Tools/winget.preview.ps1 -Id <string>` — a standalone script (not a module function) invoked as `& '<path>' <id>`, printing the summary+body text to stdout.

- [ ] **Step 1: Write the failing tests**

Create `tests/winget.preview.Tests.ps1`:

```powershell
BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/winget.preview.ps1'
    # Real `winget show --id Git.Git` output, captured during design.
    $script:GitFixture = @(
        'Found Git [Git.Git]'
        'Version: 2.55.0.3'
        'Publisher: The Git Development Community'
        'Publisher Url: https://gitforwindows.org/'
        'Publisher Support Url: https://github.com/git-for-windows/git/issues'
        'Moniker: git'
        'Description:'
        '  Git is a free and open source distributed version control system designed to handle everything from small to very large projects with speed and efficiency.'
        '  Git for Windows focuses on offering a lightweight, native set of tools that bring the full feature set of the Git SCM to Windows while providing appropriate user interfaces for experienced Git users and novices alike.'
        'Homepage: https://gitforwindows.org/'
        'License: GPL-2.0'
        'License Url: https://github.com/git-for-windows/build-extra/blob/HEAD/LICENSE.txt'
        'Copyright: Copyright (C) 1989, 1991 Free Software Foundation, Inc.'
        'Release Notes:'
        '  Changes since Git for Windows v2.55.0(2) (July 2nd 2026)'
        'Release Notes Url: https://github.com/git-for-windows/git/releases/tag/v2.55.0.windows.3'
        'Documentation:'
        '  Wiki: https://github.com/git-for-windows/git/wiki'
        'Tags:'
        '  git'
        '  vcs'
        'Installer:'
        '  Installer Type: inno'
        '  Installer Url: https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'
        '  Installer SHA256: af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca'
        '  Release Date: 2026-07-14'
        '  Offline Distribution Supported: true'
    )
}

Describe 'winget.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/Publisher/License/Homepage summary above the full output' {
        Mock -CommandName winget -MockWith { $script:GitFixture }
        $result = & $script:ScriptPath -Id 'Git.Git'

        $result[0] | Should -Be 'Name: Git'
        $result[1] | Should -Match "^Description: Git is a free and open source.*novices alike\.$"
        $result[2] | Should -Be 'Version: 2.55.0.3'
        $result[3] | Should -Be 'Last Updated: 2026-07-14'
        $result[4] | Should -Be 'Publisher: The Git Development Community'
        $result[5] | Should -Be 'License: GPL-2.0'
        $result[6] | Should -Be 'Homepage: https://gitforwindows.org/'
        $result[7] | Should -Be ''
        $result[8] | Should -Match '^-+$'
        ($result -join "`n") | Should -Match 'Installer Type: inno'
    }

    It 'omits Last Updated when no Release Date line is present' {
        $fixture = $script:GitFixture | Where-Object { $_ -notmatch 'Release Date' }
        Mock -CommandName winget -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'Git.Git'
        ($result -join "`n") | Should -Not -Match 'Last Updated'
    }

    It 'falls back to plain output when winget show returns nothing recognizable' {
        Mock -CommandName winget -MockWith { @('some unexpected output', 'that matches nothing') }
        $result = & $script:ScriptPath -Id 'Nonsense.Package'
        $result | Should -Be @('some unexpected output', 'that matches nothing')
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester tests/winget.preview.Tests.ps1 -Output Detailed`
Expected: FAIL — `Tools/winget.preview.ps1` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Tools/winget.preview.ps1`:

```powershell
# Preview formatter for the winget fzf pickers (wins/wrm/wup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `winget show`'s field layout is undocumented CLI text (see
# docs/external-dependencies.md); each field below is pulled independently so one
# field's absence never corrupts another's, and if none match at all this falls
# back to the plain, unmodified `winget show` output.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

$lines = @(& winget show --id $Id 2>$null)

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $lines) {
        if ($line -match $Pattern) { return $Matches[1] }
    }
    return $null
}

$name = $null
if ($lines.Count -gt 0 -and $lines[0] -match '^Found (.+) \[.+\]$') { $name = $Matches[1] }

# Description is a multi-line block: "Description:" (often with no inline value)
# followed by indented continuation lines, up to the next unindented field.
$description = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^Description:\s*(.*)$') {
        if ($Matches[1]) {
            $description = $Matches[1].Trim()
        } else {
            $descLines = [System.Collections.Generic.List[string]]::new()
            for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+\S'; $j++) {
                $descLines.Add($lines[$j].Trim())
            }
            if ($descLines.Count -gt 0) { $description = $descLines -join ' ' }
        }
        break
    }
}

$fields = [ordered]@{
    Name           = $name
    Description    = $description
    Version        = Get-Field '^Version:\s*(.+)$'
    'Last Updated' = Get-Field '^\s+Release Date:\s*(.+)$'
    Publisher      = Get-Field '^Publisher:\s*(.+)$'
    License        = Get-Field '^License:\s*(.+)$'
    Homepage       = Get-Field '^Homepage:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $lines
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester tests/winget.preview.Tests.ps1 -Output Detailed`
Expected: PASS (3/3).

- [ ] **Step 5: Wire the script into `Tools/winget.ps1`'s three pickers**

In `Tools/winget.ps1`, all three occurrences of the `-Preview` line currently read:

```powershell
        -Preview       'ping -n 2 127.0.0.1 >nul & winget show --id {2}' `
```

(at line 45 in `Select-WingetPackage`, line 91 in `Remove-WingetPackage`, line 128 in `Invoke-WingetUpdate`). Replace each with:

```powershell
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\winget.preview.ps1' {2}" `
```

Also update the file's top-of-file comment block (lines 13-16), which currently reads:

```powershell
# Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep that
# debounces the preview: fzf kills the running preview command when the cursor
# moves, so scrolling fast never spawns `winget show` for skipped items; it only
# runs once the cursor rests on one for ~1s.
```

to:

```powershell
# Previews run through winget.preview.ps1 (a summary block above the full
# `winget show` output — see docs/external-dependencies.md), prefixed with
# `Start-Sleep -Milliseconds 1000;` to debounce: fzf kills the running preview
# command when the cursor moves, so scrolling fast never spawns the real
# command for skipped items; it only runs once the cursor rests on one for ~1s.
```

- [ ] **Step 6: Run the existing winget picker tests to confirm nothing broke**

Run: `Invoke-Pester tests/winget.Tests.ps1 -Output Detailed`
Expected: PASS (all tests — they mock `Invoke-DFFzf` entirely and never inspect `-Preview` content, so this file's edits don't touch their assertions).

- [ ] **Step 7: Commit**

```bash
git add Tools/winget.preview.ps1 tests/winget.preview.Tests.ps1 Tools/winget.ps1
git commit -m "$(cat <<'EOF'
feat: reorder wins/wrm/wup fzf preview to surface Name/Description/Version first

Preview now runs winget.preview.ps1, which extracts Name, Description,
Version, a best-effort Last Updated (from the first Installer's Release
Date), Publisher, License, and Homepage from `winget show`'s undocumented
text output and renders them as a summary block above the full unmodified
output. Debounce prefix rewritten from cmd syntax to Start-Sleep, matching
the shell switch to pwsh.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 4: scoop preview script

**Files:**
- Create: `Tools/scoop.preview.ps1`
- Test: `tests/scoop.preview.Tests.ps1`
- Modify: `Tools/scoop.ps1:77-86,108-121,145-158`

**Interfaces:**
- Consumes: `Format-DFPreviewSummary` (Task 1).
- Produces: `Tools/scoop.preview.ps1 -Name <string>` — same standalone-script contract as Task 3.

- [ ] **Step 1: Write the failing tests**

Create `tests/scoop.preview.Tests.ps1`:

```powershell
BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/scoop.preview.ps1'
    # Real `scoop info git` output, captured during design (ANSI color codes
    # included — 32;1 = bright green bold label, 0 = reset).
    $script:GitFixture = @(
        "`e[32;1mName        : `e[0mgit"
        "`e[32;1mDescription : `e[0mA free and open source distributed version control system."
        "`e[32;1mVersion     : `e[0m2.55.0.5"
        "`e[32;1mSource      : `e[0mmain"
        "`e[32;1mWebsite     : `e[0mhttps://gitforwindows.org"
        "`e[32;1mLicense     : `e[0mGPL-2.0-only"
        "`e[32;1mUpdated at  : `e[0m2026-08-25 02:18:48"
        "`e[32;1mUpdated by  : `e[0mA1gaE"
        "`e[32;1mBinaries    : `e[0mbin\sh.exe | bin\git.exe | git-bash.exe"
        "`e[32;1mShortcuts   : `e[0mGit\Git Bash | Git\Git CMD | Git\Git GUI"
    )
}

Describe 'scoop.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/License/Homepage summary above the full output, ANSI stripped' {
        # Assign to a local variable before the Mock scriptblock: a $script:-scoped
        # variable referenced directly inside -MockWith does not resolve when the
        # mocked command is invoked from inside a separately-invoked script file
        # (confirmed during Task 3 — Pester 6.1.0 behavior). A local closure variable
        # works correctly.
        $fixture = $script:GitFixture
        Mock -CommandName Invoke-DFScoopInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Name 'git'

        $result[0] | Should -Be 'Name: git'
        $result[1] | Should -Be 'Description: A free and open source distributed version control system.'
        $result[2] | Should -Be 'Version: 2.55.0.5'
        $result[3] | Should -Be 'Last Updated: 2026-08-25 02:18:48'
        $result[4] | Should -Be 'License: GPL-2.0-only'
        $result[5] | Should -Be 'Homepage: https://gitforwindows.org'
        $result[6] | Should -Be ''
        $result[7] | Should -Match '^-+$'
        ($result -join "`n") | Should -Match 'Updated by  : A1gaE'
        ($result -join "`n") | Should -Not -Match '\x1b\['
    }

    It 'does not include a Publisher line (scoop has no equivalent field)' {
        $fixture = $script:GitFixture
        Mock -CommandName Invoke-DFScoopInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Name 'git'
        ($result -join "`n") | Should -Not -Match 'Publisher:'
    }

    It 'falls back to plain output when scoop info returns nothing recognizable' {
        Mock -CommandName Invoke-DFScoopInfo -MockWith { @('some unexpected output') }
        $result = & $script:ScriptPath -Name 'nonsense'
        $result | Should -Be @('some unexpected output')
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester tests/scoop.preview.Tests.ps1 -Output Detailed`
Expected: FAIL — `Tools/scoop.preview.ps1` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Tools/scoop.preview.ps1`:

```powershell
# Preview formatter for the scoop fzf pickers (sins/srm/sup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `scoop info`'s field layout is undocumented, ANSI-colored CLI text (see
# docs/external-dependencies.md); each field below is pulled independently, after
# stripping the color codes, so one field's absence never corrupts another's. scoop
# has no Publisher-equivalent field, so it is not part of the summary block. If no
# field matches at all, this falls back to the plain, unmodified `scoop info` output
# (color codes intact, exactly as it renders today).
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Name
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

# Wrapped in a function (rather than calling `& scoop info $Name` inline) so tests can
# mock it: Pester 6.1.0 cannot shadow a bare command name that resolves to
# CommandType 'ExternalScript' (confirmed during Task 4 — real Scoop installs a .ps1
# shim, not a .exe, so `Mock -CommandName scoop` silently fails to intercept it; the
# same pattern DotForge already uses for fzf in Private/Invoke-DFFzf.ps1).
function Invoke-DFScoopInfo {
    param([string]$Name)
    & scoop info $Name 2>$null
}

$rawLines = @(Invoke-DFScoopInfo -Name $Name)
if (-not ($rawLines -join '').Trim()) { $rawLines = @('(scoop info produced no output)') }
$lines    = $rawLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' }

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $lines) {
        if ($line -match $Pattern) { return $Matches[1].Trim() }
    }
    return $null
}

$fields = [ordered]@{
    Name           = Get-Field '^Name\s*:\s*(.+)$'
    Description    = Get-Field '^Description\s*:\s*(.+)$'
    Version        = Get-Field '^Version\s*:\s*(.+)$'
    'Last Updated' = Get-Field '^Updated at\s*:\s*(.+)$'
    License        = Get-Field '^License\s*:\s*(.+)$'
    Homepage       = Get-Field '^Website\s*:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $rawLines
```

Note: the summary block is built from ANSI-stripped `$lines`, but the body passed to
`Format-DFPreviewSummary` is the original `$rawLines` (with color codes intact) so the
full output below the separator still renders exactly as `scoop info` prints it today.
The empty-output guard (`if (-not ($rawLines -join '').Trim())`) mirrors the fix Task 3
required for `winget.preview.ps1` — see that task's history for why the condition must
be "join everything and check it's blank" rather than merely `.Count -eq 0`.

In the test file, every `Mock -CommandName scoop -MockWith {...}` targets
`Invoke-DFScoopInfo` instead (`Mock -CommandName Invoke-DFScoopInfo -MockWith {...}`) —
the wrapper is what tests actually mock, never the bare `scoop` command.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester tests/scoop.preview.Tests.ps1 -Output Detailed`
Expected: PASS (3/3 from the brief, plus a 4th empty-output guard test — see Task 3's
equivalent for the pattern).

- [ ] **Step 5: Wire the script into `Tools/scoop.ps1`'s three pickers**

In `Tools/scoop.ps1`, all three occurrences of the `-Preview` line currently read:

```powershell
        -Preview       'ping -n 2 127.0.0.1 >nul & scoop info {2}' `
```

(at line 81 in `Select-ScoopPackage`, line 116 in `Remove-ScoopPackage`, line 154 in `Invoke-ScoopUpdate`). Replace each with:

```powershell
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\scoop.preview.ps1' {2}" `
```

Also update the file's top-of-file comment block (the "Previews are prefixed with..."
paragraph, lines 41-43), which currently reads:

```powershell
#   Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep
#   that debounces the preview: fzf kills the running preview command when the
#   cursor moves, so scrolling fast never spawns `scoop info` for skipped items.
```

to:

```powershell
#   Previews run through scoop.preview.ps1 (a summary block above the full
#   `scoop info` output — see docs/external-dependencies.md), prefixed with
#   `Start-Sleep -Milliseconds 1000;` to debounce: fzf kills the running preview
#   command when the cursor moves, so scrolling fast never spawns the real
#   command for skipped items.
```

- [ ] **Step 6: Run the existing scoop picker tests to confirm nothing broke**

Run: `Invoke-Pester tests/scoop.Tests.ps1 -Output Detailed`
Expected: PASS (all tests — same reasoning as Task 3 Step 6).

- [ ] **Step 7: Commit**

```bash
git add Tools/scoop.preview.ps1 tests/scoop.preview.Tests.ps1 Tools/scoop.ps1
git commit -m "$(cat <<'EOF'
feat: reorder sins/srm/sup fzf preview to surface Name/Description/Version first

Preview now runs scoop.preview.ps1, which strips ANSI color codes and
extracts Name, Description, Version, Last Updated, License, and Homepage
from `scoop info`'s undocumented text output, rendering them as a summary
block above the full unmodified (still-colored) output. No Publisher line —
scoop has no equivalent field. Debounce prefix rewritten from cmd syntax to
Start-Sleep, matching the shell switch to pwsh.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 5: choco preview script

**Files:**
- Create: `Tools/choco.preview.ps1`
- Test: `tests/choco.preview.Tests.ps1`
- Modify: `Tools/choco.ps1:51-60,91-100,130-139`

**Interfaces:**
- Consumes: `Format-DFPreviewSummary` (Task 1).
- Produces: `Tools/choco.preview.ps1 -Id <string>` — same standalone-script contract as Tasks 3-4.

- [ ] **Step 1: Write the failing tests**

Create `tests/choco.preview.Tests.ps1`:

```powershell
BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/choco.preview.ps1'
    # Real `choco info nodejs` output, captured during design (the leading
    # "Chocolatey vX.Y.Z" banner line is real — choco always prints it first).
    $script:NodeFixture = @(
        'Chocolatey v2.7.4'
        'nodejs 26.8.1 [Approved]'
        ' Title: Node JS | Published: 2026-08-27'
        ' Package approved as a trusted package on Aug 27 2026 18:46:34.'
        ' Package testing status: Passing on Aug 27 2026 17:25:48.'
        ' Number of Downloads: 7013042 | Downloads for this version: 100'
        ' Package url https://community.chocolatey.org/packages/nodejs/26.8.1'
        ' Chocolatey Package Source: https://github.com/chocolatey-community/chocolatey-packages/tree/master/automatic/nodejs'
        ' Tags: nodejs node javascript npm admin foss cross-platform'
        ' Software Site: http://nodejs.org/'
        ' Software License: https://github.com/nodejs/node/blob/master/LICENSE'
        ' Software Source: https://github.com/nodejs/node'
        ' Documentation: https://nodejs.org/en/docs/'
        ' Issues: https://github.com/nodejs/node/issues'
        " Summary: Node JS - Evented I/O for v8 JavaScript."
        " Description: Node.js is a JavaScript runtime built on Chrome's V8 JavaScript engine."
        ' '
        ' This package runs the official Node JS installer.'
        ''
        '1 packages found.'
    )
}

Describe 'choco.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/License/Homepage summary above the full output' {
        # Assign to a local variable before the Mock scriptblock: a $script:-scoped
        # variable referenced directly inside -MockWith does not resolve when the
        # mocked command is invoked from inside a separately-invoked script file
        # (confirmed during Task 3 — Pester 6.1.0 behavior). A local closure variable
        # works correctly.
        $fixture = $script:NodeFixture
        Mock -CommandName choco -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'

        $result[0] | Should -Be 'Name: nodejs'
        $result[1] | Should -Match "^Description: Node\.js is a JavaScript runtime built on Chrome's V8 JavaScript engine\.$"
        $result[2] | Should -Be 'Version: 26.8.1'
        $result[3] | Should -Be 'Last Updated: 2026-08-27'
        $result[4] | Should -Be 'License: https://github.com/nodejs/node/blob/master/LICENSE'
        $result[5] | Should -Be 'Homepage: http://nodejs.org/'
        $result[6] | Should -Be ''
        $result[7] | Should -Match '^-+$'
        ($result -join "`n") | Should -Not -Match 'Publisher:'
    }

    It 'skips the leading "Chocolatey vX.Y.Z" banner line and finds the real header' {
        $fixture = $script:NodeFixture
        Mock -CommandName choco -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'
        ($result -join "`n") | Should -Not -Match 'Name: Chocolatey'
    }

    It 'does not misparse an embedded URL as a field ("Package url https://...")' {
        $fixture = $script:NodeFixture
        Mock -CommandName choco -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'
        ($result -join "`n") | Should -Not -Match 'Package url https'
    }

    It 'falls back to plain output when choco info returns nothing recognizable' {
        Mock -CommandName choco -MockWith { @('some unexpected output') }
        $result = & $script:ScriptPath -Id 'nonsense'
        $result | Should -Be @('some unexpected output')
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester tests/choco.preview.Tests.ps1 -Output Detailed`
Expected: FAIL — `Tools/choco.preview.ps1` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Tools/choco.preview.ps1`:

```powershell
# Preview formatter for the choco fzf pickers (cins/crm/cup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `choco info`'s field layout (see docs/external-dependencies.md) is the most
# irregular of the three: every line carries a uniform one-space indent (no
# top-level-vs-continuation signal), Name/Version are fused into the header line
# (which is preceded by a "Chocolatey vX.Y.Z" banner line, so the header is found
# by scanning, not assumed to be first), the "last updated" date is embedded
# inside the Title line's value rather than its own field, and choco has no
# Publisher-equivalent field. Only the first line of Description is used — choco
# often continues it below with unindented markdown sections (## Features, ##
# Notes, ...) that would swamp a short summary block; that content stays
# visible, unstyled, in the full output below the separator. If no field
# matches at all, this falls back to the plain, unmodified `choco info` output.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

$lines    = @(& choco info $Id 2>$null)
# Every real field line carries exactly one leading space; strip it so field
# patterns can anchor at column 0. A no-op on lines that have no leading space
# (the banner and header lines).
$stripped = $lines | ForEach-Object { $_ -replace '^ ', '' }

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $stripped) {
        if ($line -match $Pattern) { return $Matches[1].Trim() }
    }
    return $null
}

$name    = $null
$version = $null
foreach ($line in $lines) {
    if ($line -match '^(\S+)\s+(\S+)\s*\[.*\]$') {
        $name    = $Matches[1]
        $version = $Matches[2]
        break
    }
}

$fields = [ordered]@{
    Name           = $name
    Description    = Get-Field '^Description:\s*(.+)$'
    Version        = $version
    'Last Updated' = Get-Field 'Published:\s*(\S+)'
    License        = Get-Field '^Software License:\s*(.+)$'
    Homepage       = Get-Field '^Software Site:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $lines
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester tests/choco.preview.Tests.ps1 -Output Detailed`
Expected: PASS (4/4).

- [ ] **Step 5: Wire the script into `Tools/choco.ps1`'s three pickers**

In `Tools/choco.ps1`, all three occurrences of the `-Preview` line currently read:

```powershell
        -Preview       'ping -n 2 127.0.0.1 >nul & choco info {2}' `
```

(at line 55 in `Select-ChocoPackage`, line 95 in `Remove-ChocoPackage`, line 135 in `Invoke-ChocoUpdate`). Replace each with:

```powershell
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\choco.preview.ps1' {2}" `
```

Also update the file's top-of-file comment block (the "Previews are prefixed
with..." paragraph, lines 15-17), which currently reads:

```powershell
# Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep that
# debounces the preview: fzf kills the running preview command when the cursor
# moves, so scrolling fast never spawns `choco info` for skipped items.
```

to:

```powershell
# Previews run through choco.preview.ps1 (a summary block above the full
# `choco info` output — see docs/external-dependencies.md), prefixed with
# `Start-Sleep -Milliseconds 1000;` to debounce: fzf kills the running preview
# command when the cursor moves, so scrolling fast never spawns the real
# command for skipped items.
```

- [ ] **Step 6: Run the existing choco picker tests to confirm nothing broke**

Run: `Invoke-Pester tests/choco.Tests.ps1 -Output Detailed`
Expected: PASS (all tests — same reasoning as Task 3 Step 6; `tests/choco.Tests.ps1`
already exists and mocks `Invoke-DFFzf` without inspecting `-Preview` content).

- [ ] **Step 7: Commit**

```bash
git add Tools/choco.preview.ps1 tests/choco.preview.Tests.ps1 Tools/choco.ps1
git commit -m "$(cat <<'EOF'
feat: reorder cins/crm/cup fzf preview to surface Name/Description/Version first

Preview now runs choco.preview.ps1, which extracts Name+Version (fused in
choco's header line), Description (first line only — choco often continues
it with unindented markdown sections), a best-effort Last Updated (parsed
out of the Title line's Published value), License, and Homepage from
`choco info`'s irregular undocumented text output, rendering them as a
summary block above the full unmodified output. No Publisher line — choco
has no equivalent field. Debounce prefix rewritten from cmd syntax to
Start-Sleep, matching the shell switch to pwsh.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 6: Debounce the previously-instant previews (posh-git, ripgrep, oh-my-posh)

**Files:**
- Modify: `Tools/posh-git.ps1:10,24,38,58`
- Modify: `Tools/ripgrep.ps1:15`
- Modify: `Tools/oh-my-posh.ps1:50`

**Interfaces:**
- None — these three files have no existing test coverage of `-Preview` content
  (no `posh-git.Tests.ps1`, `ripgrep.Tests.ps1`, or `oh-my-posh.Tests.ps1` exist), so
  this task is a direct edit with a manual verification step instead of a red/green
  Pester cycle.

- [ ] **Step 1: Add the debounce prefix to `Tools/posh-git.ps1`'s four previews**

Four `-Preview` lines change:

`Select-GitBranch` (line 10): `'git log --oneline --color=always {1}'` →
`'Start-Sleep -Milliseconds 1000; git log --oneline --color=always {1}'`

`Select-GitLog` (line 24): `'git show --color=always {1}'` →
`'Start-Sleep -Milliseconds 1000; git show --color=always {1}'`

`Select-GitFile` (line 38): `'git diff --color=always {2}'` →
`'Start-Sleep -Milliseconds 1000; git diff --color=always {2}'`

`Select-GitStash` (line 58): `'git stash show -p {}'` →
`'Start-Sleep -Milliseconds 1000; git stash show -p {}'`

- [ ] **Step 2: Add the debounce prefix to `Tools/ripgrep.ps1`'s preview**

`Select-RipgrepResult` (line 15): `'bat --color=always --highlight-line {2} {1}'` →
`'Start-Sleep -Milliseconds 1000; bat --color=always --highlight-line {2} {1}'`

- [ ] **Step 3: Add the debounce prefix to `Tools/oh-my-posh.ps1`'s preview**

`Select-PoshTheme` (line 50) currently reads:

```powershell
        -Preview       "oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
```

Change to:

```powershell
        -Preview       "Start-Sleep -Milliseconds 1000; oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
```

- [ ] **Step 4: Run every existing test file for the three companions to confirm nothing broke**

Run: `Invoke-Pester tests/ -Output Detailed` (full suite — these three companions
have no dedicated test files, so the check here is that nothing *else* regressed,
e.g. via `Register-DFTool` dot-sourcing them).
Expected: PASS, same pass count as the suite had before this task.

- [ ] **Step 5: Commit**

```bash
git add Tools/posh-git.ps1 Tools/ripgrep.ps1 Tools/oh-my-posh.ps1
git commit -m "$(cat <<'EOF'
fix: debounce posh-git/ripgrep/oh-my-posh previews after the pwsh shell switch

These three previews had no debounce because cmd's ~80ms dispatch made
re-running them on every cursor move unnoticeable. Switching fzf's preview
shell to pwsh (~230ms startup) would otherwise add that delta to every
keystroke while scrolling a git log, branch list, or grep result list.
Same Start-Sleep -Milliseconds 1000 debounce as winget/scoop/choco.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```

---

### Task 7: Documentation — external-dependencies.md, README, examples, CHANGELOG

**Files:**
- Modify: `docs/external-dependencies.md`
- Modify: `README.md:590,624,640`
- Modify: `examples/06-winget-pickers.ps1:3-4,18`
- Modify: `examples/07-scoop-choco-pickers.ps1:4`
- Modify: `CHANGELOG.md:5-7` (the `[Unreleased]` / `### Changed` section)

**Interfaces:** None — documentation only.

- [ ] **Step 1: Add a new "Undocumented internals" entry to `docs/external-dependencies.md`**

Insert as a new `### 11.` entry, immediately before the `## Documented but load-bearing`
heading (i.e., right after entry `### 10.` and its closing `---`):

```markdown
### 11. winget/scoop/choco: `show`/`info` field layout, and fzf's default preview shell

| | |
|---|---|
| **What** | `winget show`, `scoop info`, and `choco info` are undocumented, unstable plain-text CLI output — no flag on any of the three reorders or selects fields. DotForge extracts a handful of fields (Name, Description, Version, a best-effort "last updated" date, Publisher where the tool has one, License, Homepage) from each with independent, isolated regexes and renders them as a summary block above the tool's full unmodified output. Reaching this text at all also depends on fzf's own undocumented Windows default: `cmd /s/c` runs `--preview`/`--bind execute()` commands unless `--with-shell` says otherwise (verified against fzf 0.74.3's man page) — `Tools/fzf.json` sets `--with-shell='pwsh -NoProfile -Command'` in `FZF_DEFAULT_OPTS` so those commands run under PowerShell instead. |
| **Where** | `Tools/winget.preview.ps1`, `Tools/scoop.preview.ps1`, `Tools/choco.preview.ps1`, `Private/Format-DFPreviewSummary.ps1`, `Tools/fzf.json` |
| **Why** | Each field is pulled independently — rather than parsing the whole document generically — specifically because `choco info`'s layout is irregular enough to make generic parsing unsafe: every line carries a uniform one-space indent (no top-level-vs-continuation signal), some lines pack two fields on one line, and some lines contain a colon incidentally as part of an embedded URL with no real `Key:` prefix (`Package url https://...`) — a naive "split on first colon" parser would misread that as a field named "Package url https". |
| **If it changes** | A single field's regex not matching just omits that field from the summary block — never a guess, never a misparse. If every field's regex misses (the tool changed its output format upstream), the affected preview script falls back to the tool's plain, unmodified output — no summary block, no error. If fzf's Windows default shell ever stops being `cmd` when `--with-shell`/`$SHELL` are unset, the explicit `--with-shell` setting in `FZF_DEFAULT_OPTS` is unaffected either way, since it never relies on that default. |

---
```

- [ ] **Step 2: Update `README.md`'s winget/scoop/choco section descriptions**

Line 590 currently reads:

```markdown
Fuzzy package pickers with a live `winget show` preview pane. Each item carries
```

Change to:

```markdown
Fuzzy package pickers with a live preview pane — a Name/Description/Version/
Publisher/License/Homepage summary above the full `winget show` output. Each item carries
```

Line 624 currently reads:

```markdown
The same picker set for scoop, with a `scoop info` preview. Search uses
```

Change to:

```markdown
The same picker set for scoop, with a summary-above-full-output preview built
on `scoop info` (no Publisher line — scoop has no equivalent field). Search uses
```

Line 640 currently reads:

```markdown
output (no module exists). `choco info` preview. Install/uninstall/upgrade need
```

Change to:

```markdown
output (no module exists). Summary-above-full-output preview built on `choco
info` (no Publisher line). Install/uninstall/upgrade need
```

- [ ] **Step 3: Update `examples/06-winget-pickers.ps1`**

Lines 3-4 currently read:

```powershell
# Interactive winget workflows built on Invoke-DFPicker + fzf, with a live
# `winget show` preview pane. Package data comes from the Microsoft.WinGet.Client
```

Change to:

```powershell
# Interactive winget workflows built on Invoke-DFPicker + fzf, with a live
# preview pane (Name/Description/Version/Publisher/License/Homepage summary
# above the full `winget show` output). Package data comes from the Microsoft.WinGet.Client
```

Line 18 currently reads:

```powershell
# Each row shows Name / Id / Version; the preview pane runs `winget show`.
```

Change to:

```powershell
# Each row shows Name / Id / Version; the preview pane summarizes then shows the full `winget show` output.
```

- [ ] **Step 4: Update `examples/07-scoop-choco-pickers.ps1`**

Line 4 currently reads:

```powershell
# applied to scoop and Chocolatey. Each has a live `<pm> info` preview pane and
```

Change to:

```powershell
# applied to scoop and Chocolatey. Each has a live preview pane (a summary
# block above the full `<pm> info` output) and
```

- [ ] **Step 5: Add a `CHANGELOG.md` entry**

In the `## [Unreleased]` section, under `### Changed` (create the subsection if the
`### Added` entries are currently the only ones present — insert `### Changed`
immediately after the last `### Added` bullet and before any following `###`
heading), add:

```markdown
- **`wins`/`sins`/`cins` (and `wrm`/`srm`/`crm`, `wup`/`sup`/`cup`) fzf previews now
  lead with a Name/Description/Version/Publisher/License/Homepage summary block**
  (plus a best-effort last-updated date), above the tool's full `winget
  show`/`scoop info`/`choco info` output — previously the raw CLI output, field
  order dictated entirely by the tool itself. Also switches fzf's default preview
  shell from `cmd` to `pwsh` (`Tools/fzf.json`'s `FZF_DEFAULT_OPTS`), which as a
  side effect fixes a latent quoting bug in the `fpot` (oh-my-posh theme picker)
  preview for theme paths containing spaces.
```

- [ ] **Step 6: Verify the full test suite still passes**

Run: `Invoke-Pester tests/ -Output Detailed`
Expected: PASS — no test asserts against README/examples/CHANGELOG content, so this
step confirms the documentation task introduced no accidental code changes.

- [ ] **Step 7: Commit**

```bash
git add docs/external-dependencies.md README.md examples/06-winget-pickers.ps1 examples/07-scoop-choco-pickers.ps1 CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: document the preview reorder and the fzf preview-shell dependency

Adds an external-dependencies.md entry for winget/scoop/choco's undocumented
show/info text layout and fzf's undocumented default preview shell; updates
README, examples, and the changelog to describe the new summary-block
preview behavior.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019WHSP1eRW2ik8ndFD8hFUb
EOF
)"
```
