# Improve Code Quality Plan

## Context
Started 2026-10-10 (the `/improve-code-quality` journey; an earlier, unadopted run by another agent lives outside the repo in `DotForge-recovery-2026-10-08/docs/` and was not resumed).

- **What it is:** DotForge, a PowerShell 7 module that configures CLI tools at shell start (XDG paths, pickers, aliases, roles) from a JSON tool database, and installs missing tools on request.
- **Worst failure:** a broken load leaves every new shell without the user's tools and aliases. Next: a wrong install, or overwriting a config file the user edited.
- **Stack:** PowerShell 7, Pester 6. No framework or ORM; no database except read-only SQLite caches of package catalogs.
- **Starting module:** tool registration and session activation (`Register-DFTool`, `Invoke-DFSessionActivation`, `Register-DFToolSteps`) plus the tool-record loader (`Import-DFToolDb`, `Test-DFToolSchema`): the highest 60-day churn (17, 16 and 12 commits) and the core domain.
- **Tests today:** 144 test files, ~2,540 tests, green; a full run with every `XDG_*_HOME` on empty sentinel folders asserts nothing is written there.
- **Production / load:** published to the PowerShell Gallery as a preview; one user on one machine. No server, no request load.
- **Outbound dependencies:** only the package catalog (`trifle`): Chocolatey, crates.io, npm, PowerShell Gallery and PyPI APIs, the GitHub API, release data; plus the package managers `Install-DFTool` runs.

## Phase Status
| Phase | Skill | Status | Artifact | Date |
|---|---|---|---|---|
| 1 — Build the safety net | working-with-legacy-code | done | TESTING.md + TODO.md (GATE) | 2026-10-10 |
| 2 — Make the code readable | clean-code | done (score 7/10; gaps logged with fixes) | TODO.md (Readability) + CLAUDE.md | 2026-10-10 |
| 3 — Apply named refactorings | refactoring-patterns | done (6 structure-only commits) | TODO.md (Readability) | 2026-10-10 |
| 4 — Reduce complexity | software-design-philosophy | pending | TODO.md (Architecture Backlog) | |
| 5 — Draw the architecture boundary | clean-architecture | pending | TESTING.md / this tracker (light) | |
| 6 — Lock in the habits | pragmatic-programmer | pending | TODO.md + CLAUDE.md | |
| 7 — Make it survive production | release-it | pending | TODO.md (catalog network calls) | |
| 8 — Size for real load | system-design | skipped: no server and no request load; one user, one machine | — | 2026-10-10 |
| 9 — Get the data layer right | ddia-systems | skipped: no database writes; SQLite catalog caches are read-only and rebuilt atomically | — | 2026-10-10 |
| Optional — Domain language | domain-driven-design | skipped: the domain vocabulary (tool, role, group, source, feed, session) is already settled in the specs | — | 2026-10-10 |

Statuses: pending · in-progress · awaiting-evidence · done · deferred: <reason> · skipped: <reason>

## Key Decisions
| Date | Phase | Decision | Rationale |
|---|---|---|---|
| 2026-10-10 | Intake | Scope: Phases 1–3, 6, 7 in full; 4 folded into the existing Architecture Backlog; 5 light; 8, 9 and the optional phase skipped. | The user accepted the recommended scope. DotForge is tested already, has no server load and no database writes. |
| 2026-10-10 | Intake | Artifacts: this tracker and `docs/TESTING.md` only. Debt, smells and reliability findings go to `TODO.md` (one backlog), not `TECH-DEBT.md` / `ARCHITECTURE.md` / `RELIABILITY.md`. | The user had just consolidated all audit documents into `TODO.md`; four new documents would split the backlog again. |
| 2026-10-10 | 1 | Bugs found while characterizing are pinned as they are and logged, never silently fixed. | Callers may depend on the quirk; a fix is its own deliberate change. (None found in Phase 1.) |
| 2026-10-10 | 1 | Pinned the three high-priority gaps (tool-record caches, invalid-record activation, git-config guard) before Phase 2; medium/low gaps stay in TESTING.md's backlog until a phase touches them. | Later phases may not touch code in a Gaps column. |
| 2026-10-10 | 1 | The git-config guard lives in `Set-DFTestXdg`/`Restore-DFTestXdg`, not at `TestSupport.ps1` load. | Setting it at load would leak a throwaway git config into an interactive shell that runs `Invoke-Pester`. |
| 2026-10-10 | 2 | Apply fixes 1–5 and 10 in Phase 3 (activation steps, one `+group` expansion, a requirements result object, `Test-DFToolActive`, full loop-variable names, a registration context); log 6–9 (splitting `Test-DFToolSchema`, `ConvertTo-DFToolRecord`, `Get-DFRoleWinners`; a schema result object) in `TODO.md`. | 1–5 and 10 sit in the highest-churn code and are fully covered by the safety net; 6–9 are larger, and 9 churns many tests. |
| 2026-10-10 | 2 | Four readability rules go in CLAUDE.md's Conventions: full names for long-lived variables, result objects over output parameters, split functions past ~60 lines, one home per rule. | Recorded where every agent reads them. |
| 2026-10-10 | 2 | No score gate; re-score at the end of the journey. | There is no CI. |
| 2026-10-10 | 3 | Applied, one commit each, safety-net suites green between steps: Extract Function `Test-DFToolActive`; Rename Variable (full loop-variable names); Replace Output Parameters with a returned result (`Resolve-DFToolRequirements`); Extract Function `Expand-DFGroupEntry` (one home for `+group` expansion); Introduce Parameter Object (the registration context); Extract Function ×6 (the activation's named steps). Done in a worktree, then merged. | The order goes from smallest to largest, so each step's diff stays reviewable; `main` is live in the user's shell. |
| 2026-10-10 | 3 | No preparatory refactoring for an upcoming feature, and no CI gate list (there is no CI). | Nothing is scheduled to land in the activation code next. |

## Next Actions
- [x] Phase 1: safety net mapped (92–98% coverage of the starting module), three high gaps pinned and mutation-checked (Claude, 2026-10-10)
- [x] Phase 2: starting module scored 7/10; top ten fixes ranked; conventions adopted (Claude, 2026-10-10)
- [x] Phase 3: fixes 1–5 and 10 applied as structure-only commits; full suite green (Claude, 2026-10-10)
- [ ] Phase 4: fold into the TODO.md Architecture Backlog (already scoped at intake); then Phase 5 (light) (Claude)
