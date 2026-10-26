# Config Files Over Variables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move fzf's base options and less's flags into seeded config files, shrink vivid's `LS_COLORS` with a seeded extension list, and write the policy down.

**Architecture:** Each tool keeps its own change (record JSON, seed file under `Tools/<tool>/`, companion). Seeds use the existing `setup.seed` path (copied only when absent, during the one-time setup step that fzf, less and vivid have never run). No core change.

**Tech Stack:** PowerShell 7.2+, Pester 6; fzf 0.74 (`FZF_DEFAULT_OPTS_FILE`), less 710 (`lesskey` `#env`), vivid 0.11 (`-d <filetypes.yml>`).

**Spec:** `docs/superpowers/specs/2026-10-26-config-files-design.md`

## Global Constraints

- Seeds never overwrite an existing file; a user's own `FZF_DEFAULT_OPTS` or `LESS` set outside DotForge is kept (`Set-DFEnv`).
- No file DotForge rewrites on every load or theme switch.
- Same behavior as today: fzf base options `--layout=reverse`, `--inline-info`, `--height=40%`, `--border`; less flags `--RAW-CONTROL-CHARS --quit-if-one-screen --no-init`; vivid colors unchanged for kept extensions (24-bit).
- `LS_COLORS` target: under 8,191 characters for catppuccin-mocha.
- Plugin rule: no tool names in core code.

## Review Focus

1. A theme switched three times: `FZF_DEFAULT_OPTS` holds one `--color` option, not three (today it grows).
2. PSFzf's `--ansi` survives a theme switch (it is appended after the colors).
3. An `FZF_DEFAULT_OPTS` set outside DotForge plus an explicit theme: the colors are still appended, and a second switch replaces only DotForge's colors, never the user's text.
4. vivid's seeded database deleted by the user: `LS_COLORS` falls back to vivid's built-in database without an error.
5. Editing the seeded vivid database changes the cache key, so the next load regenerates.

---

### Task 1: less — flags in the seeded lesskey

**Files:** Modify `Tools/less.json`; Create `Tools/less/lesskey`; Test `tests/less.Tests.ps1` (create if absent, same shape as `tests/vivid.Tests.ps1`'s record checks).

- [ ] **Step 1: Failing tests**
  - `does not set LESS` — `(Get-Content Tools/less.json -Raw | ConvertFrom-Json).PSObject.Properties['env']` is absent or has no `LESS`.
  - `seeds the lesskey LESSKEYIN names, with the flags in #env` — record's `setup.seed` maps `${XDG_CONFIG_HOME}/less/lesskey` → `less/lesskey`; that file's text matches `(?m)^#env\r?$` and `(?m)^LESS = --RAW-CONTROL-CHARS --quit-if-one-screen --no-init\r?$`.
- [ ] **Step 2: Run** `build/Test-DFFull.ps1 -Path tests/less.Tests.ps1` — Expected: both FAIL.
- [ ] **Step 3: Implement**: drop `env`, add `setup.seed`, write `Tools/less/lesskey` (a comment line saying DotForge seeded it and less reads it through `LESSKEYIN`, then the `#env` section).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Verify with the real less** (author-time, not a test): with `LESSKEYIN` pointing at the seeded file and `LESS` unset, `less` on a short file returns at once (`--quit-if-one-screen` from the file). Record the result in the ledger.

### Task 2: fzf — base options in a seeded fzfrc; colors replace, not append

**Files:** Modify `Tools/fzf.json`, `Tools/fzf.ps1` (`Invoke-DFApplyFzfTheme`); Create `Tools/fzf/fzfrc`; Test `tests/fzf.Tests.ps1`.

**Interfaces:** `Invoke-DFApplyFzfTheme -Name [-Implicit]` keeps its signature.

- [ ] **Step 1: Failing tests** (update the first existing test: it asserts `--layout=reverse` in the variable, which moves to the file)
  - `points FZF_DEFAULT_OPTS_FILE at the seeded fzfrc` — record: `xdg.method` `env`, `xdg.vars.FZF_DEFAULT_OPTS_FILE` = `${XDG_CONFIG_HOME}/fzf/fzfrc`, `xdg.native.FZF_DEFAULT_OPTS_FILE` = `@()`, `setup.seed` maps it to `fzf/fzfrc`; `env` has no `FZF_DEFAULT_OPTS`.
  - `the seeded fzfrc holds the base options` — `Tools/fzf/fzfrc` has lines `--layout=reverse`, `--inline-info`, `--height=40%`, `--border`.
  - `applies the theme colors alone to FZF_DEFAULT_OPTS` — after `Register-DFTool fzf`: matches `bg\+:#313244`, does not match `--layout`.
  - `a theme switch replaces DotForge's colors instead of appending` (**RF1**) — apply catppuccin-mocha, then another bundled theme, then catppuccin-mocha: `([regex]::Matches($Env:FZF_DEFAULT_OPTS, '--color=')).Count | Should -Be 1`.
  - `keeps --ansi across a theme switch` (**RF2**) — set `--ansi` after the first apply (as `Enable-DFFzfAnsiOption` does), switch theme: `--ansi` still present, one `--color=`.
  - `replaces only its own colors in an outside FZF_DEFAULT_OPTS` (**RF3**) — outside value `--cycle`, explicit apply twice: starts with `--cycle`, one `--color=`.
- [ ] **Step 2: Run** `-Path tests/fzf.Tests.ps1` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement**
  - Record: as the first test states; `xdg.compliance` stays honest (`partial`).
  - `Tools/fzf/fzfrc`: a comment line, then the four options one per line.
  - `Invoke-DFApplyFzfTheme`: remove DotForge's previous `--color=` line before adding the new one. The previous one is the line the function last wrote, remembered in a closure-captured variable (`$_lastColor`, set after each apply); remove it by exact line match (lines are `` `n ``-separated), never by pattern, so a user's own `--color` is untouched.
- [ ] **Step 4: Run** — Expected: PASS (all of `tests/fzf.Tests.ps1`, plus `tests/PSFzf*.Tests.ps1`).

### Task 3: vivid — seeded extension list, database-aware cache

**Files:** Modify `Tools/vivid.json`, `Tools/vivid.ps1`; Create `Tools/vivid/filetypes.yml`; Test `tests/vivid.Tests.ps1`.

- [ ] **Step 1: Failing tests**
  - `seeds a filetypes database` — `setup.seed` maps `${XDG_CONFIG_HOME}/vivid/filetypes.yml` → `vivid/filetypes.yml`; `xdg.native` lists vivid's own config path for it.
  - `generates from the seeded database` — `Mock` the vivid call seam (see Step 3) and assert it received `-d <XDG_CONFIG_HOME>\vivid\filetypes.yml`.
  - `falls back to vivid's own database when the file is gone` (**RF4**) — no file: the seam gets no `-d`; `LS_COLORS` still set.
  - `regenerates after the database changes` (**RF5**) — apply, touch the file's LastWriteTime +1 min, apply again: the generator ran twice.
  - `stays under 8,191 characters with the default theme` — runs real vivid against `Tools/vivid/filetypes.yml`; `-Skip:(-not (Get-Command vivid -ErrorAction Ignore))`.
- [ ] **Step 2: Run** `-Path tests/vivid.Tests.ps1` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement**
  - Seam: a closure-captured `$_runVivid = { param([string[]]$Arguments) & vivid @Arguments 2>&1 | Out-String }` in `vivid.ps1`, so tests mock nothing global; tests replace it by stubbing `vivid` with a test global (`function global:vivid {}`) as the existing tests do. Use whichever of the two the existing tests already rely on.
  - Fingerprint: `"$Name|$(<database LastWriteTimeUtc ticks, or 'builtin'>)"`.
  - `Tools/vivid/filetypes.yml`: vivid's own format (copy its structure from vivid 0.11's bundled `filetypes.yml`), trimmed per category to the extensions a developer meets weekly; keep every non-extension entry (`core`: `di`, `ln`, `ex`, …).
- [ ] **Step 4: Run** — Expected: PASS, including the length test (record the length in the ledger).

### Task 4: Policy, docs, close T-79

**Files:** `docs/guide/writing-a-tool.md` (the `env` row), `CLAUDE.md` (`env` bullet), `docs/guide/tools.md` (fzf, less, vivid notes: where the files are and how to edit them), `CHANGELOG.md` (Changed: the three moves; a note that an existing `lesskey` doesn't get the `#env` lines), restore notes (Environment size: done), `TODO.md` (delete T-79), regenerate registry, bundle, reference.

- [ ] **Step 1:** Write the docs. The `env` row says: settings go in a seeded config file when the tool reads one; `env` holds settings a tool takes only from a variable, live theme values and role variables.
- [ ] **Step 2:** `Build-DFToolRegistry.ps1`, `Build-DFCoreBundle.ps1`, `Build-DFReferenceDocs.ps1`; full gate. Expected: 0 failed, no sentinel files.
- [ ] **Step 3:** One signed commit, `Closes T-79`.
