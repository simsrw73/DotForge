# Legacy Pickers (T-3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the 11 legacy fzf pickers (reviewed, not copied), let a tool declare several pickers, and settle T-3's leftovers.

**Architecture:** `picker` gains an array form that normalizes to a list; six pickers are declarative JSON, five live in companions and call `Invoke-DFPicker`. Nothing in core names a tool.

**Tech Stack:** PowerShell 7.2+, Pester 6, fzf 0.74.

**Spec:** `docs/superpowers/specs/2026-10-11-legacy-pickers-design.md`

## Global Constraints

- No test runs a real tool or package manager: stub natives as functions, mock `Invoke-DFFzf`.
- Every new alias checked against `Get-Command` (done: all 11 free); none overrides a builtin.
- A sidecar picker calls `Invoke-DFPicker` and its record says `"picker": "custom"` (`tests/Tools.PickerDeclaration.Tests.ps1`).
- Every global function a companion defines has complete comment-based help (`tests/Docs.Help.Tests.ps1`).
- After changing `Tools/*.json`: `./build/Build-DFToolRegistry.ps1`; after `Shared/`/`Private/`/`Public/`: `./build/Build-DFCoreBundle.ps1`; then `./build/Build-DFReferenceDocs.ps1`.
- Use `Get-DFXdgPath`/`ConvertTo-DFPath` for paths; `$HOME`, never `~`, in module code.

## Review Focus

1. A picker run with nothing to list (no containers, no PRs, empty vault, no package.json): a message or a quiet return, never an fzf error or a stack trace.
2. Paths with spaces in czf, fgl, fvenv and fjq previews and actions.
3. fbw: the password never reaches the output stream, a log or a preview; the clear job leaves a clipboard the user changed alone.
4. A record that still uses an object `picker` behaves exactly as before (eza, fd, fzf, zoxide).
5. fjq with a filter containing quotes or `|`: the preview may fail, but Enter must pass the filter to jq intact.

---

### Task 1: `picker` as a list

**Files:** `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFPickerBlock`), `Shared/Test-DFToolSchema.ps1`, `Private/New-DFToolPickerFunction.ps1`, `Public/Get-DFCommandConflict.ps1`, `build/Build-DFReferenceDocs.ps1`; tests `ConvertTo-DFToolRecord`, `Test-DFToolSchema`, `New-DFToolPickerFunction` (or the Register-DFTool picker tests), `AliasOwnership`, `Coreutils.Conflicts`, `Tools.PickerDeclaration`.

- [ ] RED: an object normalizes to a one-element list; an array keeps its order; `"custom"`/null pass through.
- [ ] RED: `picker: [ {ok}, {no list} ]` reports `picker[1].list is required`; a non-object element is an error; typo warnings name `picker[0].`.
- [ ] RED: a two-picker record defines both functions and aliases; `Get-DFCommandConflict` owns both aliases.
- [ ] GREEN, then update the raw-JSON tests and the reference builder (one line per picker). Run the touched tests.

### Task 2: the six declarative pickers

**Files:** `Tools/rustup.json`, `chezmoi.json`, `docker.json` (array), `gh.json` (array); test `tests/Tools.LegacyPickers.Tests.ps1` (new).

- [ ] RED: for each shipped record, the picker's alias/function exist after `New-DFToolPickerFunction`; each `parse` gives the expected value for sample lines: frtc `stable-x86_64-pc-windows-msvc (active, default)` → name; fdc first field; fdi `<none>:<none>  abc123  1GB` → `abc123`, `alpine:3.20  def  8MB` → `alpine:3.20`; fpr/fgi → number. Actions checked by invoking the built function with `Invoke-DFFzf` mocked and the native stubbed.
- [ ] GREEN: the JSON entries per the spec table.

### Task 3: fjq (jq.ps1)
### Task 4: fgl (glow.ps1)
### Task 5: fvenv (uv.ps1)
### Task 6: fns (npm.ps1)
### Task 7: fbw (bitwarden.ps1)

Each: RED tests in `tests/<tool>.Picker.Tests.ps1` for the guards and the action (Review Focus 1–3, 5), then the companion, `"picker": "custom"` in the record, complete help. fbw's clear job: tested by calling its clear step directly with a matching and a changed clipboard (mock `Get-Clipboard`/`Set-Clipboard`).

### Task 8: nano, docs, backlog

- [ ] `Tools/nano.json` (xdg default, compliance full; packages as available); `tests/Tools.*` schema suites pass.
- [ ] `docs/guide/pickers-and-helpers.md` lists the 11 pickers; `docs/guide/writing-a-tool.md` documents the array form; CHANGELOG `Added`; delete T-3 from `TODO.md` (`Closes T-3`).
- [ ] Regenerate registry, bundle, reference; full gate `build/Test-DFFull.ps1`; one fresh reviewer on the branch; fix pass; merge and push.
