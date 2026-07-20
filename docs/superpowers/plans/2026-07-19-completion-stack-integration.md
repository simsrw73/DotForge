# Completion Stack Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add inshellisense to DotForge and compose it safely with Carapace, PSFzf, and PSReadLine.

**Architecture:** A private coordinator validates configuration, merges the Carapace bridge, selects the final Tab handler, and starts explicit inshellisense sessions. Carapace prepares its bridge before initialization; Register-DFTool finalizes keybindings once after successfully registering tools.

**Tech Stack:** PowerShell 7+, Pester 5, PSReadLine, PSFzf, Carapace, inshellisense.

## Global Constraints

- Default to CompletionMode = Native; valid values are Native and Inshellisense.
- In Native mode add the inshellisense Carapace bridge only if its executable exists; preserve user bridge entries.
- Apply PSReadLine's edit mode before one final Tab binding.
- PSFzf and inshellisense must not both own Tab.
- Do not set ErrorActionPreference to Stop; use four-space PowerShell indentation.

---

### Task 1: Create the completion-stack coordinator

**Files:**
- Create: Private/Initialize-DFCompletionStack.ps1
- Create: tests/Initialize-DFCompletionStack.Tests.ps1

**Interfaces:**
- Produces: Get-DFCompletionMode, Enable-DFCarapaceInshellisenseBridge, and Initialize-DFCompletionStack -RegisteredTools [string[]].
- Consumes: DFConfig, CARAPACE_BRIDGES, PSReadLine key-handler APIs, and optional Start-DFInshellisense.

- [ ] **Step 1: Write failing mode and bridge tests**

Dot-source the private file in BeforeAll. Restore the global config and bridge environment variable after each case. Test the default mode, invalid mode warning, duplicate bridge preservation, and missing executable behavior.

    Describe 'Get-DFCompletionMode' {
        It 'defaults to Native' {
            Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
            Get-DFCompletionMode | Should -Be 'Native'
        }

        It 'warns and falls back for an invalid value' {
            $Global:DFConfig = @{ CompletionMode = 'invalid' }
            Get-DFCompletionMode -WarningVariable warns 3>$null | Should -Be 'Native'
            $warns | Should -Match 'CompletionMode'
        }
    }

    Describe 'Enable-DFCarapaceInshellisenseBridge' {
        It 'deduplicates the bridge without changing user casing' {
            $Global:DFConfig = @{ CompletionMode = 'Native' }
            $Env:CARAPACE_BRIDGES = 'bash,InShelliSense,fish'
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\bin\is.exe' } }

            Enable-DFCarapaceInshellisenseBridge | Should -BeTrue
            $Env:CARAPACE_BRIDGES | Should -Be 'bash,InShelliSense,fish'
        }
    }

- [ ] **Step 2: Verify failure**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/Initialize-DFCompletionStack.Tests.ps1 -Output Detailed"

Expected: FAIL because the three coordinator functions do not exist.

- [ ] **Step 3: Implement mode and bridge helpers**

Create Private/Initialize-DFCompletionStack.ps1 with script-scope helpers. Get-DFCompletionMode reads Global:DFConfig.CompletionMode and returns Native or Inshellisense case-insensitively; invalid input warns and returns Native. Enable-DFCarapaceInshellisenseBridge returns false unless mode is Native and either is or inshellisense resolves through Get-Command. It splits CARAPACE_BRIDGES on commas, trims values, uses an ordinal-ignore-case HashSet to retain first spelling of every entry, appends inshellisense only if absent, writes the joined list back, and returns true.

- [ ] **Step 4: Verify passing helper tests**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Write failing final-handler tests**

Mock Set-PSReadLineKeyHandler. Assert that:
- Registered PSFzf binds Tab with a script block invoking Invoke-FzfTabCompletion.
- Registered Carapace without PSFzf binds Tab with Function MenuComplete.
- Neither registered component does not call the handler.
- Inshellisense mode without its executable warns and uses the Native result.
- Inshellisense mode with the executable and Start-DFInshellisense calls the starter and does not bind Tab.

- [ ] **Step 6: Verify failure**

Run the Step 2 command. Expected: FAIL because Initialize-DFCompletionStack is missing.

- [ ] **Step 7: Implement final resolution**

Add Initialize-DFCompletionStack -RegisteredTools. Build an ordinal-ignore-case HashSet from only successfully registered names. In Inshellisense mode, find is or inshellisense, then invoke Start-DFInshellisense and return; if unavailable, warn and continue as Native. Bind Tab with a script block only when PSFzf is registered; otherwise bind MenuComplete only when Carapace is registered. Do not touch Tab in all other cases.

- [ ] **Step 8: Verify and commit**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/Initialize-DFCompletionStack.Tests.ps1 -Output Detailed"

Expected: PASS.

    git add Private/Initialize-DFCompletionStack.ps1 tests/Initialize-DFCompletionStack.Tests.ps1
    git commit -m "feat: add completion stack coordinator"

### Task 2: Register inshellisense and finalize after tool registration

**Files:**
- Create: Tools/inshellisense.json
- Create: Tools/inshellisense.ps1
- Modify: Tools/carapace.ps1
- Modify: Tools/PSFzf.ps1
- Modify: Public/Register-DFTool.ps1
- Modify: tests/Register-DFTool.Tests.ps1

**Interfaces:**
- Consumes all Task 1 coordinator functions.
- Produces global Start-DFInshellisense only after the tool record registers.

- [ ] **Step 1: Write a failing registration integration test**

Create minimal Carapace and PSFzf records in the fixture, mock availability and Initialize-DFCompletionStack, call Register-DFTool -All, and assert one finalizer invocation receives both registered names.

    Should -Invoke Initialize-DFCompletionStack -Times 1 -ParameterFilter {
        @($RegisteredTools) -contains 'carapace' -and
        @($RegisteredTools) -contains 'PSFzf'
    }

- [ ] **Step 2: Verify failure**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"

Expected: FAIL because registration never finalizes the completion stack.

- [ ] **Step 3: Add the record and guarded direct-session companion**

Create Tools/inshellisense.json with name inshellisense, executable is, npm package @microsoft/inshellisense, full/default XDG compliance, completion/shell/productivity tags, empty aliases, and null picker.

Create Tools/inshellisense.ps1. It must define Start-DFInshellisense, use is -c with all output discarded, return if its exit code is zero, and otherwise invoke the output of is init pwsh through Invoke-Expression.

- [ ] **Step 4: Wire coordinator ownership**

Immediately before Carapace's existing initializer, call Enable-DFCarapaceInshellisenseBridge and discard its output. Keep PSFzf's Set-PsFzfOption -TabExpansion but remove its direct Set-PSReadLineKeyHandler line.

In Register-DFTool, create a List[string] before the loop. Add a tool name only after it passes availability and its companion completes. Before the existing conflict notice, call Initialize-DFCompletionStack -RegisteredTools $registeredTools.ToArray().

- [ ] **Step 5: Verify and commit**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1,tests/Initialize-DFCompletionStack.Tests.ps1 -Output Detailed"

Expected: PASS.

    git add Tools/inshellisense.json Tools/inshellisense.ps1 Tools/carapace.ps1 Tools/PSFzf.ps1 Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
    git commit -m "feat: integrate inshellisense completion bridge"

### Task 3: Honor configured PSReadLine edit mode

**Files:**
- Modify: Tools/psreadline.ps1
- Create: tests/PSReadLine.Completion.Tests.ps1

**Interfaces:**
- Consumes optional Global:DFConfig.PSReadLineEditMode.
- Produces a Set-PSReadLineOption EditMode call before Task 2's coordinator runs.

- [ ] **Step 1: Write failing companion tests**

Dot-source the companion with minimal DFCurrentTool settings while mocking theme support. Assert that configured Emacs replaces the JSON Windows default, while invalid Vi emits a PSReadLineEditMode warning and retains Windows.

- [ ] **Step 2: Verify failure**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/PSReadLine.Completion.Tests.ps1 -Output Detailed"

Expected: FAIL because the companion ignores PSReadLineEditMode.

- [ ] **Step 3: Implement the override**

After the companion builds its option hashtable and before it applies options, read Global:DFConfig.PSReadLineEditMode. Accept only Windows or Emacs case-insensitively and overwrite the EditMode option; otherwise warn and retain the record value. Leave the existing per-option fallback intact.

- [ ] **Step 4: Verify and commit**

Run: pwsh -NoProfile -Command "Invoke-Pester tests/PSReadLine.Completion.Tests.ps1,tests/Initialize-DFCompletionStack.Tests.ps1 -Output Detailed"

Expected: PASS.

    git add Tools/psreadline.ps1 tests/PSReadLine.Completion.Tests.ps1
    git commit -m "fix: restore completion binding after PSReadLine edit mode"

### Task 4: Document the completion contract

**Files:**
- Modify: README.md
- Modify: docs/external-dependencies.md

- [ ] **Step 1: Update user configuration**

Add CompletionMode = Native and PSReadLineEditMode = Windows to the existing DFConfig example. Add a Completion Stack section explaining Native precedence (PSReadLine, Carapace, optional PSFzf), inshellisense bridge augmentation, explicit direct mode, and the rule that a raw post-registration edit-mode change resets Tab.

- [ ] **Step 2: Update external contracts**

Replace the Carapace/PSFzf Tab notes with the centralized contract: Carapace-only Native sessions use MenuComplete for styled results; PSFzf binds only through the coordinator after edit mode; the bridge is merged only for Native mode with is; direct inshellisense startup is last and guarded by is -c.

- [ ] **Step 3: Full verification and commit**

Run:

    git diff --check
    pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"

Expected: no whitespace errors and a passing suite.

    git add README.md docs/external-dependencies.md
    git commit -m "docs: explain completion stack configuration"

## Plan Self-Review

- **Spec coverage:** Tasks 1–2 implement modes, bridge merging, fallback, direct startup, final Tab precedence, and the tool record. Task 3 handles the edit-mode reset conflict. Task 4 documents configuration and ordering.
- **Placeholder scan:** No task defers required behavior.
- **Type consistency:** Coordinator function names and the RegisteredTools string-array interface are defined in Task 1 and used consistently later.

