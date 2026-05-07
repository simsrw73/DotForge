#Requires -Version 7.0
# DotForge standard profile
# ─────────────────────────────────────────────────────────────────────────────
# Typical single-developer setup: package manager preference, tools to skip,
# and a first-run bootstrap that installs missing core tools.

# ── DotForge config (set BEFORE Import-Module) ────────────────────────────────
$DFConfig = @{
    # Package manager priority for Install-DFTool
    PackageManagerOrder = @('scoop', 'winget')

    # Tools excluded from Register-DFTool -All
    # lsd conflicts with eza; both provide ls — keep only one
    SkipTools = @('lsd')
}

Import-Module DotForge

# ── First-run bootstrap ────────────────────────────────────────────────────────
# Install core tools if any are missing. Runs fast because Install-DFTool
# is a no-op for tools that are already on PATH.
$coreTools = @('eza', 'bat', 'fzf', 'ripgrep', 'zoxide', 'fd', 'delta', 'gh')
$missing = $coreTools | Where-Object { -not (Get-Command "$_.exe" -ErrorAction Ignore) }
if ($missing) {
    Initialize-DFEnvironment
    Install-DFTool -Name $missing
}

# ── Configure all installed tools ─────────────────────────────────────────────
Register-DFTool -All

# ── Prompt ────────────────────────────────────────────────────────────────────
# oh-my-posh is registered above (if installed); fpot lets you preview themes
# oh-my-posh init pwsh --config "$Env:XDG_CONFIG_HOME\oh-my-posh\catpow.omp.yaml" |
#     Invoke-Expression
