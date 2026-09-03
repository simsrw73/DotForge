# Companion for winget — fuzzy pickers built on Invoke-DFPicker + fzf.
#   Select-WingetPackage (wins)  search → install
#   Remove-WingetPackage (wrm)   installed → uninstall
#   Invoke-WingetUpdate  (wup)   upgradable → update (multi-select)
#
# Dot-sourced by Register-DFTool when winget is registered. Every user-facing
# function/alias is declared `global:` so it survives Register-DFTool's scope.
#
# Data comes from the Microsoft.WinGet.Client module (objects, no table
# scraping). fzf's --preview and --bind execute() commands run in a fresh
# `pwsh -NoProfile` process (Tools/fzf.json's --with-shell) with no DotForge
# module loaded and Microsoft.WinGet.Client not imported, so those steps use
# the `winget` CLI directly for display and in-place actions rather than
# paying to import the module in a throwaway process per keystroke.
#
# Previews run through winget.preview.ps1 (a summary block above the full
# `winget show` output — see docs/external-dependencies.md), prefixed with
# `Start-Sleep -Milliseconds 1000;` to debounce: fzf kills the running preview
# command when the cursor moves, so scrolling fast never spawns the real
# command for skipped items; it only runs once the cursor rests on one for ~1s.

# Guard: the pickers need the Microsoft.WinGet.Client module. Documented
# dependency, so warn clearly (not silently) when it is missing.
function global:Assert-DFWingetModule {
    if (Get-Command Find-WinGetPackage -ErrorAction Ignore) { return $true }
    Write-Warning "DotForge: the 'Microsoft.WinGet.Client' module is required for the winget pickers (wins/wrm/wup). Install it with: Install-Module Microsoft.WinGet.Client -Scope CurrentUser"
    return $false
}

function global:Select-WingetPackage {
    [CmdletBinding()]
    param([string]$Query = '')

    if (-not (Assert-DFWingetModule)) { return }
    if (-not $Query) { $Query = Read-Host 'Search winget packages' }

    # Build the display lines up front so $Query is resolved here (not in the
    # picker's scope) and close over the resulting plain array.
    $items = @(
        Find-WinGetPackage $Query 2>$null | ForEach-Object {
            ('{0,-40} {1,-34} {2}' -f $_.Name, $_.Id, $_.Version) + "`t" + $_.Id
        }
    )

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\winget.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'winget search  [Enter=command | Alt-R=install | Alt-I=install in place]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-r' `
        -Bind          'alt-i:execute(winget install --id {2} --exact)'

    if (-not $sel) { return }
    $id = @($sel.Selected)[0]
    if (-not $id) { return }   # only the in-place Alt-I bind ran; nothing chosen on exit

    if ($sel.Key -eq 'alt-r') {
        Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
        Install-WinGetPackage -Id $id -MatchOption Equals
    }
    else {
        # Enter → return the install command for review / piping / running.
        "winget install --id $id --exact"
    }
}
Set-Alias -Name wins -Value Select-WingetPackage -Scope Global -Force

function global:Remove-WingetPackage {
    [CmdletBinding()]
    param(
        # Optionally restrict the list to one installed-package source
        # (e.g. -Source winget) to hide ARP/registry-only entries.
        [string]$Source = ''
    )

    if (-not (Assert-DFWingetModule)) { return }

    # Get-WinGetPackage -Source does not actually filter the returned set, so
    # filter on the Source property here (blank = ARP/registry-only entries).
    $items = @(
        Get-WinGetPackage 2>$null |
            Where-Object { -not $Source -or $_.Source -eq $Source } |
            ForEach-Object {
                ('{0,-40} {1,-34} {2}' -f $_.Name, $_.Id, $_.InstalledVersion) + "`t" + $_.Id
            }
    )

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\winget.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'winget uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-c' `
        -Bind          'alt-x:execute(winget uninstall --id {2})'

    if (-not $sel) { return }
    $id = @($sel.Selected)[0]
    if (-not $id) { return }

    if ($sel.Key -eq 'alt-c') {
        "winget uninstall --id $id"
    }
    else {
        Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
        Uninstall-WinGetPackage -Id $id -MatchOption Equals
    }
}
Set-Alias -Name wrm -Value Remove-WingetPackage -Scope Global -Force

function global:Invoke-WingetUpdate {
    [CmdletBinding()]
    param()

    if (-not (Assert-DFWingetModule)) { return }

    $sel = Invoke-DFPicker `
        -List {
            Get-WinGetPackage 2>$null | Where-Object IsUpdateAvailable | ForEach-Object {
                $latest = @($_.AvailableVersions)[0]
                ('{0,-36} {1,-30} {2} -> {3}' -f $_.Name, $_.Id, $_.InstalledVersion, $latest) + "`t" + $_.Id
            }
        } `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Multi `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\winget.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'winget upgrade  [Tab=mark | Enter=upgrade marked | Alt-A=upgrade all]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-a'

    if (-not $sel) { return }

    if ($sel.Key -eq 'alt-a') {
        Write-Host '⚙  Upgrading all packages…' -ForegroundColor Green
        winget upgrade --all
        return
    }

    foreach ($id in $sel.Selected) {
        if ($id) {
            Write-Host "⚙  Upgrading $id…" -ForegroundColor Green
            Update-WinGetPackage -Id $id -MatchOption Equals
        }
    }
}
Set-Alias -Name wup -Value Invoke-WingetUpdate -Scope Global -Force

# ── PSReadLine binding: Ctrl+G, W ───────────────────────────────────────────
# Type a search term, press Ctrl+G then W: pick in fzf, and the install command
# lands on the command line (editable — press Enter to run). Uses the current
# line as the query. Guarded so it is a no-op when PSReadLine is unavailable.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g,w' `
        -Description 'DotForge: winget search → install command onto the line' `
        -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            $cmd = Select-WingetPackage -Query $line
            if ($cmd -is [string] -and $cmd.Trim()) {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)
            }
        }
}
