# Companion for scoop — dot-sourced by Register-DFTool when scoop is registered.
# Invoke-Expression is required by scoop-search's hook registration pattern.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# Scoop requires git for bucket operations (scoop bucket add, scoop update, etc.)
if (-not (Get-Command git -ErrorAction Ignore)) {
    Write-Warning 'DotForge: git is not installed — scoop bucket operations will fail. Fix: scoop install git'
}

# If scoop-search is installed, hook it as the default search provider.
# It is dramatically faster than built-in scoop search.
# To install: scoop install scoop-search
if (Get-Command scoop-search -ErrorAction Ignore) {
    # scoop-search --hook emits `function scoop { ... }` with no scope modifier.
    # This companion is dot-sourced from inside Register-DFTool, so an unqualified
    # function definition lands in that function's scope and is discarded when it
    # returns — the hook never reaches the prompt. (zoxide avoids this because its
    # init emits global:-scoped functions.) Promote the hook's scoop function to
    # global scope so it survives.
    #
    # The hook script is a pure function of scoop-search's own build (verified
    # byte-identical across runs) -- cached keyed to the binary's own file
    # identity so a scoop-search upgrade regenerates it. See
    # docs/superpowers/specs/2026-09-05-startup-perf-audit.md.
    $_scoopHook = Get-DFCachedCommandOutput -Name 'scoop-search-hook' -Executable 'scoop-search' -Generate {
        & scoop-search --hook | Out-String
    }
    # If scoop-search ever emits a global-scoped function itself (proposed
    # upstream), leave it untouched. Otherwise the Replace forces global scope;
    # it no-ops (leaving the function local, i.e. the pre-fix behavior) if the
    # codegen changes in some other way.
    if ($_scoopHook -notmatch 'function\s+global:scoop\b') {
        $_scoopHook = $_scoopHook.Replace('function scoop {', 'function global:scoop {')
    }
    Invoke-Expression $_scoopHook
} else {
    Write-Verbose 'DotForge: scoop-search not found — install for faster search: scoop install scoop-search'
}

# ── Fuzzy pickers (sins / srm / sup) ─────────────────────────────────────────
# Built on Invoke-DFPicker + fzf, with a live `scoop info` preview pane.
#   Search uses scoop-search (fast; matches names AND binaries) when present,
#   else the Scoop module's Find-ScoopApp wildcard. Installed list + typed
#   install/uninstall/update actions come from the Scoop module (object output,
#   no `scoop list` table scraping). fzf --bind execute() runs in a cmd subshell
#   that cannot call cmdlets, so the in-place keys use the `scoop` CLI.
#   Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep
#   that debounces the preview: fzf kills the running preview command when the
#   cursor moves, so scrolling fast never spawns `scoop info` for skipped items.

# Guard: the pickers need the Scoop module (Get-ScoopApp + *-ScoopApp actions).
function global:Assert-DFScoopModule {
    <#
    .SYNOPSIS
        Returns $true when the Scoop PowerShell module is available; otherwise warns and returns $false.
    .DESCRIPTION
        Guard used by the scoop pickers (sins, srm, sup). The warning includes
        the command that installs the module. Defined by DotForge's scoop
        companion.
    .EXAMPLE
        if (Assert-DFScoopModule) { Get-ScoopApp }

        Runs a Scoop module cmdlet only when the module is present.
    .OUTPUTS
        System.Boolean.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    if (Get-Command Get-ScoopApp -ErrorAction Ignore) { return $true }
    Write-Warning "DotForge: the 'Scoop' module is required for the scoop pickers (sins/srm/sup). Install it with: Install-Module Scoop -Scope CurrentUser"
    return $false
}

# What differs about scoop; the shared flow is Invoke-DFPackageManagerAction.
$script:DFPackageManagerSpecs['scoop'] = @{
    Name             = 'scoop'
    Require          = { Assert-DFScoopModule }
    SearchPrompt     = 'Search scoop apps'
    Preview          = 'scoop info {2}'
    # Prefer scoop-search (fast, matches binaries); fall back to the module.
    Search           = { param($Query)
        if (Get-Command scoop-search -ErrorAction Ignore) {
            $bucket = ''
            & scoop-search $Query 2>$null | ForEach-Object {
                if ($_ -match "^'([^']+)' bucket:") { $bucket = $Matches[1]; return }
                if ($_ -match '^\s+(\S+)\s+\(([^)]+)\)') {
                    ('{0,-34} {1,-14} {2}' -f $Matches[1], $Matches[2], $bucket) + "`t" + $Matches[1]
                }
            }
        } else {
            Find-ScoopApp -Name "*$Query*" 2>$null | ForEach-Object {
                ('{0,-34} {1,-14} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
            }
        } }
    Installed        = { param($Source)
        Get-ScoopApp 2>$null | ForEach-Object {
            ('{0,-34} {1,-18} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
        } }
    # The Scoop module has no "outdated" query, so offer every installed app.
    Outdated         = {
        Get-ScoopApp 2>$null | ForEach-Object {
            ('{0,-34} {1,-18} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
        } }
    InstallCommand   = Format-DFInstallCommand -Manager $DFCurrentTool   # from this record's installs block
    UninstallCommand = 'scoop uninstall {0}'
    InPlace          = { param($command) $command }
    Install          = { param($Id) Install-ScoopApp -Name $Id }
    Uninstall        = { param($Id) Uninstall-ScoopApp -Name $Id }
    Update           = { param($Id) Update-ScoopApp -Name $Id }
    UpdateAll        = { scoop update '*' }
    UpdateWord       = 'update'
    UpdatingWord     = 'Updating'
    AllMessage       = 'Updating all apps…'
}

function global:Select-ScoopPackage {
    <#
    .SYNOPSIS
        Searches scoop buckets, fuzzy-picks an app, and returns or runs its install command.
    .DESCRIPTION
        Searches with scoop-search when it is installed (fast, and matches
        binary names as well as app names), otherwise with the Scoop module's
        Find-ScoopApp, and lists the results in fzf with a scoop info preview.
        Only buckets you have added are searched.

        Keys:
          Enter   return the command 'scoop install <name>' (nothing is installed)
          Alt-R   close the picker and install the selection now
          Alt-I   install the highlighted app without closing the picker

        Bound to Ctrl+G, S when PSReadLine is loaded: type a search term, press
        the chord, pick an app, and the install command replaces the line.

        Defined by DotForge's scoop companion. Requires the Scoop PowerShell
        module (Install-Module Scoop -Scope CurrentUser; warns and does
        nothing without it) and fzf (or $Env:Picker).
    .PARAMETER Query
        Search terms. When omitted, you are prompted.
    .EXAMPLE
        sins ripgrep

        Pick ripgrep and press Enter to get: scoop install ripgrep
    .OUTPUTS
        System.String (the install command) on Enter; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([string]$Query = '')
    Invoke-DFPackageManagerAction -Manager scoop -Action Install -Query $Query
}
Set-Alias -Name sins -Value Select-ScoopPackage -Scope Global -Force

function global:Remove-ScoopPackage {
    <#
    .SYNOPSIS
        Fuzzy-picks an installed scoop app and uninstalls it.
    .DESCRIPTION
        Lists installed apps (Get-ScoopApp) in fzf with a scoop info preview.

        Keys:
          Enter   uninstall the selection (Uninstall-ScoopApp)
          Alt-X   uninstall the highlighted app without closing the picker
          Alt-C   return the command 'scoop uninstall <name>' instead

        Defined by DotForge's scoop companion. Requires the Scoop PowerShell
        module (Install-Module Scoop -Scope CurrentUser; warns and does
        nothing without it) and fzf (or $Env:Picker).
    .EXAMPLE
        srm

        Pick an installed app and press Enter to uninstall it.
    .OUTPUTS
        System.String (the uninstall command) on Alt-C; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPackageManagerAction -Manager scoop -Action Uninstall
}
Set-Alias -Name srm -Value Remove-ScoopPackage -Scope Global -Force

function global:Invoke-ScoopUpdate {
    <#
    .SYNOPSIS
        Fuzzy-picks installed scoop apps and updates them.
    .DESCRIPTION
        Lists every installed app (the Scoop module cannot list only outdated
        ones) in fzf with a scoop info preview. Updating an app that is
        already current does nothing.

        Keys:
          Tab     mark an app (repeat for several)
          Enter   update the marked apps, or the highlighted one
          Alt-A   run scoop update '*' (every app)

        Defined by DotForge's scoop companion. Requires the Scoop PowerShell
        module (Install-Module Scoop -Scope CurrentUser; warns and does
        nothing without it) and fzf (or $Env:Picker).
    .EXAMPLE
        sup

        Mark apps with Tab, then press Enter to update them.
    .OUTPUTS
        None. scoop writes its own progress.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPackageManagerAction -Manager scoop -Action Update
}
Set-Alias -Name sup -Value Invoke-ScoopUpdate -Scope Global -Force

# ── PSReadLine binding: Ctrl+G, S ───────────────────────────────────────────
# Type a search term, press Ctrl+G then S: pick in fzf, and the install command
# lands on the command line (editable — press Enter to run). Uses the current
# line as the query. Guarded so it is a no-op when PSReadLine is unavailable.
Register-DFPrefillChord -Chord 'Ctrl+g,s' -Picker 'Select-ScoopPackage' `
    -Description 'DotForge: scoop search → install command onto the line'
