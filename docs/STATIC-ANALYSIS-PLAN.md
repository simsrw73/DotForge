# Static analysis plan

PSScriptAnalyzer runs over every tracked script, informational for now: `build/Invoke-DFLint.ps1`
locally, and the `lint` job in CI, which writes the summary to the run's page and never fails it. This
page orders the work of bringing the findings down. It is part of T-88 (make DotForge strict safe);
after it come strict checks during the test run.

```powershell
pwsh -NoProfile -File build/Invoke-DFLint.ps1                                  # summary by rule
pwsh -NoProfile -Command "./build/Invoke-DFLint.ps1 -Rule AvoidUsingEmptyCatchBlock -Detailed"  # one rule, every finding
```

## Rules

- **Every default rule runs.** `PSScriptAnalyzerSettings.psd1` excludes only `PSUseBOMForUnicodeEncodedFile`
  (a BOM matters only to Windows PowerShell 5.1; DotForge requires 7).
- **Tests are barely relaxed.** `tests/PSScriptAnalyzerSettings.psd1` also excludes the naming and
  ShouldProcess rules, which a stub named after what it replaces breaks by design. Globals, unused
  variables and parameters stay on: tests have shipped bugs that strict checking would have caught.
- **Fix with the idiom, not a suppression.** Each rule below names the usual fix. A deliberate exception
  gets `[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSRuleName', '', Justification = '…')]` on
  its function or `param()` block, with a real reason. Never a new exclusion in the settings files
  without one that holds everywhere.

## Baseline (2026-10-27, PSScriptAnalyzer 1.25.0)

1,363 findings in 292 of 483 files: 464 shipped, 103 build/examples, 796 tests. No errors.

## Order of work

Highest bug-catching value per finding first; volume last. Each step is one or a few commits, run with
`-Rule` on the rules it covers.

### 1. Findings that are, or hide, real problems (~100)

| Rule | Shipped | Build | Tests | Fix |
|---|---:|---:|---:|---|
| ShouldProcess | 9 | | | A function that calls `$PSCmdlet.ShouldProcess` without `SupportsShouldProcess` never receives `-WhatIf`; one that declares it and only delegates should pass its `$PSCmdlet` on, or the helper should declare it. Check each one honors `-WhatIf`. |
| AvoidUsingCmdletAliases | | | 13 | `DFPackageUniverse.Merge.Tests.ps1` removes the global `r` alias for a helper `R`, then recreates it with `-Scope Global`: give the helper a real name, and touch no builtin. `ls` → `Get-ChildItem`. |
| AvoidOverwritingBuiltInCmdlets | | | 1 | `DFPackageUniverse.Links.Tests.ps1` defines `Node`, a builtin: rename. |
| UseDeclaredVarsMoreThanAssignments | 5 | 2 | 18 | Drop dead assignments (`{ $rows = … } \| Should -Not -Throw` → `$null = …`). `$DFCurrentTool` read by a dot-sourced sidecar and the `$_df*` closure variables in `New-DFToolWrapper` are real uses: suppress with that reason. |
| AvoidUsingEmptyCatchBlock | 14 | 5 | 2 | Avoid the throw (`[datetime]::TryParse`, `-ErrorAction Ignore`), or say why in `Write-Debug`. |
| UseUsingScopeModifierInNewRunspaces | 14 | | | Thread jobs take values through `-ArgumentList` + `param()`; switch to `$using:`, which also reads more plainly. |
| UseCmdletCorrectly | 1 | | 8 | Name the parameter: `Write-Output -NoEnumerate -InputObject $x`; the same for `ConvertTo-Json`. |
| PossibleIncorrectComparisonWithNull | 4 | | | `@($x) -ne '' -ne $null` filters an array on purpose; write it as `@($x \| Where-Object { $_ })`. |
| AvoidDefaultValueSwitchParameter | 1 | | | `Get-DFCategoryList -Counts` defaults to `$true`: a switch that defaults on can't be turned off without `:$false`. Make it `-NoCounts`, or a `[bool]`. |
| UseLiteralInitializerForHashtable | 1 | | | `Tools/psreadline.ps1:53` `[hashtable]::new()` is case-sensitive; `@{}` unless that matters. |
| UseApprovedVerbs | | 1 | | `Render-WithTheme` in a conformance probe. |

### 2. Strict tests (~435)

| Rule | Tests | Fix |
|---|---:|---|
| AvoidGlobalVars | 242 | Most (`$global:DFTestNative`, `RoleCalls`, `DFTestActivated`, …) record calls from mocks. A `Mock` body runs in the test file's script scope, so `$script:` works and nothing leaks into later files. Keep `$global:` only where a child scope that can't see `$script:` sets it (a sidecar's global function), removed with `Remove-DFTestGlobal`. |
| ReviewUnusedParameter | 193 | A `Mock` body needs no `param()`: Pester binds the parameters as variables. An injected seam whose signature is fixed (a `$spawn` scriptblock) suppresses on its `param()`, with the seam as the reason. |

### 3. Shipped API hygiene (~175)

| Rule | Shipped | Build | Fix |
|---|---:|---:|---|
| ReviewUnusedParameter | 58 | 1 | Remove the parameter, or use it. Role hooks and sidecar functions with a fixed signature (`-Role`, `-Tool`) suppress with that reason. |
| UseShouldProcessForStateChangingFunctions | 58 | 3 | Functions named `New-`/`Set-`/`Remove-`/`Start-`… that change something the user owns get `SupportsShouldProcess` (see step 1). Constructors that only build an object (`New-DFToolStatus`, `New-DFConflictResult`, …) suppress: they change nothing. |
| UseSingularNouns | 26 | 18 | Private names: rename. A global function a `Tools/*.ps1` companion defines is user-facing: keep the name, suppress. |
| AvoidGlobalVars | 10 | | `DFEnvState`, the dotenv location hook and `DFPSReadLineColors` are deliberate session state: suppress with the reason, or move to module scope if nothing outside reads it. |

### 4. Mechanical volume (~650)

| Rule | Shipped | Build | Tests | Fix |
|---|---:|---:|---:|---|
| UseOutputTypeCorrectly | 76 | 16 | 2 | Make `[OutputType()]` match what the function returns. |
| AvoidUsingWriteHost | 51 | 27 | | Console output that is the point of the command (banner, pickers, status) keeps `Write-Host` (it goes to the information stream in PowerShell 7) with a suppression on the function; data goes to the pipeline; diagnostics to `Write-Verbose`/`Write-Warning`. |
| AvoidUsingPositionalParameters | 136 | 30 | 317 | Name the parameters. `Shared/Import-DFToolDb.ps1` alone has 92. |

### 5. Gate it

Once a rule reaches zero, CI fails on it (a `-FailOn` list in `Invoke-DFLint.ps1`), so it stays at zero;
when all are at zero, the `lint` job joins the gate in `build/Test-DFFull.ps1`.
