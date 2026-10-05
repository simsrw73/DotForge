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
    <#
    .SYNOPSIS
        Returns $true when choco is on PATH; otherwise warns and returns $false.
    .DESCRIPTION
        Guard used by the choco pickers (cins, crm, cup). Defined by DotForge's
        choco companion.
    .EXAMPLE
        if (Assert-DFChoco) { choco list }

        Runs choco only when it is installed.
    .OUTPUTS
        System.Boolean.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    if (Get-Command choco -ErrorAction Ignore) { return $true }
    Write-Warning 'DotForge: choco is not installed. See https://chocolatey.org/install'
    return $false
}

# Run a choco command elevated via DotForge's sudo alias when present; otherwise run directly
# (choco will fail/prompt for elevation itself if the shell is not admin).
function global:Invoke-DFChocoElevated {
    <#
    .SYNOPSIS
        Runs choco with the given arguments, elevated through gsudo when available.
    .DESCRIPTION
        When DotForge's sudo alias points at gsudo, runs sudo choco <args>,
        which shows a UAC prompt; otherwise runs choco <args> directly, and
        choco fails without admin rights for commands that need them.
        Defined by DotForge's choco companion.
    .PARAMETER ChocoArgs
        Arguments passed to choco unchanged.
    .EXAMPLE
        Invoke-DFChocoElevated upgrade ripgrep -y

        Upgrades ripgrep from an unelevated shell.
    .OUTPUTS
        Whatever choco writes.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    param([Parameter(ValueFromRemainingArguments)][string[]]$ChocoArgs)
    if ((Get-Alias sudo -ErrorAction Ignore)?.Definition -eq 'gsudo') { sudo choco @ChocoArgs }
    else { choco @ChocoArgs }
}

function global:Select-ChocoPackage {
    <#
    .SYNOPSIS
        Searches the Chocolatey community feed, fuzzy-picks a package, and returns or runs its install command.
    .DESCRIPTION
        Runs choco search for -Query and lists the results in fzf with a
        choco info preview, shown after the cursor rests on an item for about
        a second.

        Keys:
          Enter   return the command 'choco install <id> -y' (nothing is
                  installed; run it in an elevated shell)
          Alt-R   close the picker and install the selection now
          Alt-I   install the highlighted package without closing the picker

        Bound to Ctrl+G, C when PSReadLine is loaded: type a search term, press
        the chord, pick a package, and the install command replaces the line.

        Defined by DotForge's choco companion; requires fzf (or $Env:Picker).
        Installing, uninstalling and upgrading need an elevated shell: they
        run through gsudo when DotForge's sudo alias points at it, which
        shows a UAC prompt; otherwise choco itself fails without admin rights.
    .PARAMETER Query
        Search terms passed to choco search. When omitted, you are prompted.
    .EXAMPLE
        cins ripgrep

        Pick ripgrep and press Enter to get: choco install ripgrep -y
    .OUTPUTS
        System.String (the install command) on Enter; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
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

    $sel = Invoke-DFPackageManagerPicker `
        -ListItems      { $items }.GetNewClosure() `
        -PreviewCommand 'choco info {2}' `
        -Header         'choco search  [Enter=command | Alt-R=install | Alt-I=install in place]' `
        -ExpectKey      'alt-r' `
        -Bind           "alt-i:execute($run install {2} -y)"

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
    <#
    .SYNOPSIS
        Fuzzy-picks an installed Chocolatey package and uninstalls it.
    .DESCRIPTION
        Lists installed packages (choco list) in fzf with a choco info preview.

        Keys:
          Enter   uninstall the selection
          Alt-X   uninstall the highlighted package without closing the picker
          Alt-C   return the command 'choco uninstall <id> -y' instead

        Defined by DotForge's choco companion; requires fzf (or $Env:Picker).
        Installing, uninstalling and upgrading need an elevated shell: they
        run through gsudo when DotForge's sudo alias points at it, which
        shows a UAC prompt; otherwise choco itself fails without admin rights.
    .EXAMPLE
        crm

        Pick an installed package and press Enter to uninstall it.
    .OUTPUTS
        System.String (the uninstall command) on Alt-C; otherwise none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
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

    $sel = Invoke-DFPackageManagerPicker `
        -ListItems      { $items }.GetNewClosure() `
        -PreviewCommand 'choco info {2}' `
        -Header         'choco uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]' `
        -ExpectKey      'alt-c' `
        -Bind           "alt-x:execute($run uninstall {2} -y)"

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
    <#
    .SYNOPSIS
        Fuzzy-picks outdated Chocolatey packages and upgrades them.
    .DESCRIPTION
        Lists packages with a newer version (choco outdated: installed ->
        available) in fzf with a choco info preview.

        Keys:
          Tab     mark a package (repeat for several)
          Enter   upgrade the marked packages, or the highlighted one
          Alt-A   run choco upgrade all -y

        Defined by DotForge's choco companion; requires fzf (or $Env:Picker).
        Installing, uninstalling and upgrading need an elevated shell: they
        run through gsudo when DotForge's sudo alias points at it, which
        shows a UAC prompt; otherwise choco itself fails without admin rights.
    .EXAMPLE
        cup

        Mark packages with Tab, then press Enter to upgrade them.
    .OUTPUTS
        None. choco writes its own progress.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
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

    $sel = Invoke-DFPackageManagerPicker `
        -ListItems      { $items }.GetNewClosure() `
        -PreviewCommand 'choco info {2}' `
        -Header         'choco upgrade  [Tab=mark | Enter=upgrade marked | Alt-A=upgrade all]' `
        -ExpectKey      'alt-a' `
        -Multi

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
