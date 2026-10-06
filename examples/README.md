# DotForge profile examples

**Audience:** DotForge users setting up or reorganizing their PowerShell profile.  
**Topic:** complete example profiles to copy, and what each one is for.  
**Goal:** pick the example closest to what you want and use it as your `$PROFILE`.

Copy one of these files as your `$PROFILE` starting point, or borrow parts of them. Examples 01–04 are complete profiles that the test suite runs in a sandbox; 05–07 are walkthroughs of interactive commands.

| File | When to use |
| --- | --- |
| `01-minimal.ps1` | Getting started, CI, shared machines: no configuration |
| `02-standard.ps1` | A typical setup: `$DFConfig`, plus installing missing core tools on first run |
| `03-selective.ps1` | A lean startup: register tools in groups instead of all at once |
| `04-vscode-fastpath.ps1` | A full profile with a lighter path for VS Code's terminal |
| `05-trifle-catalog.ps1` | Package catalog lookups (`trifle`) and a scheduled cache refresh |
| `06-winget-pickers.ps1` | winget pickers (`wins`, `wrm`, `wup`) and their keys |
| `07-scoop-choco-pickers.ps1` | scoop (`sins`, `srm`, `sup`) and Chocolatey (`cins`, `crm`, `cup`) pickers |

## Quick start

The smallest useful profile, the same as `01-minimal.ps1`:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

## Common patterns

### Install missing tools on first run

Each tool record knows its real executable (ripgrep's is `rg.exe`), so check that instead of guessing:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
$missing = @('eza', 'bat', 'fzf', 'ripgrep') | Where-Object {
    -not (Get-Command (Get-DFTool -Name $_).executable -ErrorAction Ignore)
}
if ($missing) { Install-DFTool -Name $missing -WhatIf }
```

Remove `-WhatIf` to install for real.

### Query the registry

```powershell
Import-Module DotForge
Get-DFTool -Tag pager | Sort-Object name | Select-Object -ExpandProperty name
```

```text
bat
delta
less
moor
ov
```

For themes, choosing between eza and lsd, and skipping tools, see the [configuration guide](../docs/guide/configuration.md). For everything else, start at the [documentation index](../README.md#documentation).
