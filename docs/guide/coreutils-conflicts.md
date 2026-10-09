# Coreutils conflicts

**Audience:** DotForge users who also have [Coreutils for Windows](https://github.com/uutils/coreutils) installed.  
**Topic:** why some DotForge commands (`cat`, `touch`, `env`, `paste`, `ls`) silently don't run, and how to choose which version wins.  
**Goal:** every command name runs the version you expect.

## The problem

Coreutils for Windows adds a hook to your PowerShell profile that rewrites some command names to `<name>.cmd` *before PowerShell looks them up*. No alias or function can win against that, because the name is changed before resolution starts. The confusing part: `Get-Command cat` still reports DotForge's version, so everything looks right while typing `cat` actually runs coreutils.

The commands that usually collide are `cat` (bat), `ls`/`la` (eza or lsd), `touch`, `env` and `paste` (DotForge helpers).

`Register-DFTool` detects this and warns once per session, listing the affected commands and the fix.

## See the conflicts

```powershell
Import-Module DotForge
Get-DFCommandConflict | Format-Table Command, ShadowedBy, WouldResolveTo, Ignored, DisableWith
```

In a shell where the coreutils hook is active, the output looks like this. With no conflicts, it prints nothing.

<!-- output: varies -->
```text
Command ShadowedBy WouldResolveTo Ignored DisableWith
------- ---------- -------------- ------- -----------
cat     coreutils  bat            False   cat
la      coreutils  eza            False   ls
touch   coreutils  New-DFFile     False   touch
```

`DisableWith` is the name to give `coreutils-manager`. It differs from `Command` for `la`: there is no separate `la` utility, and coreutils adds `la` only while `ls` is enabled, so disabling `ls` removes both.

The hook is loaded only by the console host's profile, so in hosts that don't load it (the VS Code terminal, for example) there is genuinely no conflict, and none is reported.

## Pick a side

Resolving a conflict needs administrator rights and is your choice to make, so DotForge only prints the command; it never elevates or changes coreutils itself.

### Keep DotForge's versions

Run this once in an elevated shell. It persists across coreutils upgrades, because the installer regenerates its profile block from this list:

<!-- system -->

```powershell
coreutils-manager disable cat touch env paste
```

Check the result with `coreutils-manager status` (no elevation needed). Undo it with `coreutils-manager enable cat touch env paste`.

### Keep coreutils' versions

List the commands in `IgnoreConflicts` to accept coreutils' version and silence the warning for them:

```powershell
$DFConfig = @{ IgnoreConflicts = @('cat', 'touch', 'env', 'paste') }
Import-Module DotForge
Start-DFSession -Config (@{ Tools = @('+core'); IgnoreConflicts = @('cat', 'touch', 'env', 'paste') })
Get-DFCommandConflict -IncludeIgnored | Format-Table Command, Ignored
```

`-IncludeIgnored` shows ignored conflicts too, marked `Ignored = True`; without it they're left out.

### Turn the check off

```powershell
$DFConfig = @{ SkipConflictCheck = $true }
Import-Module DotForge
Start-DFSession -Config (@{ Tools = @('+core'); SkipConflictCheck = $true })
```

The check is cheap: it reads the same list the coreutils hook uses, and costs nothing when coreutils isn't installed.

## Things to avoid

- Don't hand-edit the `DO NOT MODIFY -- coreutils` block in your profile. The coreutils installer regenerates it on every upgrade.
- Don't rely on `Get-Command` to check which version runs; it can't see the rewrite.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `cat` prints plain text, without bat's colors | coreutils' `cat` wins | `coreutils-manager disable cat` (elevated), or accept it with `IgnoreConflicts`. |
| `coreutils-manager disable la` fails | there is no `la` utility | Disable `ls`; that removes `la` too. |
| The warning appears again after a coreutils upgrade | a new utility now collides | Run `Get-DFCommandConflict` and handle the new name. |
| The check stopped reporting anything after a coreutils upgrade | coreutils changed the internals DotForge reads | Nothing else breaks; see [external dependencies](../external-dependencies.md). |

More on the [troubleshooting page](troubleshooting.md).
