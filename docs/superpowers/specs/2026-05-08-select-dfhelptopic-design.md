# Design: Select-DFHelpTopic + Invoke-DFHelp Regex Update

**Date:** 2026-05-08
**Status:** Approved

## Overview

Two related changes to `DFHelpers.Help.ps1`:

1. **`Select-DFHelpTopic` (`fh`)** — fzf-based interactive help browser. Browses all available PS help topics, shows a plain `Get-Help` preview, and on selection opens the full colorized paged help via `Invoke-DFHelp`. Topic list is cached and invalidated by a module fingerprint check.

2. **`Invoke-DFHelp` regex update** — replace the hardcoded header list in the `foreach` loop with a single regex that matches any all-caps section header automatically.

## Architecture

```
Private/Get-DFHelpTopicList.ps1     ← NEW: cache read/write/invalidation
Public/DFHelpers.Help.ps1           ← MODIFIED: add Select-DFHelpTopic (fh),
                                       update Invoke-DFHelp regex
DotForge.psd1                       ← MODIFIED: add Select-DFHelpTopic + fh
tests/Get-DFHelpTopicList.Tests.ps1 ← NEW: cache hit/miss/force tests
tests/DFHelpers.Help.Tests.ps1      ← MODIFIED: new function + regex tests
```

`Select-DFHelpTopic` has zero cache logic — it delegates entirely to `Get-DFHelpTopicList`. The private helper is mockable in tests, so `Select-DFHelpTopic` tests can inject a fake topic list without touching the filesystem or running `Get-Help *`.

## `Get-DFHelpTopicList` (Private)

**Cache files** stored in `$XDG_CACHE_HOME/dotforge/`:
- `help-topics.txt` — one `Name\tCategory` pair per line
- `help-topics.key` — module fingerprint string

**Fingerprint** (~50ms to compute):
```powershell
Get-Module -ListAvailable | Sort-Object Name, Version |
    ForEach-Object { "$($_.Name):$($_.Version)" } |
    Join-String -Separator ','
```

**Cache logic:**
1. Compute fingerprint
2. If `help-topics.key` exists and content matches fingerprint → read and return `help-topics.txt` lines
3. Otherwise → run `Get-Help * | Select-Object Name, Category`, write both files, return lines
4. `-Force` switch skips step 2, always regenerates

**Signature:**
```powershell
function Get-DFHelpTopicList {
    param([switch]$Force)
    # returns [string[]] of "Name`tCategory" lines
}
```

**Why `Name\tCategory`:** A single cache file serves all `-Category` filter combinations. Client-side filtering after cache retrieval is instant — no second `Get-Help *` call per category.

**Conventions:** `#Requires -Version 7.0`, no `$ErrorActionPreference = 'Stop'`, uses `Ensure-DFDir` for cache directory creation.

## `Select-DFHelpTopic` (`fh`)

**Parameters:**
- `-Category [string]` — optional, no `[ValidateSet]` (future PS categories work without code changes). Filters the cached list client-side: `Where-Object { ($_ -split "`t")[1] -eq $Category }`.
- `-Force [switch]` — passed through to `Get-DFHelpTopicList`

**Picker configuration:**
- `-List`: `Get-DFHelpTopicList -Force:$Force` output, optionally filtered by `-Category`
- `-Delimiter "\`t"` — tab delimiter
- `-WithNth "1"` — fzf displays Name column only; fuzzy search works against name only, not category strings
- `-Header`: `'Browse help topics  [Enter to view full help]'`
- `-Preview`: `'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue" 2>nul'` — plain, fast, no colorization
- `-Parse`: `{ ($_ -split "`t")[0] }` — extracts topic name from raw line
- `-Action`: `{ param($topic) Invoke-DFHelp $topic }` — full colorized paged view

**Usage:**
```powershell
fh                        # browse all topics
fh -Category HelpFile     # browse only about_* docs
fh -Category Cmdlet       # browse only cmdlets
fh -Force                 # bypass cache, regenerate
```

**Alias:** `fh`, registered with `-Scope Global -Force`.

## `Invoke-DFHelp` Regex Update

Replace the `foreach` loop:
```powershell
# BEFORE
foreach ($h in 'NAME', 'TOPIC', 'SYNOPSIS', ...) {
    $helpText = $helpText -replace "(?m)^($h)", "$yellow`$1$reset"
}

# AFTER
$helpText = $helpText -replace '(?m)^([A-Z]{2,}(?: [A-Z]+)*)$', "$yellow`$1$reset"
```

**Pattern:** `(?m)^([A-Z]{2,}(?: [A-Z]+)*)$`
- `(?m)` — multiline: `^`/`$` match line boundaries
- `[A-Z]{2,}` — at least 2 uppercase letters
- `(?: [A-Z]+)*` — zero or more additional all-caps words separated by a single space
- `$` — end of line, no trailing content

Catches all standard and custom help headers including ones from third-party modules. Eliminates the hardcoded list and its maintenance burden.

## Module Manifest (`DotForge.psd1`)

Add to existing arrays:
- `FunctionsToExport`: `'Select-DFHelpTopic'`
- `AliasesToExport`: `'fh'`

## Testing

**`tests/Get-DFHelpTopicList.Tests.ps1`** (new):
- Cache hit: fingerprint matches → returns cached list, `Get-Help` not called
- Cache miss: fingerprint differs → regenerates, writes both cache files
- `-Force`: bypasses cache even when fingerprint matches, regenerates
- Missing cache files: treated as cache miss, generates fresh

**`tests/DFHelpers.Help.Tests.ps1`** (extend existing):
- `Select-DFHelpTopic`: mock `Get-DFHelpTopicList`, verify `Invoke-DFFzf` invoked, verify action calls `Invoke-DFHelp` with selected topic name
- `-Category` filtering: mock returns mixed categories, verify only matching topics passed to fzf
- `-Force` passed through to `Get-DFHelpTopicList`
- `Invoke-DFHelp` regex: ANSI codes present on all-caps header lines, absent on indented content lines, absent when `$Env:NO_COLOR` set
