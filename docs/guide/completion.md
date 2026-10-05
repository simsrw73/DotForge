# Completion

**Audience:** DotForge users who want Tab completion for external commands (git, docker, scoop, …).  
**Topic:** how DotForge combines PSReadLine, Carapace, PSFzf and inshellisense, and how to choose between them.  
**Goal:** Tab completes arguments for your CLI tools, in the style you prefer.

## Quick start

Install Carapace, then register your tools. Tab now completes arguments for hundreds of commands:

<!-- system -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Install-DFTool -Name carapace
Register-DFTool -All
```

Check it without pressing Tab, by asking PowerShell's completion engine directly:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
(TabExpansion2 -inputScript 'git checko' -cursorColumn 10).CompletionMatches.CompletionText
```

<!-- output: varies -->
```text
checkout
checkout-index
```

At the prompt, type `git checko` and press Tab.

## How the pieces fit

| Piece | Role | Comes from |
| --- | --- | --- |
| PSReadLine | the command-line editor; owns the Tab key | PowerShell |
| Carapace | completers: what the valid arguments are, for ~500 commands | `carapace` tool |
| PSFzf | a fuzzy picker over the completions when you press Tab | `PSFzf` module |
| inshellisense | IDE-style completion; a fallback source, or a full replacement | `inshellisense` tool (npm) |

DotForge registers each tool's completers as the tool is registered. Then, once all tools are registered, it decides what Tab does:

| What's registered | Tab does |
| --- | --- |
| PSFzf (with or without Carapace) | opens PSFzf's fuzzy picker over the completions |
| Carapace, no PSFzf | PSReadLine's `MenuComplete`: a menu you move through with Tab and the arrow keys |
| neither | PSReadLine's default for your edit mode |

When both PSFzf and Carapace are registered, DotForge adds `--ansi` to `FZF_DEFAULT_OPTS` so Carapace's colored items render in the picker instead of showing escape codes.

See which handler Tab has:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
Get-PSReadLineKeyHandler -Bound | Where-Object Key -EQ 'Tab' | Select-Object Key, Function
```

<!-- output: varies -->
```text
Key Function
--- --------
Tab CustomAction
```

`CustomAction` is PSFzf's picker; `MenuComplete` means Carapace without PSFzf.

## Use inshellisense

inshellisense has its own completion specs. DotForge can use it two ways, set with `CompletionMode`:

| `CompletionMode` | What happens |
| --- | --- |
| `Native` (default) | Carapace stays the completer. If the `is` command exists, DotForge adds `inshellisense` to `CARAPACE_BRIDGES`, so commands Carapace doesn't know fall back to inshellisense's specs. Bridges you set yourself are kept. |
| `Inshellisense` | DotForge starts inshellisense directly in each shell, after all tools are registered, and leaves Tab alone. If `is` isn't found, it warns and uses `Native`. |

To run inshellisense directly:

```powershell
$DFConfig = @{ CompletionMode = 'Inshellisense' }
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

inshellisense is a Node program, so it's usually installed with npm and only on `PATH` after fnm sets up Node. DotForge registers fnm before Carapace for that reason.

## Add a completer for a command Carapace doesn't know

Carapace has no completer for some tools. DotForge ships specs for `scoop` and `mdv` and copies them to `$XDG_CONFIG_HOME\carapace\specs\`, where Carapace loads them. To add your own, write a YAML spec there:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
$specs = Join-Path $Env:XDG_CONFIG_HOME 'carapace' 'specs'
New-DFDirectory $specs
@'
name: deploy
description: deploy the site
commands:
  - name: staging
    description: deploy to staging
  - name: production
    description: deploy to production
'@ | Set-Content (Join-Path $specs 'deploy.yaml')
Get-ChildItem $specs -Name
```

```text
...
deploy.yaml
```

DotForge's own `scoop.yaml` and `mdv.yaml` appear there too once Carapace has been registered.

1. Carapace registers a PowerShell completer for each command it knows when its init script runs. DotForge caches that script in `$XDG_CACHE_HOME\dotforge\carapace-init.txt` and only regenerates it when Carapace itself is upgraded.
2. So after adding a spec for a new command, delete the cached script and open a new shell:

   ```powershell
   Import-Module DotForge
   Initialize-DFEnvironment
   Remove-Item (Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'carapace-init.*') -ErrorAction Ignore
   ```

3. Run `carapace --help` for the spec format, or see the [carapace-spec documentation](https://carapace-sh.github.io/carapace-spec/).
4. Don't edit `scoop.yaml` or `mdv.yaml`: DotForge rewrites them whenever its bundled copy changes.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Tab stopped completing after you changed key bindings | `Set-PSReadLineOption -EditMode` after `Register-DFTool` resets Tab | Set `PSReadLineEditMode` in `$DFConfig` instead. |
| The fuzzy picker shows `[0m`-style codes | `FZF_DEFAULT_OPTS` was replaced after registration, dropping `--ansi` | Append to `FZF_DEFAULT_OPTS` instead of overwriting it. |
| `Inshellisense completion requested but its executable or starter was not found` | `CompletionMode = 'Inshellisense'` without `is` on `PATH` | Install inshellisense (`npm install -g @microsoft/inshellisense`) and make sure fnm is registered. |
| `CompletionMode '<x>' is invalid; using Native.` | a typo in `CompletionMode` | Use `Native` or `Inshellisense`. |
| A command you added a Carapace spec for doesn't complete | the cached Carapace init predates the spec | Delete `$XDG_CACHE_HOME\dotforge\carapace-init.*` and open a new shell. |

More on the [troubleshooting page](troubleshooting.md).
