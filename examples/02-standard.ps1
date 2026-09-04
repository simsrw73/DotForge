#Requires -Version 7.0
# DotForge standard profile
# ─────────────────────────────────────────────────────────────────────────────
# Typical single-developer setup: package manager preference, default-tool role
# winners, and a first-run bootstrap that installs missing core tools.

# ── DotForge config (set BEFORE Import-Module) ────────────────────────────────
$DFConfig = @{
    # Package manager priority for Install-DFTool
    PackageManagerOrder = @('scoop', 'winget')

    # eza and lsd both declare role: 'listing' and compete for ls/ll/la/tree.
    # Defaults names the winner; the loser keeps everything else it declares
    # (XDG config, other aliases) -- only the contested alias keys are suppressed.
    Defaults = @{ listing = 'eza' }

    # If Coreutils for Windows is installed, its readline hook rewrites command
    # names before PowerShell resolves them, so DotForge aliases sharing a name
    # (cat, touch, env, paste) never run. Register-DFTool warns once; see
    # `Get-DFCommandConflict` and the Coreutils Conflicts section of the README.
    # List commands here to keep coreutils' version and silence the warning:
    #   IgnoreConflicts = @('cat')
    # Or turn the check off entirely:
    #   SkipConflictCheck = $true

    # Theme selection for tools whose companions ship themes. Each accepts a
    # bundled name, a name under $XDG_CONFIG_HOME/<tool>/themes/, or a full path.
    # One shared theme for every viewer; per-tool keys override it. The shared
    # Theme key must be the canonical family name (e.g. 'catppuccin-mocha', not
    # the bare 'catppuccin' — DotForge resolves each tool's own dialect from it,
    # e.g. mdv's native 'catppuccin'). Per-tool keys accept the canonical name
    # OR that tool's own native names:
    #   Theme           = 'catppuccin-mocha'   # glow, mdcat, mdv, psreadline, delta, bat
    #   MdcatTheme      = 'dracula'             # override just mdcat
    #   MdvTheme        = 'nord'                # override just mdv
    #   GlowTheme       = 'catppuccin-mocha'    # override just glow
    #   PSReadLineTheme = 'catppuccin-mocha'    # override just psreadline
    #   DeltaTheme      = 'catppuccin-mocha'    # override just delta (a delta
    #                                           #   config must define the feature)
    #   BatTheme        = 'catppuccin-mocha'    # override just bat
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
