# Your Own Tools (T-2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** a user tools folder loaded alongside `Tools\`, `New-DFTool` to start a record, and a guide page.
**Spec:** `docs/superpowers/specs/2026-10-11-user-tools-design.md`

## Global Constraints

- Tests isolate XDG (`Set-DFTestXdg`); nothing writes the real `$XDG_CONFIG_HOME`.
- Paths through `ConvertTo-DFPath`; folders through `New-DFDirectory`; `$HOME`, never `~`.
- Rebuild bundle, registry and reference before committing.

## Review Focus

1. A broken user record (bad JSON, schema error) warns and is skipped; the shipped record of that name is not lost silently — it is replaced only by a *valid* user record.
2. A user record whose file name differs from its `name`.
3. The registry record object is never mutated by setting `folder`.
4. `-From` for a tool with a data folder (fzf) and with a seed (fastfetch).
5. A user companion that throws doesn't stop the other tools (existing guard; confirm it still applies).

### Task 1: loader (Shared/Import-DFToolDb.ps1, Shared/ConvertTo-DFPath.ps1 or new Shared file)
RED tests in `tests/Import-DFToolDb.UserTools.Tests.ps1`, then `Get-DFUserToolsPath`, overlay in both paths, `Get-DFToolNames` union, `folder`/`source` fields.

### Task 2: consumers use `$Tool.folder`
`Invoke-DFToolCompanion`, `Invoke-DFToolSeed`, `Import-DFManagerOps`, `Write-DFRemoveLeftover`. Tests: a user record's companion, seed and manage file load from the user folder.

### Task 3: `New-DFTool` (Modules/DotForge.Helpers/Public/New-DFTool.ps1)
RED tests in `tests/New-DFTool.Tests.ps1`, then the command, help, export.

### Task 4: docs, backlog, gate
Guide page, writing-a-tool pointer, CHANGELOG, TODO (Closes T-2), regenerate, full gate, review, merge.
