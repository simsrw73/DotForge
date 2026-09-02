# 07 — scoop & choco fuzzy pickers
#
# The same picker workflow as the winget set (see 06-winget-pickers.ps1),
# applied to scoop and Chocolatey. Each has a live preview pane (a summary
# block above the full `<pm> info` output) and
# the same keys: Enter (command / act), Alt-R install, Alt-I/Alt-X in place,
# Alt-C command, Tab + Alt-A for bulk update.
#
# Requires fzf on PATH (or $Env:Picker = 'skim').

Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -Name scoop, choco    # or -All

# ── scoop (sins / srm / sup) ────────────────────────────────────────────────
# Search prefers scoop-search (fast; matches names AND binaries). Requires the
# Scoop module for the installed list + typed actions:
#   Install-Module Scoop -Scope CurrentUser
#   scoop install scoop-search        # optional but recommended for fast search
sins ripgrep       # search → Enter prints `scoop install ripgrep`; Alt-R installs
srm                # installed apps → uninstall
sup                # installed apps → Tab-mark several → Enter updates them
#                  #   Alt-A runs `scoop update *`

# ── choco (cins / crm / cup) ────────────────────────────────────────────────
# No object module exists, so these use choco's machine-readable `-r` output.
# install/uninstall/upgrade need elevation: they run via gsudo when it is on
# PATH, otherwise Enter on the search picker returns the command to run elevated.
cins ripgrep       # search → Enter prints `choco install ripgrep -y`; Alt-R installs (gsudo)
crm                # installed packages → uninstall
cup                # outdated packages → Tab-mark → Enter upgrades; Alt-A upgrades all

# Enter on the search pickers returns a string, so you can capture / run later:
$cmd = cins ripgrep
# Invoke-Expression $cmd

# ── Command-line prefill (PSReadLine chords) ────────────────────────────────
# For an editable command on your prompt: type a search term, then press the
# chord — Ctrl+G S (scoop) or Ctrl+G C (choco) — pick in fzf, and the install
# command lands on the line, ready to edit / run. (winget is Ctrl+G W.)
#
#   ripgrep<Ctrl+G><S>   ->   scoop install ripgrep
#   ripgrep<Ctrl+G><C>   ->   choco install ripgrep -y
