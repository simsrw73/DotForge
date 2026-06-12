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
# Install core tools if any are missing. Only passes absent tools to
# Install-DFTool — tools already on PATH are filtered out by $missing.
$coreTools = @('eza', 'bat', 'fzf', 'ripgrep', 'zoxide', 'fd', 'delta', 'gh')
$missing = $coreTools | Where-Object { -not (Get-Command "$_.exe" -ErrorAction Ignore) }
if ($missing) {
    Initialize-DFEnvironment
    Install-DFTool -Name $missing
}

# ── Configure all installed tools ─────────────────────────────────────────────
# oh-my-posh and zoxide inits are handled by their companions inside Register-DFTool.
# Set $Env:POSH_THEME before this line to pin a specific config file; otherwise the
# companion auto-discovers *.omp.* from $XDG_CONFIG_HOME/oh-my-posh/ (warns if ambiguous).
# Use fpot in-session to preview and switch themes (note: theme switch breaks zoxide
# directory tracking for the rest of that session — known limitation).
Register-DFTool -All

# ── General helpers now available ─────────────────────────────────────────────
# Importing DotForge also exposes helper aliases, e.g.:
#   hm <name>   colorized PowerShell Get-Help
#   clh <cmd>   colorized help for an external CLI tool (eza, git, docker, ...)
#   clhp <cmd>  same as clh, through the pager
# clh auto-detects each tool's help flag and caches it under $XDG_CACHE_HOME/dotforge.
