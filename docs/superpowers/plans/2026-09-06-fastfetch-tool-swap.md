# winfetch → fastfetch Tool Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the abandoned `winfetch` plugin with `fastfetch`, shipping a
seeded catppuccin-mocha config, and document (not automate) an optional
startup banner.

**Architecture:** Pure plugin swap per `docs/plugin-architecture.md` — no
core (`Public/`/`Private/`) code changes. One new tool JSON
(`Tools/fastfetch.json`) uses the already-existing `xdg.method: "config"`
seeding path in `Private/Set-DFToolXdgConfig.ps1`. Two build-time-generated
data files (`data/tool-categories.json`, `data/tool-identities.json`) get
regenerated from edited source fragments, never hand-edited directly.

**Tech Stack:** PowerShell 7+, Pester 5/6, fastfetch 2.68.1 (installed via
scoop on the dev machine), JSON/JSONC.

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file.
- Every tool JSON must pass `Test-DFToolSchema` (name + executable required;
  `xdg.method` ∈ `default|env|config|wrapper|manual`).
- `data/tool-categories.json` and `data/tool-identities.json` are
  **build-generated** — edit only `build/categories/*.jsonc` /
  `build/identities/*.jsonc` sources, then regenerate via
  `build/Build-DFCategoryDb.ps1` / `build/Build-DFToolIdentities.ps1`. A
  duplicate tool key across `build/categories/*.jsonc` fragments makes
  `Build-DFCategoryDb.ps1` throw.
- The design spec's verified module set for the seeded fastfetch config is
  final (drop `publicip` only, keep everything else from the user's draft) —
  see `docs/superpowers/specs/2026-09-06-fastfetch-tool-swap-design.md`,
  "Verified facts". Do not re-litigate this in implementation.
- No new `$DFConfig` key and no automatic invocation of `fastfetch` anywhere
  in module code — the startup banner is documentation-only, per the
  approved design.

---

### Task 1: Swap the tool plugin JSON

**Files:**
- Create: `Tools/fastfetch.json`
- Delete: `Tools/winfetch.json`
- Modify: `tests/Test-DFToolSchema.Tests.ps1:90`

**Interfaces:**
- Consumes: `Private/Test-DFToolSchema.ps1`'s `Test-DFToolSchema -Tool -Errors ([ref])` (existing, unchanged); `Private/Set-DFToolXdgConfig.ps1`'s `'config'` method (existing, unchanged — reads `xdg.config_path`/`xdg.config_content`).
- Produces: `Tools/fastfetch.json` — consumed by Task 2 (category `ids` must match its `packages` block) and Task 3 (README table).

- [ ] **Step 1: Update the seed-file list to point at `fastfetch` instead of `winfetch`**

In `tests/Test-DFToolSchema.Tests.ps1`, change line 90 from:

```powershell
        'fd', 'broot', 'jq', 'glow', 'procs', 'winfetch',
```

to:

```powershell
        'fd', 'broot', 'jq', 'glow', 'procs', 'fastfetch',
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed"`
Expected: FAIL on `'seed file fastfetch.json exists and passes schema validation'` with "fastfetch.json must exist in Tools/" — `Tools/winfetch.json` still exists on disk at this point but is no longer referenced by the test, which is fine.

- [ ] **Step 3: Create `Tools/fastfetch.json`**

```json
{
  "name": "fastfetch",
  "description": "Fast, actively-maintained neofetch-like system information tool",
  "tags": ["system", "info"],
  "executable": "fastfetch.exe",
  "packages": {
    "scoop": "fastfetch",
    "winget": "Fastfetch-cli.Fastfetch"
  },
  "xdg": {
    "compliance": "full",
    "method": "config",
    "config_path": "${XDG_CONFIG_HOME}/fastfetch/config.jsonc",
    "config_content": "{\n  \"$schema\": \"https://github.com/fastfetch-cli/fastfetch/raw/2.68.1/doc/json_schema.json\",\n  \"logo\": { \"type\": \"none\" },\n  \"display\": { \"separator\": \"  \", \"color\": { \"keys\": \"#cba6f7\", \"output\": \"#cdd6f4\" } },\n  \"modules\": [\n    \"os\", \"host\", \"kernel\", \"uptime\", \"packages\", \"shell\", \"terminal\",\n    \"cpu\", \"gpu\", { \"type\": \"memory\", \"format\": \"{used} / {total} ({percentage})\" },\n    \"display\", { \"type\": \"localip\", \"format\": \"{ipv4} ({ifname})\" },\n    { \"type\": \"disk\", \"format\": \"{mountpoint} ({filesystem}): {size-used} / {size-total} ({size-percentage})\" },\n    { \"type\": \"physicaldisk\", \"hideVirtual\": true, \"hideUnused\": true, \"format\": \"{name} ({physical-type}, {interconnect}): {size}\" }\n  ]\n}\n"
  },
  "aliases": {},
  "picker": null
}
```

This exact `config_content` string was verified during design: it round-trips through `ConvertFrom-Json` twice (outer tool record, then the inner config string) and renders correctly through a real `fastfetch --config <file>` invocation (14 modules, real OS/CPU/memory/disk output, no errors). `packages.winget` was confirmed via a live `winget search fastfetch` on the dev machine returning exactly `Fastfetch-cli.Fastfetch`; `packages.scoop` matches the locally scoop-installed `fastfetch`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed"`
Expected: PASS, including `'seed file fastfetch.json exists and passes schema validation'`.

- [ ] **Step 5: Delete the old plugin**

```bash
git rm Tools/winfetch.json
```

- [ ] **Step 6: Re-run the full schema test file to confirm nothing else regressed**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed"`
Expected: PASS, same as Step 4 (deleting `winfetch.json` doesn't affect this file since it's no longer in `$seedFiles`).

- [ ] **Step 7: Commit**

```bash
git add Tools/fastfetch.json tests/Test-DFToolSchema.Tests.ps1
git commit -m "$(cat <<'EOF'
feat(tools): replace abandoned winfetch with fastfetch

winfetch is unmaintained upstream; fastfetch is its actively maintained
successor and is natively XDG-aware. Ships a seeded catppuccin-mocha
config via the existing xdg.method: config path (Tools/fastfetch.json's
config_content) -- publicip is deliberately omitted: it measured a
2.87s cold-path spike from its network lookup during design (see
docs/superpowers/specs/2026-09-06-fastfetch-tool-swap-design.md).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WS88pgBkJSmBUEbgZRL2KC
EOF
)"
```

---

### Task 2: Promote fastfetch and retire winfetch in the category database

**Files:**
- Modify: `build/categories/dotforge-curated.jsonc`
- Modify: `build/categories/extras.jsonc`
- Modify (generated, do not hand-edit content): `data/tool-categories.json`
- Modify (generated, do not hand-edit content): `data/tool-identities.json`
- Test: `tests/Build-DFCategoryDb.Tests.ps1`, `tests/Build-DFToolIdentities.Tests.ps1` (existing — used to verify, not modified)

**Interfaces:**
- Consumes: `Tools/fastfetch.json`'s `packages` block from Task 1 (must match the `ids` added here).
- Produces: `data/tool-categories.json` / `data/tool-identities.json` entries under key `"fastfetch"`; no entry under `"winfetch"` in either file. Later tasks don't depend on these directly, but the full test suite (Task 5) does.

- [ ] **Step 1: Remove the `winfetch` entry from `dotforge-curated.jsonc`**

In `build/categories/dotforge-curated.jsonc`, delete:

```json
  "winfetch": {
    "function": ["system-info"], "worksWith": ["filesystem"], "interface": "cli",
    "alternativeTo": ["neofetch"],
    "ids": { "scoop": "winfetch" },
    "relatedTo": ["fastfetch"], "popularity": 1
  },
```

- [ ] **Step 2: Add the `fastfetch` entry to `dotforge-curated.jsonc`**

In `build/categories/dotforge-curated.jsonc`, insert between the `"eza"` and `"fd"` entries:

```json
  "fastfetch": {
    "function": ["system-info"], "worksWith": ["filesystem"], "interface": "cli",
    "alternativeTo": ["neofetch"],
    "ids": { "scoop": "fastfetch", "winget": "Fastfetch-cli.Fastfetch" },
    "relatedTo": ["winfetch"], "popularity": 1
  },
```

(so the file reads `"eza": {...}, "fastfetch": {...}, "fd": {...}` in that order — exact position doesn't affect the build, `Build-DFCategoryDb.ps1` sorts its output alphabetically, this is just for a readable diff.)

- [ ] **Step 3: Remove the now-duplicate `fastfetch` entry from `extras.jsonc`**

In `build/categories/extras.jsonc`, delete:

```json
  "fastfetch": {
    "function": ["system-info"], "worksWith": ["filesystem"], "interface": "cli",
    "alternativeTo": ["neofetch"], "relatedTo": ["winfetch"], "popularity": 1
  },
```

(Leaving this in place alongside Step 2's addition would make `Build-DFCategoryDb.ps1` throw: `"duplicate tool key 'fastfetch' in extras.jsonc (already defined in dotforge-curated.jsonc)"`.)

- [ ] **Step 4: Regenerate `data/tool-categories.json`**

Run: `pwsh -NoProfile -File build/Build-DFCategoryDb.ps1`
Expected output: `Wrote <repo>/data/tool-categories.json (<N> tools)` with no thrown error. Then verify the swap landed:

Run: `pwsh -NoProfile -Command "(Get-Content data/tool-categories.json -Raw | ConvertFrom-Json).tools.PSObject.Properties.Name -contains 'fastfetch'"`
Expected: `True`

Run: `pwsh -NoProfile -Command "(Get-Content data/tool-categories.json -Raw | ConvertFrom-Json).tools.PSObject.Properties.Name -contains 'winfetch'"`
Expected: `False`

- [ ] **Step 5: Run the category DB test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Build-DFCategoryDb.Tests.ps1,tests/Get-DFCategoryDb.Tests.ps1,tests/Get-DFCategoryList.Tests.ps1,tests/Update-DFCategoryDb.Tests.ps1 -Output Detailed"`
Expected: PASS (these tests use their own fixtures per the `[Unreleased]` CHANGELOG entry about `Get-DFCategoryDb.Tests.ps1`/`Get-DFCategoryList.Tests.ps1` no longer touching the real ambient data file, so this regeneration doesn't affect them).

- [ ] **Step 6: Regenerate `data/tool-identities.json`**

Run: `pwsh -NoProfile -File build/Build-DFToolIdentities.ps1`
Expected: completes without throwing (uses cached catalog lookups by default, no `-Fresh` needed for a routine regen — this independently re-verifies the `scoop`/`winget` IDs from Task 1 against live catalogs, beyond the manual `winget search` already done during design).

Run: `pwsh -NoProfile -Command "(Get-Content data/tool-identities.json -Raw | ConvertFrom-Json).tools.PSObject.Properties.Name -contains 'fastfetch'"`
Expected: `True` (same `{ schemaVersion, updated, tools: { ... } }` top-level shape as `tool-categories.json` — confirmed by inspection).

Run: `pwsh -NoProfile -Command "(Get-Content data/tool-identities.json -Raw | ConvertFrom-Json).tools.PSObject.Properties.Name -contains 'winfetch'"`
Expected: `False`

Run: `git diff --stat data/tool-identities.json`
Expected: shows changes (winfetch's entry removed, fastfetch's added).

- [ ] **Step 7: Run the identity guide test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Build-DFToolIdentities.Tests.ps1,tests/Get-DFToolIdentityGuide.Tests.ps1,tests/Update-DFToolIdentityGuide.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add build/categories/dotforge-curated.jsonc build/categories/extras.jsonc data/tool-categories.json data/tool-identities.json
git commit -m "$(cat <<'EOF'
build(categories): promote fastfetch to curated, retire winfetch

fastfetch now ships a real Tools/fastfetch.json (previous commit), so its
category entry moves from extras.jsonc (known-but-unshipped) into
dotforge-curated.jsonc with resolved package ids. winfetch's curated
entry is removed. Regenerated via Build-DFCategoryDb.ps1 and
Build-DFToolIdentities.ps1 -- these files are build-generated, never
hand-edited.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WS88pgBkJSmBUEbgZRL2KC
EOF
)"
```

---

### Task 3: Documentation and changelog housekeeping

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`
- Modify: `CHANGELOG.md`
- Delete: `fastfetch.config.jsonc` (repo root)

**Interfaces:**
- Consumes: nothing new from earlier tasks (pure prose updates referencing `fastfetch`/`Tools/fastfetch.json`, already created in Task 1).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update README's Included Tools table**

In `README.md`, in the "Included Tools" table, change the System row from:

```
| System           | procs, winfetch, gsudo                             |
```

to:

```
| System           | procs, fastfetch, gsudo                            |
```

- [ ] **Step 2: Close the TODO.md item**

In `TODO.md`, replace:

```
  - `winfetch` — unrelated to theming, but flagged in the same pass: winfetch is abandoned
    upstream. Replace the `Tools/winfetch.json` entry with `fastfetch` (its actively maintained
    successor) — a tool-swap task, not a theming task; update `Tools/*.json`, README's Included
    Tools table (currently lists `winfetch` under "System"), and any doc/example references.
```

with:

```
  - [x] `fastfetch` — closed 2026-09-06: replaced `Tools/winfetch.json` with `Tools/fastfetch.json`
    (winfetch is abandoned upstream). Ships a seeded catppuccin-mocha config via the existing
    `xdg.method: "config"` path; `publicip` deliberately omitted (measured 2.87s cold-path spike).
    See `docs/superpowers/specs/2026-09-06-fastfetch-tool-swap-design.md`.
```

matching the file's existing convention of converting a closed plain-bullet item to a `- [x]` line with a closure note (see the `lsd` item a few lines above it in the same list).

- [ ] **Step 3: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the empty `## [Unreleased]` heading, add:

```markdown
## [Unreleased]

### Changed

- **Replaced the abandoned `winfetch` plugin with `fastfetch`.** `winfetch` is unmaintained
  upstream; `fastfetch` is its actively maintained, natively XDG-aware successor.
  `Tools/fastfetch.json` seeds a catppuccin-mocha themed config at
  `$XDG_CONFIG_HOME/fastfetch/config.jsonc` (only when absent) via the existing
  `xdg.method: "config"` path. `publicip` is deliberately excluded from the seeded module list —
  it measured a 2.87s cold-path network spike during design.
```

- [ ] **Step 4: Remove the root-level scratch config file**

```bash
git rm fastfetch.config.jsonc
```

Its content is now the single source of truth inside `Tools/fastfetch.json`'s `config_content` (Task 1) — keeping a second standalone copy would let the two drift.

- [ ] **Step 5: Commit**

```bash
git add README.md TODO.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: update README/TODO/CHANGELOG for the fastfetch swap; drop scratch config

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WS88pgBkJSmBUEbgZRL2KC
EOF
)"
```

(the `git rm` from Step 4 stages itself; this commit picks up that deletion along with the doc edits since they're the same logical change)

---

### Task 4: Document the optional startup banner in example profiles

**Files:**
- Modify: `examples/01-minimal.ps1`
- Modify: `examples/02-standard.ps1`

**Interfaces:**
- Consumes: `fastfetch.exe` as the executable name (from `Tools/fastfetch.json`, Task 1).
- Produces: nothing consumed elsewhere — this is the terminal documentation step for the "optional startup banner" requirement.

- [ ] **Step 1: Add the banner block to `examples/02-standard.ps1`**

In `examples/02-standard.ps1`, after the closing `}` of `$DFConfig = @{ ... }` and the `Import-Module DotForge` line (i.e., directly before the `# ── First-run bootstrap ──` section), insert:

```powershell
# ── Optional: lightweight system-info banner ──────────────────────────────────
# Uncomment to show a one-shot system summary at the top of every new shell.
# The bundled fastfetch config has no logo and skips network-dependent
# modules, so this stays fast even on a cold shell.
# if (Get-Command fastfetch.exe -ErrorAction Ignore) { fastfetch }

```

- [ ] **Step 2: Add a one-line pointer in `examples/01-minimal.ps1`**

In `examples/01-minimal.ps1`, after the `Register-DFTool -All` line, append:

```powershell

# Optional lightweight system-info banner: see examples/02-standard.ps1's
# "Optional: lightweight system-info banner" section.
# if (Get-Command fastfetch.exe -ErrorAction Ignore) { fastfetch }
```

- [ ] **Step 3: Sanity-check both files still parse as valid PowerShell**

Run: `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('examples/01-minimal.ps1', [ref]$null, [ref]$errors); $errors.Count"`
Expected: `0`

Run: `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('examples/02-standard.ps1', [ref]$null, [ref]$errors); $errors.Count"`
Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add examples/01-minimal.ps1 examples/02-standard.ps1
git commit -m "$(cat <<'EOF'
docs(examples): document optional fastfetch startup banner

Documentation-only per the approved design -- no new $DFConfig key, no
core hook. Register-DFTool never runs a tool's executable as a side
effect of registration, and this doesn't change that.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WS88pgBkJSmBUEbgZRL2KC
EOF
)"
```

---

### Task 5: Full verification pass

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing — this is the final gate before considering the plan done.

- [ ] **Step 1: Run the full Pester suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: PASS, 0 failed. (Run from `pwsh -NoProfile` per `CLAUDE.md`'s testing guidance, to avoid profile interference.)

- [ ] **Step 2: Confirm no remaining `winfetch` references outside historical docs**

Run: `grep -rli winfetch Tools/ README.md tests/ build/categories/ data/ examples/`
Expected: no output (empty — `TODO.md`'s closure note in Task 3 and the design spec's own historical mentions are outside this file set and are expected to still mention `winfetch` by name).

- [ ] **Step 3: Manual smoke test — seed the config on first registration**

```powershell
Import-Module ./DotForge.psd1 -Force
$Env:XDG_CONFIG_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
Initialize-DFEnvironment
Register-DFTool -Name fastfetch
Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc')
```

Expected: `True`. Then confirm the seeded file actually renders:

```powershell
fastfetch --config (Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc')
```

Expected: real system info printed (OS, kernel, uptime, shell, terminal, CPU, GPU, memory, display, local IP, disk, physical disk lines), no error, no `publicip`/public-IP line.

- [ ] **Step 4: Manual smoke test — second registration does not overwrite a user edit**

```powershell
Add-Content (Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc') "`n// user edit marker"
Register-DFTool -Name fastfetch
Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc') -Raw | Select-String 'user edit marker'
```

Expected: the marker is still present (match found) — proves `Set-DFToolXdgConfig`'s existing "seed only when absent" behavior applies to fastfetch exactly as it does to every other `'config'`-method tool, with no fastfetch-specific code needed.

- [ ] **Step 5: Clean up the scratch XDG dir from Steps 3-4**

```powershell
Remove-Item -Recurse -Force $Env:XDG_CONFIG_HOME
```

No commit for this task — it's verification only. If Step 1 or 2 turns up a failure, fix it in the task that introduced it and re-run this task from Step 1.
