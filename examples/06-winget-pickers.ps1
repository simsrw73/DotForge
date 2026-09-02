# 06 — winget fuzzy pickers (wins / wrm / wup)
#
# Interactive winget workflows built on Invoke-DFPicker + fzf, with a live
# preview pane (Name/Description/Version/Publisher/License/Homepage summary
# above the full `winget show` output). Package data comes from the Microsoft.WinGet.Client
# module (objects, not scraped CLI tables), so filtering matches name OR id.
#
# Requires:
#   - fzf on PATH (or set $Env:Picker = 'skim')
#   - the Microsoft.WinGet.Client module:
#       Install-Module Microsoft.WinGet.Client -Scope CurrentUser
#     (the pickers warn and no-op if it is missing)

Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -Name winget    # registers wins / wrm / wup (or use -All)

# ── Search → install ────────────────────────────────────────────────────────
# Each row shows Name / Id / Version; the preview pane summarizes then shows the full `winget show` output.
#   Enter  → returns the install command string (review / edit / run / pipe it)
#   Alt-R  → installs the selected package now
#   Alt-I  → installs the highlighted package in place, WITHOUT leaving fzf,
#            so you can walk the list installing several
wins ripgrep
wins                            # no query → prompts for a search term

# Enter returns a string, so you can capture or run it:
$cmd = wins ripgrep             # e.g. 'winget install --id BurntSushi.ripgrep.MSVC --exact'
# Invoke-Expression $cmd        # ...then run it when ready

# ── Command-line prefill (PSReadLine chord) ─────────────────────────────────
# For an editable command on your prompt instead of returned text: type a search
# term and press Ctrl+G then W. The picker opens; on Enter the line is replaced
# with the install command, cursor at the end — edit if you like, press Enter to
# run. (Bound automatically when PSReadLine is loaded; uses the current line as
# the query.) scoop uses Ctrl+G S, choco uses Ctrl+G C.
#
#   ripgrep<Ctrl+G><W>   ->   winget install --id BurntSushi.ripgrep.MSVC --exact

# ── Browse installed → uninstall ────────────────────────────────────────────
#   Enter  → uninstall the selection
#   Alt-X  → uninstall the highlighted package in place (keep browsing)
#   Alt-C  → return the uninstall command instead of running it
wrm

# ── Browse upgradable → update (multi-select) ───────────────────────────────
#   Tab    → mark a package (multi-select)
#   Enter  → update every marked package
#   Alt-A  → run `winget upgrade --all`
wup

# ── The keybindings come from Invoke-DFPicker ───────────────────────────────
# -Expect gives multi-key mode (returns a { Key; Selected } object so a caller
# can branch on the pressed key); -Bind wires up act-in-place execute() keys;
# -FzfArgs passes extra fzf flags through verbatim. Example of rolling your own:
#
#   $r = Invoke-DFPicker -List { Get-ChildItem -Name } -Expect 'alt-e' `
#            -Header 'Enter=print | Alt-E=edit'
#   if     ($r.Key -eq 'alt-e') { code $r.Selected }
#   elseif ($r)                 { $r.Selected }
