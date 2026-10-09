# Companion for winget — fuzzy pickers built on Invoke-DFPicker + fzf.
#   Select-WingetPackage (wins)  search → install
#   Remove-WingetPackage (wrm)   installed → uninstall
#   Invoke-WingetUpdate  (wup)   upgradable → update (multi-select)
#
# Dot-sourced by Register-DFTool when winget is registered. Every user-facing
# function/alias is declared `global:` so it survives Register-DFTool's scope.
#
# Data comes from the Microsoft.WinGet.Client module (objects, no table
# scraping). fzf's --preview and --bind execute() run in a cmd subshell that
# cannot call cmdlets, so those steps use the `winget` CLI for display only.
#
# Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep that
# debounces the preview: fzf kills the running preview command when the cursor
# moves, so scrolling fast never spawns `winget show` for skipped items; it only
# runs once the cursor rests on one for ~1s.

# Guard: the pickers need the Microsoft.WinGet.Client module. Documented
# dependency, so warn clearly (not silently) when it is missing.
function global:Assert-DFWingetModule {
    <#
    .SYNOPSIS
        Returns $true when the Microsoft.WinGet.Client module is available; otherwise warns and returns $false.
    .DESCRIPTION
        Guard used by the winget pickers (wins, wrm, wup). The warning includes
        the command that installs the module. Defined by DotForge's winget
        companion.
    .EXAMPLE
        if (Assert-DFWingetModule) { Get-WinGetPackage }

        Runs a WinGet.Client cmdlet only when the module is present.
    .OUTPUTS
        System.Boolean.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    if (Get-Command Find-WinGetPackage -ErrorAction Ignore) { return $true }
    Write-Warning "DotForge: the 'Microsoft.WinGet.Client' module is required for the winget pickers (wins/wrm/wup). Install it with: Install-Module Microsoft.WinGet.Client -Scope CurrentUser"
    return $false
}

# What differs about winget; the shared flow is Invoke-DFPackageManagerAction.
$script:DFPackageManagerSpecs['winget'] = @{
    Name             = 'winget'
    Require          = { Assert-DFWingetModule }
    SearchPrompt     = 'Search winget packages'
    Preview          = 'winget show --id {2}'
    Search           = { param($Query)
        Find-WinGetPackage $Query 2>$null | ForEach-Object {
            ('{0,-40} {1,-34} {2}' -f $_.Name, $_.Id, $_.Version) + "`t" + $_.Id
        } }
    # Get-WinGetPackage -Source does not actually filter the returned set, so
    # filter on the Source property here (blank = ARP/registry-only entries).
    Installed        = { param($Source)
        Get-WinGetPackage 2>$null | Where-Object { -not $Source -or $_.Source -eq $Source } | ForEach-Object {
            ('{0,-40} {1,-34} {2}' -f $_.Name, $_.Id, $_.InstalledVersion) + "`t" + $_.Id
        } }
    Outdated         = {
        Get-WinGetPackage 2>$null | Where-Object IsUpdateAvailable | ForEach-Object {
            $latest = @($_.AvailableVersions)[0]
            ('{0,-36} {1,-30} {2} -> {3}' -f $_.Name, $_.Id, $_.InstalledVersion, $latest) + "`t" + $_.Id
        } }
    InstallCommand   = Format-DFInstallCommand -Manager $DFCurrentTool   # from this record's installs block
    UninstallCommand = 'winget uninstall --id {0}'
    InPlace          = { param($command) $command }
    Install          = { param($Id) Install-WinGetPackage -Id $Id -MatchOption Equals }
    Uninstall        = { param($Id) Uninstall-WinGetPackage -Id $Id -MatchOption Equals }
    Update           = { param($Id) Update-WinGetPackage -Id $Id -MatchOption Equals }
    UpdateAll        = { winget upgrade --all }
    UpdateWord       = 'upgrade'
    UpdatingWord     = 'Upgrading'
    AllMessage       = 'Upgrading all packages…'
}

function global:Select-WingetPackage {
    <#
    .SYNOPSIS
        Searches winget, fuzzy-picks a package, and returns or runs its install command.
    .DESCRIPTION
        Runs Find-WinGetPackage for -Query and lists the results (name, id,
        version) in fzf. The preview pane shows winget show for the
        highlighted package after the cursor rests on it for about a second.

        Keys:
          Enter   return the command 'winget install --id <id> --exact' (nothing
                  is installed; review it, pipe it, or run it)
          Alt-R   close the picker and install the selection now
          Alt-I   install the highlighted package without closing the picker

        Bound to Ctrl+G, W when PSReadLine is loaded: type a search term, press
        the chord, pick a package, and the install command replaces the line.

        Defined by DotForge's winget companion. Requires the
        Microsoft.WinGet.Client module (warns and does nothing without it) and
        fzf (or $Env:Picker).
    .PARAMETER Query
        Search terms passed to Find-WinGetPackage. When omitted, you are prompted.
    .EXAMPLE
        wins ripgrep

        Pick ripgrep and press Enter to get:
        winget install --id BurntSushi.ripgrep.MSVC --exact
    .OUTPUTS
        System.String (the install command) on Enter; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([string]$Query = '')
    Invoke-DFPackageManagerAction -Manager winget -Action Install -Query $Query
}
Set-Alias -Name wins -Value Select-WingetPackage -Scope Global -Force

function global:Remove-WingetPackage {
    <#
    .SYNOPSIS
        Fuzzy-picks an installed package and uninstalls it with winget.
    .DESCRIPTION
        Lists installed packages (Get-WinGetPackage) in fzf with a winget show
        preview.

        Keys:
          Enter   uninstall the selection (Uninstall-WinGetPackage)
          Alt-X   uninstall the highlighted package without closing the picker
          Alt-C   return the command 'winget uninstall --id <id>' instead

        Defined by DotForge's winget companion. Requires the
        Microsoft.WinGet.Client module and fzf (or $Env:Picker).
    .PARAMETER Source
        Show only packages from this installed-package source (e.g. winget),
        hiding apps winget only knows from the Windows Apps & Features list.
        Default: all.
    .EXAMPLE
        wrm -Source winget

        Lists only winget-installed packages; Enter uninstalls the selection.
    .OUTPUTS
        System.String (the uninstall command) on Alt-C; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([string]$Source = '')
    Invoke-DFPackageManagerAction -Manager winget -Action Uninstall -Source $Source
}
Set-Alias -Name wrm -Value Remove-WingetPackage -Scope Global -Force

function global:Invoke-WingetUpdate {
    <#
    .SYNOPSIS
        Fuzzy-picks packages with available upgrades and updates them with winget.
    .DESCRIPTION
        Lists installed packages that have an update (installed -> latest
        version) in fzf with a winget show preview.

        Keys:
          Tab     mark a package (repeat for several)
          Enter   update the marked packages, or the highlighted one
          Alt-A   run winget upgrade --all

        Defined by DotForge's winget companion. Requires the
        Microsoft.WinGet.Client module and fzf (or $Env:Picker).
    .EXAMPLE
        wup

        Mark packages with Tab, then press Enter to update them.
    .OUTPUTS
        None. winget writes its own progress.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPackageManagerAction -Manager winget -Action Update
}
Set-Alias -Name wup -Value Invoke-WingetUpdate -Scope Global -Force

# ── PSReadLine binding: Ctrl+G, W ───────────────────────────────────────────
# Type a search term, press Ctrl+G then W: pick in fzf, and the install command
# lands on the command line (editable — press Enter to run). Uses the current
# line as the query. Guarded so it is a no-op when PSReadLine is unavailable.
Register-DFPrefillChord -Chord 'Ctrl+g,w' -Picker 'Select-WingetPackage' `
    -Description 'DotForge: winget search → install command onto the line'
