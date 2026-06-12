# Design: `Show-DFCliHelp` — colorized CLI help with flag auto-detection

**Date:** 2026-06-12
**Status:** Approved (design phase)

## Problem

`hm` / `Invoke-DFHelp` colorizes **PowerShell `Get-Help`** output. There is no
equivalent for **external CLI tools** (`git`, `eza`, `docker`, `fzf`, ...). Those
print their own help text when given a help flag, but:

- The help flag varies by tool (`--help`, `-help`, `-?`, `help`, `-h`), and some
  flags collide with real behavior (`eza -h` / `ls -h` mean *human-readable*, not help).
- The raw output is monochrome and hard to scan.

We want a function that takes a command name (and optionally an explicit flag),
discovers the right help flag when not given, caches the discovery, colorizes the
output with header + flag emphasis similar to `hm`, and offers a paged variant.

## Goals

- Run `<command> <help-flag>` and print colorized help.
- Auto-detect the help flag when not supplied; cache the result per command.
- Colorize: section headers (bold yellow, like `hm`) and a faint tint on option flags.
- Provide a terminal alias and a pager alias.

## Non-Goals

- Parsing/structuring help into fields. We colorize text, not model it.
- Supporting interactive help pagers launched by the tool itself.
- Cross-session learning beyond the simple flag cache.

## Architecture

Three units, following the repo's Public-orchestrates / Private-does-the-work split.

| Unit | Location | Responsibility |
|------|----------|----------------|
| `Show-DFCliHelp` | `Public/DFHelpers.Help.ps1` (append) | Orchestrate: resolve flag → run command → colorize → emit or page |
| `Resolve-DFCliHelpFlag` | `Private/Resolve-DFCliHelpFlag.ps1` (new) | Find the working help flag; read/write the flag cache |
| `Format-DFCliHelpText` | `Private/Format-DFCliHelpText.ps1` (new) | **Pure** string→string colorizer (takes a `-Color` bool) |

### Why this boundary

`hm` inlines its colorize regex, so the coloring logic is only observable through
captured pager output. Here the **pure colorizer** (`Format-DFCliHelpText`) takes
text + a color flag and returns text, giving every header/flag rule a direct,
deterministic unit test with no process spawning. The messy, side-effectful part —
guessing flags by spawning processes — is isolated in `Resolve-DFCliHelpFlag`,
where mocking is contained.

## Component: `Resolve-DFCliHelpFlag`

```
Resolve-DFCliHelpFlag [-Name] <string> [-Force]
  → returns the working help flag string (e.g. '--help'), or $null if none found
```

Algorithm:

1. **Explicit flag bypass** — handled by the caller. If `Show-DFCliHelp -Flag` is
   supplied, this resolver is not called at all (and nothing is cached).
2. **Cache hit** — read `$XDG_CACHE_HOME/dotforge/cli-help-flags.json` (a JSON object
   `{ "git": "--help", "eza": "--help", ... }`). Return the cached flag unless `-Force`.
3. **Guess** — try candidates in this **safe order**:
   `--help`, `-help`, `-?`, `help`, `-h` (last — it collides with real flags).
4. For each candidate: run `& $cmd $candidate 2>&1`, capture combined text + exit
   code inside try/catch (native-exec failures must not throw out of the loop).
   **Accept** the candidate when the output *looks like help*:
   - non-empty, AND
   - (≥ 3 lines OR matches `(?im)^\s*(usage|options|commands|flags|synopsis)\b` or a heading line), AND
   - NOT an error: does not match `(?i)(unknown|unrecognized|invalid|unexpected)\b.{0,30}\b(option|flag|argument|switch|command)` and not a leading `(?im)^error\b`.
5. First accepted candidate → write to cache (merge into the JSON map), return it.
6. **No candidate accepted** → return `$null`. The caller warns and falls back to the
   highest-output candidate's text without caching.

Safety: because `--help` is validated first, the risky `-h` only runs for tools where
every safer candidate failed validation.

Cache notes:

- Map is `{ commandName: flag }`. Read-merge-write so concurrent tools accumulate.
- Refresh with `-Force` (re-guess + overwrite the entry). Help flags effectively never
  change for a tool, so no version/path fingerprinting.
- If `$XDG_CACHE_HOME` is unset: still functions, skips persistence, warns once
  (mirrors `Get-DFHelpTopicList`).

## Component: `Format-DFCliHelpText`

```
Format-DFCliHelpText [-Text] <string> [-Color] <bool>
  → returns the (optionally) colorized text
```

- When `-Color:$false` → returns `$Text` unchanged (NO_COLOR / non-VT passthrough).
- Processed **line-by-line** (the "preceded by a blank line" rule needs previous-line
  state; a pure multiline regex is brittle here).

Rules:

- **Header** → bold yellow `ESC[1;33m … ESC[0m` (same as `hm`). A line qualifies when:
  - it is at column 0 (not indented), AND
  - the previous line is blank/whitespace OR it is the first line, AND
  - it is ALL-CAPS (≥ 2 chars, pattern roughly `^[A-Z][A-Z0-9 ./_-]+$`) OR ends in `:`
    (`^\S.*:\s*$`).
  - Catches `USAGE`, `GLOBAL OPTIONS`, `Options:`, `Commands:`.
- **Flag tint** → faint `ESC[2m … ESC[22m`, a hint not a highlight. Applied only on
  option-list lines (`^\s+-`). Tint the **flag portion only** — everything before the
  first run of 2+ spaces that separates the flag(s) from the description. So in
  `  -f, --force   overwrite`, only `-f, --force` dims; the description stays body color.
- Lines that match neither rule are emitted unchanged.

Color gate (computed by the caller, passed in as `-Color`):
`(-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal` — identical to `hm`.

## Component: `Show-DFCliHelp` (orchestrator + entry points)

```
Show-DFCliHelp [-Name] <string> [-Flag <string>] [-Paged] [-Force]
```

Flow:

1. `Get-Command -Name $Name -ErrorAction SilentlyContinue` — if not found, warn and return.
2. Determine the flag:
   - `-Flag` given → use it verbatim, no detection, no cache.
   - else → `Resolve-DFCliHelpFlag -Name $Name -Force:$Force`. If `$null`, warn and use
     the best-effort fallback text.
3. Run `& $Name $flag 2>&1 | Out-String` to get raw help text.
4. `$color = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal`.
5. `$out = Format-DFCliHelpText -Text $raw -Color $color`.
6. Emit: default → write `$out` to the output stream (terminal renders it).
   `-Paged` → `$out | Invoke-DFWithPager`.

### Aliases / entry points

- `clh` = `Set-Alias` → `Show-DFCliHelp` (terminal).
- `clhp` = **thin wrapper function** adding `-Paged`:
  `function Show-DFCliHelpPaged { Show-DFCliHelp @args -Paged }`, aliased `clhp`.
  An alias cannot add an argument (the same constraint hit with eza's `ls` wrapper),
  so the paged variant must be a function, not a `Set-Alias`.

Usage:

```
clh  eza            → Show-DFCliHelp eza
clh  eza --tree     → Show-DFCliHelp eza -Flag --tree   (explicit flag, no guessing)
clhp git            → Show-DFCliHelp git -Paged          (through Invoke-DFWithPager)
clh  docker -Force  → re-guess + refresh the cached flag
```

## Edge cases

- Command not on PATH → `Get-Command` check, `Write-Warning`, return.
- `$XDG_CACHE_HOME` unset → works without persistence, warns once.
- Help flag causes the tool to wait on input → out of scope (help flags exit promptly);
  noted as a known risk, not mitigated with a timeout in v1.
- Failed guess → best-effort highest-output text + warning; nothing cached.

## Manifest / exports

`DotForge.psd1`:
- `FunctionsToExport` += `Show-DFCliHelp`, `Show-DFCliHelpPaged`.
- `AliasesToExport` += `clh`, `clhp`.

(Privates are dot-sourced, not exported.)

## Testing

- `tests/Format-DFCliHelpText.Tests.ps1` — pure unit tests: header detection (all-caps,
  trailing colon, blank-line-precedence, indented lines excluded, first-line case),
  flag-tint portion split, `-Color:$false` passthrough, idempotence on already-plain text.
- `tests/Resolve-DFCliHelpFlag.Tests.ps1` — mock command execution: candidate order,
  `-h` tried last, error-output rejection, accept on help-looking output, cache
  read/write/merge, `-Force` re-guess, `$null` when all fail.
- `tests/Show-DFCliHelp.Tests.ps1` — orchestration with both privates mocked: explicit
  `-Flag` bypasses resolver, not-found warns, `-Paged` routes through `Invoke-DFWithPager`,
  color gate honored.

## Docs

- Full comment-based help on `Show-DFCliHelp` (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`
  ×4, `.EXAMPLE` ×≥2, `.OUTPUTS`).
- README: add `clh` / `clhp` to the General Helpers table + a short example.
- `examples/`: mention in the relevant profile example.

## Decisions locked during brainstorming

- Flag detection: **validate output content** (not exit-code-only, not a curated map).
- Colors: **fixed ANSI, like `hm`** (bold-yellow headers, faint flags).
- Header rule: **exact user rule** (col 0, blank/SOF precedence, all-caps or trailing `:`).
- Naming: **`Show-DFCliHelp` / `clh` / `clhp`**.
- Cache: **per-command JSON map, refresh on `-Force`**.
- `clhp` is a real exported function (argument constraint).
- Failed guess → best-effort text + warning, not an error.
