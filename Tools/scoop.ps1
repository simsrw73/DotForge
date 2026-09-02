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
    $_scoopHook = & scoop-search --hook | Out-String
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
#   Previews run through scoop.preview.ps1 (a summary block above the full
#   `scoop info` output — see docs/external-dependencies.md), prefixed with
#   `Start-Sleep -Milliseconds 1000;` to debounce: fzf kills the running preview
#   command when the cursor moves, so scrolling fast never spawns the real
#   command for skipped items.

# Guard: the pickers need the Scoop module (Get-ScoopApp + *-ScoopApp actions).
function global:Assert-DFScoopModule {
    if (Get-Command Get-ScoopApp -ErrorAction Ignore) { return $true }
    Write-Warning "DotForge: the 'Scoop' module is required for the scoop pickers (sins/srm/sup). Install it with: Install-Module Scoop -Scope CurrentUser"
    return $false
}

function global:Select-ScoopPackage {
    [CmdletBinding()]
    param([string]$Query = '')

    if (-not (Assert-DFScoopModule)) { return }
    if (-not $Query) { $Query = Read-Host 'Search scoop apps' }

    # Prefer scoop-search (fast, matches binaries); fall back to the module.
    $items = @(
        if (Get-Command scoop-search -ErrorAction Ignore) {
            $bucket = ''
            & scoop-search $Query 2>$null | ForEach-Object {
                if ($_ -match "^'([^']+)' bucket:") { $bucket = $Matches[1]; return }
                if ($_ -match '^\s+(\S+)\s+\(([^)]+)\)') {
                    ('{0,-34} {1,-14} {2}' -f $Matches[1], $Matches[2], $bucket) + "`t" + $Matches[1]
                }
            }
        }
        else {
            Find-ScoopApp -Name "*$Query*" 2>$null | ForEach-Object {
                ('{0,-34} {1,-14} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
            }
        }
    )

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\scoop.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'scoop search  [Enter=command | Alt-R=install | Alt-I=install in place]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-r' `
        -Bind          'alt-i:execute(scoop install {2})'

    if (-not $sel) { return }
    $name = @($sel.Selected)[0]
    if (-not $name) { return }

    if ($sel.Key -eq 'alt-r') {
        Write-Host "⚙  Installing $name…" -ForegroundColor Cyan
        Install-ScoopApp -Name $name
    }
    else {
        "scoop install $name"
    }
}
Set-Alias -Name sins -Value Select-ScoopPackage -Scope Global -Force

function global:Remove-ScoopPackage {
    [CmdletBinding()]
    param()

    if (-not (Assert-DFScoopModule)) { return }

    $sel = Invoke-DFPicker `
        -List {
            Get-ScoopApp 2>$null | ForEach-Object {
                ('{0,-34} {1,-18} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
            }
        } `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\scoop.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'scoop uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-c' `
        -Bind          'alt-x:execute(scoop uninstall {2})'

    if (-not $sel) { return }
    $name = @($sel.Selected)[0]
    if (-not $name) { return }

    if ($sel.Key -eq 'alt-c') {
        "scoop uninstall $name"
    }
    else {
        Write-Host "⚙  Uninstalling $name…" -ForegroundColor DarkYellow
        Uninstall-ScoopApp -Name $name
    }
}
Set-Alias -Name srm -Value Remove-ScoopPackage -Scope Global -Force

function global:Invoke-ScoopUpdate {
    [CmdletBinding()]
    param()

    if (-not (Assert-DFScoopModule)) { return }

    # The Scoop module has no "outdated" query, so list all installed apps and
    # let the user mark which to update.
    $sel = Invoke-DFPicker `
        -List {
            Get-ScoopApp 2>$null | ForEach-Object {
                ('{0,-34} {1,-18} {2}' -f $_.Name, $_.Version, $_.Source) + "`t" + $_.Name
            }
        } `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Multi `
        -Preview       "Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\scoop.preview.ps1' {2}" `
        -PreviewWindow 'right:60%' `
        -Header        'scoop update  [Tab=mark | Enter=update marked | Alt-A=update all]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-a'

    if (-not $sel) { return }

    if ($sel.Key -eq 'alt-a') {
        Write-Host '⚙  Updating all apps…' -ForegroundColor Green
        scoop update '*'
        return
    }

    foreach ($name in $sel.Selected) {
        if ($name) {
            Write-Host "⚙  Updating $name…" -ForegroundColor Green
            Update-ScoopApp -Name $name
        }
    }
}
Set-Alias -Name sup -Value Invoke-ScoopUpdate -Scope Global -Force

# ── PSReadLine binding: Ctrl+G, S ───────────────────────────────────────────
# Type a search term, press Ctrl+G then S: pick in fzf, and the install command
# lands on the command line (editable — press Enter to run). Uses the current
# line as the query. Guarded so it is a no-op when PSReadLine is unavailable.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g,s' `
        -Description 'DotForge: scoop search → install command onto the line' `
        -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            $cmd = Select-ScoopPackage -Query $line
            if ($cmd -is [string] -and $cmd.Trim()) {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)
            }
        }
}
