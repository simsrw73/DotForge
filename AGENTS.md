# Repository Guidelines

## Project Structure & Module Organization

DotForge is a PowerShell 7+ module. `DotForge.psd1` is the manifest and controls exported functions and aliases; `DotForge.psm1` loads module files. Public cmdlets live in `Public/`, internal helpers live in `Private/`, and tool registry records live in `Tools/` as lowercase `<toolname>.json` files with optional same-basename `.ps1` sidecars. Tests are in `tests/` and mirror the function or helper under test, for example `tests/Add-DFToPath.Tests.ps1`. Usage examples are in `examples/`, design notes and plans are in `docs/`, and images are in `assets/`.

## Build, Test, and Development Commands

Use PowerShell 7 from the repository root.

```powershell
Import-Module ./DotForge.psd1 -Force
Invoke-Pester tests/ -Output Detailed
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
./Publish-DotForge.ps1
```

`Import-Module` reloads the local module for development. `Invoke-Pester tests/` runs the full Pester 5 suite; use a single test file while iterating. Run tests from `pwsh -NoProfile` when profile state could affect results. `Publish-DotForge.ps1` is the release helper; do not run it unless preparing a publish.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell files and keep functions focused. Public functions must use the `DF` prefix, such as `Register-DFTool`; private helpers use the same prefix but remain in `Private/`. Add new public functions and aliases to `FunctionsToExport` and `AliasesToExport` in `DotForge.psd1`. Do not set `$ErrorActionPreference = 'Stop'` in module files. Use `New-DFDirectory` for directory creation and `Add-DFToPath` for PATH updates. Public functions need complete comment-based help with synopsis, description, parameters, examples, and outputs.

## Testing Guidelines

Tests use Pester 5 and follow `*.Tests.ps1` naming. Add or update tests with behavior changes, new cmdlets, tool schema changes, or sidecar logic. Mock external tools where possible; avoid spawning interactive processes such as `fzf` in tests.

## Commit & Pull Request Guidelines

Recent history uses concise imperative subjects and conventional prefixes where useful, for example `chore: bump version to 0.1.1-preview` and `fix: stage into DotForge/ subdir...`. Keep commits scoped. Pull requests should describe behavior changes, list test commands run, link related issues or plans, and include screenshots only for README or asset-visible changes.

## Security & Configuration Tips

Do not commit secrets or machine-specific values from `.env`. Tool records should declare package managers, XDG behavior, and dependencies explicitly; validate schema changes with the relevant Pester tests.
