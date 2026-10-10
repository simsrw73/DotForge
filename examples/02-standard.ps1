#Requires -Version 7.2
# DotForge standard profile
# ─────────────────────────────────────────────────────────────────────────────
# Typical single-developer setup: package manager preference, default-tool role
# winners, and an explicit opt-in tool list.

# ── DotForge config (pass to Start-DFSession -Config) ─────────────────────────
$DFConfig = @{
    Tools = @('+core', '+prompt', '+git')
    # Preferred install sources for Install-DFTool (ordering only)
    InstallOrder = @('scoop', 'winget')

    # Defaults picks the tool for each role (see Get-DFRole). eza and lsd both
    # fill 'listing' (ls/ll/la/tree); oh-my-posh and starship both fill 'prompt'.
    # Only the winner applies the role; the others stay usable by name.
    Defaults = @{ listing = 'eza'; prompt = 'oh-my-posh' }

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
    #   Theme           = 'catppuccin-mocha'   # glow, mdcat, mdv, psreadline, delta, vivid, bat
    #   MdcatTheme      = 'dracula'             # override just mdcat
    #   MdvTheme        = 'nord'                # override just mdv
    #   GlowTheme       = 'catppuccin-mocha'    # override just glow
    #   PSReadLineTheme = 'catppuccin-mocha'    # override just psreadline
    #   DeltaTheme      = 'catppuccin-mocha'    # override just delta
    #   VividTheme      = 'catppuccin-mocha'    # override just vivid (LS_COLORS)
    #   BatTheme        = 'catppuccin-mocha'    # override just bat
}

Import-Module DotForge

# If requested tools are missing, review the warning and run Install-DFTool -Missing manually.

# ── Configure requested installed tools ───────────────────────────────────────
# oh-my-posh and zoxide inits are handled by their companions inside Register-DFTool.
# Set $Env:POSH_THEME before this line to pin a specific config file; otherwise the
# companion auto-discovers *.omp.* from $XDG_CONFIG_HOME/oh-my-posh/ (warns if ambiguous).
# Use fpot in-session to preview and switch themes (note: theme switch breaks zoxide
# directory tracking for the rest of that session — known limitation).
Start-DFSession -Config $DFConfig

# ── Optional: lightweight system-info banner ──────────────────────────────────
# Uncomment to show a one-shot system summary at the top of every new shell.
# The bundled fastfetch config has no logo and skips network-dependent
# modules, so this stays fast even on a cold shell.
# if (Get-Command fastfetch.exe -ErrorAction Ignore) { fastfetch }

# ── General helpers now available ─────────────────────────────────────────────
# Importing DotForge also exposes helper aliases, e.g.:
#   hm <name>   colorized PowerShell Get-Help
#   clh <cmd>   colorized help for an external CLI tool (eza, git, docker, ...)
#   clhp <cmd>  same as clh, through the pager
# clh auto-detects each tool's help flag and caches it under $XDG_CACHE_HOME/dotforge.
