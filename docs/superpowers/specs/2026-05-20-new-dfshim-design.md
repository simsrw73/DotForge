# New-DFShim — Design Spec

**Date:** 2026-05-20
**Status:** Approved

---

## Context

DotForge configures CLI tools but has no way to make tools that live off `$PATH` invocable without manually editing the system PATH or copying binaries. Shims — small stub executables that forward invocations to the real application — solve this: put one directory on `$PATH` and create shims there as needed.

This spec adds `New-DFShim`, a Layer 3 Tool Operation that generates `.cmd` shim files. It accepts either a raw executable path or a DotForge tool name (DB lookup). The default shim directory is `$HOME\.local\bin` (XDG user-binary convention), configurable via `$DFConfig['ShimsPath']`.

---

## File

| File | Action |
|------|--------|
| `Public/New-DFShim.ps1` | Create |
| `DotForge.psd1` | Modify — add `New-DFShim` to `FunctionsToExport` |
| `tests/New-DFShim.Tests.ps1` | Create |

---

## Signature

```powershell
New-DFShim
    [-Name] <string>       # shim filename (no extension); also used as tool DB key when -Target omitted
    [-Target <string>]     # explicit path to target .exe; bypasses DB lookup
    [-ShimsPath <string>]  # override shim directory for this call
    [-Force]               # overwrite existing shim without error
```

`[CmdletBinding(SupportsShouldProcess)]` — supports `-WhatIf` and `-Confirm`.

---

## Execution Flow

1. **Resolve shims directory** (first match wins):
   - `-ShimsPath` parameter
   - `$DFConfig['ShimsPath']` global config key
   - `$HOME\.local\bin` (XDG user-binary default)

2. **Create directory** via `New-DFDirectory $shimsDir` — idempotent, follows module convention.

3. **PATH check**: if `$shimsDir` is not present in `$Env:PATH`, emit:
   ```
   Write-Warning "DotForge: '$shimsDir' is not on PATH — shims won't be invocable until it is added"
   ```

4. **Resolve target executable** (one of):
   - `-Target` provided → `Test-Path $Target -PathType Leaf`; `Write-Error` if missing; use as-is
   - `-Target` omitted → load tool DB → find tool by `$Name` → get `executable` field → `Get-Command $executable` to resolve full path on PATH; `Write-Error` if tool unknown or not installed

5. **App directory**: `Split-Path -Parent $resolvedTarget`

6. **Shim existence check**: if `"$shimsDir\$Name.cmd"` already exists and `-Force` not set → `Write-Error` (non-terminating, skip this shim).

7. **Write shim** (guarded by `ShouldProcess`):

```batch
@echo off
setlocal
cd /d "<app-dir>"
"<target-exe>" %*
set "_exit=%ERRORLEVEL%"
endlocal
exit /b %_exit%
```

8. **Output**: `Write-Verbose "DotForge: shim created → $shimPath"`. Function returns no pipeline output (follows pattern of `New-DFDirectory`, `Add-DFToPath`).

---

## Generated .cmd Anatomy

```batch
@echo off
setlocal
cd /d "C:\tools\myapp"
"C:\tools\myapp\myapp.exe" %*
set "_exit=%ERRORLEVEL%"
endlocal
exit /b %_exit%
```

| Line | Purpose |
|------|---------|
| `@echo off` | Suppress command echo |
| `setlocal` | Isolate env changes from caller's shell |
| `cd /d "<app-dir>"` | Change drive AND directory to app's location |
| `"<target>" %*` | Run exe; `%*` forwards all arguments verbatim |
| `set "_exit=%ERRORLEVEL%"` | Capture exit code before `endlocal` clears env |
| `endlocal` | Restore caller's environment |
| `exit /b %_exit%` | Propagate captured exit code |

The `setlocal`/`endlocal` pattern correctly handles argument strings containing `!` (cmd delayed expansion) while preserving the target process exit code.

---

## $DFConfig Key

`$DFConfig['ShimsPath']` — optional string. Set in profile before `Import-Module DotForge`:

```powershell
$DFConfig = @{
    ShimsPath = 'C:\Users\me\.local\bin'   # defaults to $HOME\.local\bin if omitted
}
```

---

## DotForge.psd1

Add to `FunctionsToExport`:
```
'New-DFShim'
```

No new aliases.

---

## Tests (`tests/New-DFShim.Tests.ps1`)

| Test | Behavior verified |
|------|-------------------|
| Creates `.cmd` file in shims dir | File exists after call |
| `.cmd` contains correct target path | String match on content |
| `.cmd` contains correct working dir | `cd /d` line matches app dir |
| Shims dir from `$DFConfig['ShimsPath']` | File written to configured path |
| Falls back to `$HOME\.local\bin` | No `$DFConfig` key → default path used |
| Warns when shims dir not on `$PATH` | `Write-Warning` emitted |
| DB lookup resolves tool name to exe | Tool name → exe path via registry |
| `-Target` bypasses DB entirely | Explicit path used; no DB load |
| `-Force` overwrites existing shim | File overwritten without error |
| No `-Force` on existing → error | `Write-Error` emitted, file unchanged |
| Missing `-Target` + unknown tool → error | `Write-Error` emitted |
| `-WhatIf` produces no file | No `.cmd` written |

---

## Verification

```powershell
Import-Module ./DotForge.psd1 -Force

# By tool name (ripgrep must be installed)
New-DFShim -Name ripgrep -ShimsPath $TestDrive

# By explicit path
New-DFShim -Name myapp -Target 'C:\tools\myapp\myapp.exe' -ShimsPath $TestDrive

# Check generated content
Get-Content "$TestDrive\ripgrep.cmd"

# WhatIf — no file created
New-DFShim -Name ripgrep -ShimsPath $TestDrive -WhatIf

# Run tests
Invoke-Pester tests/New-DFShim.Tests.ps1 -Output Detailed
```
