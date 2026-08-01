# gsudo sudo precedence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefer gsudo over Windows' built-in sudo when registering DotForge's sudo alias.

**Architecture:** `Register-DFTool` remains generic. The gsudo companion owns precedence and alias setup; elevation consumers declare `dependsOn: ["gsudo"]` and invoke `sudo` after the companion has run.

**Tech Stack:** PowerShell 7, Pester 5.

## Global Constraints

- Do not alter PATH unless gsudo is installed and Windows' `sudo.exe` is the first installed `sudo` command.
- Use `Add-DFToPath` for PATH mutation.
- Preserve ordinary registration and aliases for every other tool.
- Call `sudo`, not `gsudo`, from elevation consumers.

---

### Task 1: Reproduce and fix gsudo precedence

**Files:**
- Modify: `Tools/gsudo.ps1`
- Modify: `Tools/gsudo.json`
- Modify: `Tools/choco.ps1`
- Modify: `Tools/choco.json`
- Create: `tests/gsudo.Tests.ps1`
- Modify: `tests/choco.Tests.ps1`
- Modify: `Public/Add-DFToPath.ps1`
- Modify: `tests/Add-DFToPath.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`

**Interfaces:**
- Consumes: the gsudo companion, `Add-DFToPath -Dir <path> -Prepend`, and `Register-DFTool` dependency ordering.
- Produces: a global `sudo` alias targeting `gsudo` with gsudo's directory at the front of process PATH.

- [ ] **Step 1: Write the failing test**

Add a gsudo companion test that mocks `Get-Command gsudo.exe` as a Scoop shim and `Get-Command sudo` as `C:\\Windows\\System32\\sudo.exe`, then asserts the shim directory starts PATH and `Get-Alias sudo` targets `gsudo`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`

Expected: the new test fails because gsudo's directory is not prepended before alias registration.

- [ ] **Step 3: Write minimal implementation**

Move gsudo-specific discovery and PATH setup from `Register-DFTool` into `Tools/gsudo.ps1`, then create the `sudo -> gsudo` alias there. Remove the declarative gsudo alias. Add `choco -> gsudo` dependency ordering and change Chocolatey's PowerShell and child-process elevation commands to `sudo`.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`

Expected: all tests in the file pass, including the gsudo precedence regression.

- [ ] **Step 5: Run the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`

Expected: full Pester suite passes.
