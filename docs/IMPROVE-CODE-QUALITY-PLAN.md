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
| 1 — Build the safety net | working-with-legacy-code | pending | TESTING.md + TODO.md (GATE) | |
| 2 — Make the code readable | clean-code | pending | TODO.md | |
| 3 — Apply named refactorings | refactoring-patterns | pending | TODO.md | |
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

## Next Actions
- [ ] Enter Phase 1: record the safety net and its gaps for the starting module (Claude, 2026-10-10)
