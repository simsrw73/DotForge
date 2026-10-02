# DotForge Architectural Audit

**Date:** 2026-09-04  
**Scope:** Current DotForge PowerShell module, especially profile startup, the registry, companions, public interface, catalog subsystem, and tests. No source changes were made.

## Executive assessment

DotForge is well designed at its core. Its key seam is effective: Tools/name.json holds stable declarative facts, while a same-basename PowerShell companion handles tool-specific imperative initialization. That gives profiles a compact interface: import the module, initialize XDG directories, then register tools.

The code reflects careful real-world PowerShell work: conditional tool registration, dependency ordering, XDG normalization, PATH deduplication, external-command test seams, cache handling, and excellent documentation of vendor behaviors.

The main pressure point is Register-DFTool. It now owns record selection, configuration, availability checks, XDG/env mutation, aliases, dynamic picker construction, companion execution, completion setup, and conflict reporting. It remains functional, but is the central source of future change risk. The second concern is session ownership: registrations deliberately create global aliases/functions and change environment, PSReadLine, completions, cd, and prompt behavior, but there is no explicit record of what DotForge owns or controlled reset mechanism.

**Conclusion:** strong foundation; refactor incrementally around the current registry/sidecar architecture rather than replacing it with a generic plugin framework.

## Strong design choices

### Registry plus companion sidecar is the right depth

The JSON registry describes facts that should be data: package mappings, XDG policy, environment variables, aliases, picker declarations, and dependencies. Companions contain vendor-generated initialization and behaviors that are not honestly representable as data. This is a deep module: profile callers learn a small interface while the registry hides a large amount of per-tool knowledge.

Import-DFToolDb, Test-DFToolSchema, and cached records create a coherent registry read path. Invoke-DFTopoSort makes dependsOn actual behavior. The approved one-time setup lifecycle design preserves this seam correctly: persistent actions belong in a setup companion, not in a growing JSON action language.

### Good profile defaults and idempotence

Initialize-DFEnvironment has a focused purpose, and Add-DFToPath centralizes normalization, deduplication, and precedence instead of letting each tool manipulate PATH. Registration is conditional on installed tools, does not install packages automatically, and the cache maintenance flow leaves scheduling to the user.

### Mostly idiomatic PowerShell

The module uses a manifest to control its exported surface, approved verb-noun names, CmdletBinding, comment-based help, Pester, and SupportsShouldProcess on installation. Private wrappers around fzf, command capture, SQLite, and catalog fetches are useful seams for tests. The catalog providers are reasonable private adapters that normalize results for a common public experience.

## Findings and recommendations

### 1. High: split Register-DFTool into private phases

**Evidence:** Public/Register-DFTool.ps1 handles selection, role resolution, availability, XDG and env changes, aliases/functions, picker generation, sidecar loading, completion configuration, and conflict reporting.

**Why it matters:** This is a wide internal interface. Every new registry capability changes the same function, and ordering/scope interactions are difficult to reason about.

**Recommendation:** retain Register-DFTool as the single public facade, but extract private helpers:

- Resolve-DFRegistrationPlan: load, skip, availability, dependency order, and role-winner resolution; return a normalized plan.
- Set-DFToolSessionEnvironment: declarative XDG and env changes only.
- Register-DFToolAliases and Register-DFToolPicker: translate record data into commands.
- Invoke-DFToolCompanion: establish and clear sidecar context with an explicit error policy.
- Initialize-DFRegisteredToolFeatures: completion and conflict work after registration.

Do not export these helpers or introduce a plugin framework. This is a behavior-preserving refactor that improves locality and focused testing.

**Priority/effort:** high value, medium effort.

### 2. High: define session ownership and collision policy

**Evidence:** registration and sidecars create global aliases/functions, change process environment and key handlers, and vendor init can redefine cd, prompt, or argument completers. Repeated or selective registration can happen in different orders.

**Why it matters:** ambient state is appropriate for profile setup, but stale registrations may remain after configuration or default-tool changes. Current ordering behavior is correct only because several relationships are carefully documented.

**Recommendation:** define three ownership classes: manifest exports, DotForge-created session registrations, and controlled external generated initialization. Track DotForge-owned aliases/functions and their prior definitions in private session state; add an internal reset path for tests/reloads. Defer a public unregister command until safe restoration semantics are designed. Detect unresolved collisions between selected records and warn rather than silently choosing last writer.

**Priority/effort:** high value, medium-to-high effort.

### 3. High: distinguish one-time persistent setup from session registration

**Evidence:** Tools/mdv.ps1 seeds user-visible config; Tools/carapace.ps1 synchronizes shipped specs; vivid writes cache. The approved setup-lifecycle design identifies this distinction already.

**Recommendation:** implement that approved lifecycle primitive and migrate only user-owned defaults needing run-once-then-back-off semantics; mdv is the concrete candidate. Keep cache and shipped-spec synchronization as repeatable registration work with change guards. Do not merge the three lifetimes into one mechanism.

**Priority/effort:** high value, low-to-medium effort. Coordinate with the agent currently implementing lifecycle changes; this is not a competing design.

### 4. Medium: validate registry structure more strongly

**Evidence:** Test-DFToolSchema only requires name/executable and validates two enums; core code repeatedly probes dynamic fields.

**Recommendation:** keep fields optional, but validate each field when present. Add a database-level pass for case-insensitive duplicate names, dependencies, self-dependencies/cycles, alias and picker shape, supported package managers, and role coherence. Report all defects at load time. A typed normalized internal record could help later, but stricter validation provides most value without adding serialization complexity.

### 5. Medium: normalize global configuration behind one read interface

**Evidence:** global DFConfig is read by registration, installation, completion, themes, conflict handling, and sidecars. PSScriptAnalyzer reported global-variable warnings in the representative core set.

**Recommendation:** preserve DFConfig as the user-facing backward-compatible input, but add a private Get-DFConfiguration that reads once, validates known keys, fills defaults, and returns a normalized snapshot. Pass that snapshot through the registration plan. Keep deliberately live theme/session state separate and clearly named as state.

### 6. Medium: contain executable strings and host-only output

**Evidence:** picker lists/actions use scriptblock creation; vendor init uses Invoke-Expression. The latter are documented vendor patterns. PSScriptAnalyzer also reported Write-Host warnings in environment/install code.

**Recommendation:** preserve vendor init where required, but centralize it in a documented generated-initialization helper with narrow source ownership. Prefer interpreted registry data or a sidecar for DotForge-authored behavior; do not make arbitrary script strings the general extension mechanism. Add negative schema tests for remaining executable strings.

For normal status, prefer Write-Information or Write-Verbose; reserve Write-Host for intentional host UI. Keep ShouldProcess for persistent/destructive public actions, but ignore the analyzer false positives for private in-memory New object constructors.

### 7. Medium: make module load deterministic and profile performance measurable

**Evidence:** DotForge.psm1 loads all private/public files through unsorted Get-ChildItem. Five forced imports measured 332.6 to 499.9 ms, 344.9 ms median, with 40 exported functions and 27 aliases.

**Recommendation:** sort source paths during module load now. Then measure the complete profile in stages: Import, Initialize, and Register. If optimization is justified:

1. Cache tool availability for a registration pass to avoid repeated Get-Command/module discovery.
2. Lazily load catalog providers/formatters on first catalog command if profiling identifies import cost as important.
3. Keep expensive external work out of default registration; preserve existing cache guards.
4. Keep the existing in-session registry cache; do not persist parsed JSON without evidence it matters.

Do not split DotForge into several independently imported modules yet; that increases profile complexity before a measured need exists.

### 8. Low: selectively share package-manager picker flow

Scoop, WinGet, and Chocolatey sidecars contain similar search/install/remove/update picker behavior. Extract only the common UI flow into a private coordinator with provider callbacks; retain package-manager APIs and elevation policy in sidecars. Do this after registration orchestration is decomposed, and only if the next feature would duplicate the same flow again.

### 9. Low: improve test isolation and declare the supported Pester version

Tests provide strong coverage, but many dot-source private files and manually clean global state. Add shared fixtures for aliases, global variables, environment, PSReadLine handlers, and temporary records. Maintain private tests where they validate a real seam, but add registration-plan/public integration cases too.

The repository guidance says Pester 5; this environment has Pester 6.1. Establish the supported version in a manifest or documented bootstrap and run a normal-environment CI baseline.

## PowerShell best-practice conclusion

DotForge generally follows PowerShell idioms well. Its global state, global aliases/functions, host output, and vendor Invoke-Expression are deliberate profile tradeoffs rather than simple mistakes. They need containment and ownership documentation, not a blanket ban. Avoid a remove-all-globals/Invoke-Expression/Write-Host cleanup: that would weaken an interactive profile module without guaranteeing better behavior.

## Recommended order of work

1. Complete the approved one-time setup lifecycle; then migrate mdv if appropriate.
2. Refactor Register-DFTool into a registration plan and private phases.
3. Add configuration normalization and registry/database validation.
4. Add session ownership/collision tracking and a test-only reset path.
5. Establish a normal-environment Pester baseline and profile full startup.
6. Only then pursue lazy catalog loading or picker-flow consolidation if measured or feature-driven.

## Verification performed

- Static inspection of the manifest/load path, public/private functions, registry/schema, companions, completion flow, catalog architecture, examples, relevant design documents, and tests.
- Five forced module imports succeeded: 332.6 to 499.9 ms, 344.9 ms median; 40 functions and 27 aliases exported.
- PSScriptAnalyzer 1.25 on representative core files found expected global-state and host-output warnings plus a generated-picker unused-parameter warning. A broad run also reported a stale suppression-attribute error in Register-DFTool; broad output contained unrelated installed-script noise, so no repository-wide warning total is claimed.
- Focused Pester execution could not run test bodies: sandboxed Pester 6.1 was denied registry access while creating HKCU Software Pester. This is an environment limitation, not evidence of failing DotForge tests.

