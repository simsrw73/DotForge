# One-time setup for delta — add an [include] line to the user's real global
# git config pointing at the bundled catppuccin theme file (deployed by
# Tools/delta.ps1), so DELTA_FEATURES=+catppuccin-mocha resolves to a real
# [delta "catppuccin-mocha"] style block instead of a dead pointer. Runs at
# most once ever per machine, gated by Invoke-DFToolCompanion on
# Get-DFToolSetupState; a thrown error here is caught by the caller, which
# retries the whole script from scratch next time, so every step below must
# stay safe to re-run. See
# docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md Section 3.

$_deployedPath = Expand-DFXdgPath '${XDG_CONFIG_HOME}/delta/catppuccin.gitconfig'

$_existing = git config --global --get-all include.path 2>$null
if ($_existing -notcontains $_deployedPath) {
    git config --global --add include.path $_deployedPath
    Write-Host "DotForge: added catppuccin theme include to your global git config — remove with: git config --global --unset-all include.path `"$_deployedPath`"" -ForegroundColor Green
}

Complete-DFToolSetup -Name 'delta' -Actions @(
    @{ type = 'gitConfigInclude'; path = $_deployedPath }
)
