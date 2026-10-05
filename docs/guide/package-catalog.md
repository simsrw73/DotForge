# Package catalog (trifle)

**Audience:** anyone choosing where to install a command-line tool from on Windows.  
**Topic:** `trifle` (`Find-DFPackage`), `ftrifle` (`Select-DFPackage`) and `tcats` (`Get-DFCategoryList`), which search every package catalog at once.  
**Goal:** find a tool, see which catalogs carry it and whether it's installed, and keep the caches warm.

## Quick start

Look a tool up in all seven catalogs at once:

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
trifle ripgrep
```

At a terminal, this prints an info card for ripgrep: its description, whether it's installed and through which catalog, which catalogs carry it and at what version, its homepage and license, and how old the cached data is.

The catalogs are scoop, winget, Chocolatey, npm, PyPI, crates.io and the PowerShell Gallery. Scoop and winget are read from files on your machine. The others are web APIs, cached so that repeat questions answer in about 200 ms.

## Search by name or keywords

Why: you know roughly what you want but not its exact name.

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
trifle static site generator
trifle bat -Source scoop, winget
trifle rg
```

1. Several words make a keyword search, and the result is a table of matches.
2. `-Source` limits the search to some catalogs.
3. winget's short names work too: `rg` finds ripgrep.

A query that matches exactly one package (by id, or by exact name) shows the detail card instead of the table. When other packages also matched, the card ends with a `+N more matches` line; add `-All` to see the table instead. The table's `Id` column holds values you can paste back as a qualified query.

## Go straight to one package

Why: skip ranking and get the full details for one package in one catalog.

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
trifle winget:Zed.Zed
trifle winget:Zed.Zed -GitInfo
trifle npm:left-pad -Readme
```

1. `<source>:<id>` always shows that package's detail card. An unknown prefix is treated as ordinary search text.
2. `-GitInfo` adds GitHub stars, the latest release and recent activity. It uses the `gh` CLI when it is installed and signed in, otherwise GitHub's anonymous API, which is rate limited.
3. `-Readme` pages the package's readme after the card.

`-GitInfo` and `-Readme` need a single package (a qualified id or an exact match). Otherwise trifle warns and shows the table.

## Use the results in a script

When trifle's output is piped, redirected or assigned with `-AsObject`, it returns objects instead of a printed card:

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
$hits = Find-DFPackage ripgrep -AsObject
$hits | Select-Object -First 1 Name, Installed, InstalledVia, DFTool
```

<!-- output: varies -->
```text
Name    Installed InstalledVia DFTool
----    --------- ------------ ------
ripgrep      True {scoop}      ripgrep
```

1. Use `-AsObject` when you assign the result: PowerShell can't tell an assignment from a terminal, so without it you capture the printed card.
2. Each object is a `DotForge.ToolInfo`. Its `Sources` property has one entry per catalog; the [reference](../reference.md#find-dfpackage) lists every field.
3. A package is merged into one row across catalogs only when DotForge knows they are the same tool (from its tool records or the shipped identity guide). Same-named packages in other catalogs stay separate rows, because a shared name alone often means a different tool.

## Browse by category

Why: find tools for a job without knowing any names.

A taxonomy of well-known tools ships with DotForge. List its terms (this works offline):

```powershell
Import-Module DotForge
tcats -Facet worksWith | Select-Object -First 4
```

```text
WorksWith
  archives (1)
  binaries (8)
  clipboard (1)
```

Then search a category; installed state and versions still come from the live catalogs:

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
trifle -Category search
trifle -Category search -WorksWith filesystem
```

1. `-Category` matches what a tool does (`search`, `file-viewing`, …); `-WorksWith` matches what it works on (`filesystem`, `git`, …).
2. Several values for one option match any of them; `-Category` together with `-WorksWith` must match both.
3. A category search always shows the table.

For bare terms in a script, keep the indented lines and trim them:

```powershell
Import-Module DotForge
tcats -Facet function -Counts:$false | Where-Object { $_ -like '  *' } | ForEach-Object Trim | Select-Object -First 3
```

```text
archive
benchmarking
clipboard
```

## Browse interactively

`ftrifle` (`Select-DFPackage`) puts results in fzf with a preview card for each, so scrolling is instant:

<!-- interactive -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
ftrifle zed
```

| Command | What it lists |
| --- | --- |
| `ftrifle <query>` | live search results across every catalog |
| `ftrifle` | every package already in your local caches; opens instantly |
| `ftrifle -Categories` | the category terms; Enter searches the one you pick |
| `ftrifle -Category <c>`, `ftrifle -WorksWith <w>` | one category directly |

Enter shows the full detail card for the selection. `-Readme` and `-GitInfo` pass through.

## Keep the caches warm

trifle answers from its caches and refreshes stale entries in the background, so the next query is current. `-Fresh` waits for live data instead. To keep everything warm, refresh nightly with a scheduled task. Run this once; it creates a per-user task and needs no elevation:

<!-- system -->

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh' -Argument (
    '-NoProfile -Command "winget source update; Import-Module DotForge; Update-DFPackageCache -Quiet"'
)
$trigger  = New-ScheduledTaskTrigger -Daily -At 6am
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
Register-ScheduledTask -TaskName 'DotForge catalog refresh' -Action $action -Trigger $trigger -Settings $settings
```

To check on it, or remove it:

<!-- system -->

```powershell
Get-ScheduledTask -TaskName 'DotForge catalog refresh' | Get-ScheduledTaskInfo
Unregister-ScheduledTask -TaskName 'DotForge catalog refresh' -Confirm:$false
```

`winget source update` runs first because winget's catalog is a file winget downloads only when winget itself runs. `Update-DFPackageCache` re-reads whatever file is there, so on a machine where you rarely use winget, its data would otherwise grow old (the card's `Cache` line shows it, for example `winget 61d`).

## Update the category and identity data

The category database and the identity guide ship with the module. Newer copies are published with each DotForge release; download them without upgrading the module:

<!-- network -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Update-DFCategoryDb
Update-DFToolIdentityGuide
```

Both validate the download before writing it to `$XDG_DATA_HOME\dotforge\`, and keep your current copy if anything fails. Nothing ever runs these for you. Delete the downloaded files to go back to the shipped copies.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The card's `Cache` line shows winget data days old | winget hasn't refreshed its catalog file | Run `winget source update`, or add it to the scheduled task as above. |
| `-GitInfo` adds nothing to the card | no GitHub repository found for the package, or GitHub's anonymous API limit (60 requests an hour) was reached | Install the `gh` CLI and run `gh auth login`. |
| `$x = trifle rg` gives text, not objects | an assignment looks like a terminal | Add `-AsObject`. |
| `ftrifle` with no query lists nothing | nothing is cached yet | Run a `trifle` query or `Update-DFPackageCache` first. |
| `ftrifle -Category <x>` warns `no matches for category '<x>'` | the term isn't in the taxonomy | Check spelling with `tcats`. |

More on the [troubleshooting page](troubleshooting.md).
