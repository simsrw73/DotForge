# Split the startup core from on-demand code: design

**Status:** approved 2026-10-10 · **Decided in:** a short design session (decisions 1–5 are the user's or follow from spikes) · **Backlog item:** TODO.md, Architecture Backlog, "Split the startup core from on-demand code"

## Context

`Import-Module DotForge` takes about 0.7 s of a 2.25 s start (the user's config, median of 7, 2026-10-10). Measured:

| Cost | Time |
| --- | --- |
| Dot-sourcing 102 files one by one | 670–720 ms |
| The same code as one file | about 400 ms |
| The core's code alone, as one file | 36–81 ms |
| Load-time work of the 7 package-catalog providers (compiling large files) | about 300 ms |

About half the code (the package catalog behind `trifle`, the general helpers) is never used while a shell starts, but it loads eagerly.

## Decisions

| # | Decision |
| --- | --- |
| 1 | **Real nested modules, auto-loaded by PowerShell.** `DotForge.Catalog` and `DotForge.Helpers` live in `Modules/` inside the DotForge folder and ship in the same Gallery package. `DotForge.psm1` adds `Modules/` to the session's `PSModulePath`, so PowerShell loads each module on first use of one of its commands. `Get-Help` and parameter completion keep working. |
| 2 | **`Get-DFConfig` becomes public** (read-only), so the on-demand modules read session settings (`Defaults`, `Theme`) from the core. |
| 3 | **Stateless helpers live in `Shared/`**, which each module dot-sources (its own copy, one source on disk). Session state stays in the core. |
| 4 | **Every alias stays in the core**, pointing at functions in the on-demand modules. A spike showed that an alias exported by a not-yet-loaded module loses to a program of the same name on PATH (`env`, `which`, `touch`, `paste` and `fzf` collide on the user's machine). A core alias always wins and auto-loads its target by function name (26 ms in the spike). |
| 5 | **Bundling the core** (one generated file, used when its hash matches the sources; otherwise the separate files load) is the last step, measured on its own and dropped if it doesn't pay. |

## Placement (computed from the call graph, 2026-10-10)

- **`Modules/DotForge.Catalog`:** `Find-DFPackage`, `Select-DFPackage`, `Update-DFPackageCache`, `Get-DFCategoryList`, `Update-DFCategoryDb`, `Update-DFToolIdentityGuide`, and the private code only they reach: the `DFCatalog*` providers, release data, categories, identity guide/linkage/schemas, readme, GitHub info, SQLite, XML, the info cards, the refresh job. The `DotForge.ToolInfo` type data moves here.
- **`Modules/DotForge.Helpers`:** the `DFHelpers.*` files except the pager, and their private helpers (`Format-DFCliHelpText`, `Get-DFHelpTopicList`, `Invoke-DFCommandCapture`, `Resolve-DFCliHelpFlag`).
- **`Shared/`:** what the core and an on-demand module both reach and that holds no session state: `ConvertTo-DFPath` (with `Get-DFXdgPath`), `Write-DFFileAtomic`, `Get-DFFingerprintCache`, `Import-DFToolDb`, `Get-DFToolRegistry`, `Test-DFToolSchema`, `Get-DFPackageRef`, `Invoke-DFFzf`, `Invoke-DFPagerExe`, `Test-DFOutputPiped`, `New-DFDirectory`, `Invoke-DFPicker`, `DFHelpers.Pager` (`Invoke-DFWithPager`), `Format-DFInstallCommand` (with `Get-DFInstallHint`) and `DFInstallSource`. A shared public function is exported only by the core; the on-demand modules' copies stay private.
- **Core:** everything else, including install and the package-manager pickers the scoop/winget/choco sidecars use at startup.

## Contract (tests)

- After `Import-Module DotForge`, neither on-demand module is loaded, yet `Get-Command Find-DFPackage` resolves (auto-loading `DotForge.Catalog`), and the `trifle`/`env`/`which` aliases are core aliases whose targets resolve.
- Each manifest's `FunctionsToExport` equals its `Public/` functions; `AliasesToExport` is set only in `DotForge.psd1`, and every alias target is exported by one of the three modules. The three manifests have the same version.
- `Get-DFConfig` is exported and returns the session's value.
- No file in `Shared/` reads session state (`$script:DFSession*`).
- Startup is measured before and after each step.
