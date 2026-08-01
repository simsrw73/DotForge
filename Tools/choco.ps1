# Companion for choco — fuzzy pickers built on Invoke-DFPicker + fzf.
#   Select-ChocoPackage (cins)  search → install
#   Remove-ChocoPackage (crm)   installed → uninstall
#   Invoke-ChocoUpdate  (cup)   outdated → upgrade (multi-select)
#
# Dot-sourced by Register-DFTool when choco is registered. Every user-facing
# function/alias is declared `global:` so it survives Register-DFTool's scope.
#
# Chocolatey has no first-class object module, but its CLI has a machine-readable
# mode (`-r` / `--limit-output`) that emits pipe-delimited rows — so we split on
# '|' instead of scraping aligned columns. install/uninstall/upgrade need
# elevation; they run through the configured sudo alias when it is available
# (see Invoke-DFChocoElevated).
#
# Previews are prefixed with `ping -n 2 127.0.0.1 >nul &` — a ~1s cmd sleep that
# debounces the preview: fzf kills the running preview command when the cursor
# moves, so scrolling fast never spawns `choco info` for skipped items.

# Guard: choco must be on PATH.
function global:Assert-DFChoco {
    if (Get-Command choco -ErrorAction Ignore) { return $true }
    Write-Warning 'DotForge: choco is not installed. See https://chocolatey.org/install'
    return $false
}

# Run a choco command elevated via DotForge's sudo alias when present; otherwise run directly
# (choco will fail/prompt for elevation itself if the shell is not admin).
function global:Invoke-DFChocoElevated {
    param([Parameter(ValueFromRemainingArguments)][string[]]$ChocoArgs)
    if ((Get-Alias sudo -ErrorAction Ignore)?.Definition -eq 'gsudo') { sudo choco @ChocoArgs }
    else { choco @ChocoArgs }
}

function global:Select-ChocoPackage {
    [CmdletBinding()]
    param([string]$Query = '')

    if (-not (Assert-DFChoco)) { return }
    if (-not $Query) { $Query = Read-Host 'Search choco packages' }

    $items = @(
        choco search $Query -r 2>$null | Where-Object { $_ -match '\|' } | ForEach-Object {
            $parts = $_ -split '\|'
            ('{0,-38} {1}' -f $parts[0], $parts[1]) + "`t" + $parts[0]
        }
    )

    # sudo-aware command for the in-place execute() key (runs in a cmd subshell).
    $run = if ((Get-Alias sudo -ErrorAction Ignore)?.Definition -eq 'gsudo') { 'sudo choco' } else { 'choco' }

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       'ping -n 2 127.0.0.1 >nul & choco info {2}' `
        -PreviewWindow 'right:60%' `
        -Header        'choco search  [Enter=command | Alt-R=install | Alt-I=install in place]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-r' `
        -Bind          "alt-i:execute($run install {2} -y)"

    if (-not $sel) { return }
    $id = @($sel.Selected)[0]
    if (-not $id) { return }

    if ($sel.Key -eq 'alt-r') {
        Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
        Invoke-DFChocoElevated install $id -y
    }
    else {
        "choco install $id -y"
    }
}
Set-Alias -Name cins -Value Select-ChocoPackage -Scope Global -Force

function global:Remove-ChocoPackage {
    [CmdletBinding()]
    param()

    if (-not (Assert-DFChoco)) { return }

    $items = @(
        choco list -r 2>$null | Where-Object { $_ -match '\|' } | ForEach-Object {
            $parts = $_ -split '\|'
            ('{0,-38} {1}' -f $parts[0], $parts[1]) + "`t" + $parts[0]
        }
    )

    $run = if ((Get-Alias sudo -ErrorAction Ignore)?.Definition -eq 'gsudo') { 'sudo choco' } else { 'choco' }

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Preview       'ping -n 2 127.0.0.1 >nul & choco info {2}' `
        -PreviewWindow 'right:60%' `
        -Header        'choco uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-c' `
        -Bind          "alt-x:execute($run uninstall {2} -y)"

    if (-not $sel) { return }
    $id = @($sel.Selected)[0]
    if (-not $id) { return }

    if ($sel.Key -eq 'alt-c') {
        "choco uninstall $id -y"
    }
    else {
        Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
        Invoke-DFChocoElevated uninstall $id -y
    }
}
Set-Alias -Name crm -Value Remove-ChocoPackage -Scope Global -Force

function global:Invoke-ChocoUpdate {
    [CmdletBinding()]
    param()

    if (-not (Assert-DFChoco)) { return }

    # `choco outdated -r` → name|current|available|pinned
    $items = @(
        choco outdated -r 2>$null | Where-Object { $_ -match '\|' } | ForEach-Object {
            $parts = $_ -split '\|'
            ('{0,-34} {1} -> {2}' -f $parts[0], $parts[1], $parts[2]) + "`t" + $parts[0]
        }
    )

    $sel = Invoke-DFPicker `
        -List          { $items }.GetNewClosure() `
        -Delimiter     "`t" `
        -WithNth       '1' `
        -Multi `
        -Preview       'ping -n 2 127.0.0.1 >nul & choco info {2}' `
        -PreviewWindow 'right:60%' `
        -Header        'choco upgrade  [Tab=mark | Enter=upgrade marked | Alt-A=upgrade all]' `
        -Parse         { ($_ -split "`t")[1] } `
        -Expect        'alt-a'

    if (-not $sel) { return }

    if ($sel.Key -eq 'alt-a') {
        Write-Host '⚙  Upgrading all packages…' -ForegroundColor Green
        Invoke-DFChocoElevated upgrade all -y
        return
    }

    foreach ($id in $sel.Selected) {
        if ($id) {
            Write-Host "⚙  Upgrading $id…" -ForegroundColor Green
            Invoke-DFChocoElevated upgrade $id -y
        }
    }
}
Set-Alias -Name cup -Value Invoke-ChocoUpdate -Scope Global -Force

# ── PSReadLine binding: Ctrl+G, C ───────────────────────────────────────────
# Type a search term, press Ctrl+G then C: pick in fzf, and the install command
# lands on the command line (editable — press Enter to run). Uses the current
# line as the query. Guarded so it is a no-op when PSReadLine is unavailable.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g,c' `
        -Description 'DotForge: choco search → install command onto the line' `
        -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            $cmd = Select-ChocoPackage -Query $line
            if ($cmd -is [string] -and $cmd.Trim()) {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)
            }
        }
}
