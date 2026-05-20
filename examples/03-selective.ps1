#Requires -Version 7.0
# DotForge selective profile
# ─────────────────────────────────────────────────────────────────────────────
# Register only specific tool groups rather than everything at once.
# Good for: keeping startup lean, staging tools by group, or troubleshooting.

$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget', 'choco')
}

Import-Module DotForge

Initialize-DFEnvironment

# ── Prompt (must register before zoxide) ──────────────────────────────────────
# oh-my-posh wraps function:prompt; zoxide must wrap it afterwards.
# Register PSFzf and Terminal-Icons here too — no ordering constraint.
Register-DFTool -Name PSFzf, Terminal-Icons, oh-my-posh

# ── Group 1: Core file tools ───────────────────────────────────────────────────
# Registers: ls/ll/la/tree aliases (eza), cat alias (bat), ff picker (eza+bat),
#            ffd picker (fd), frg picker (ripgrep), fzo directory picker + z/zi (zoxide)
Register-DFTool -Name eza, bat, fd, ripgrep, fzf, zoxide

# ── Group 2: Git stack ────────────────────────────────────────────────────────
# Registers: git diff pager (delta), lazygit/lg alias, fco/flog/fga/fstash pickers (posh-git)
Register-DFTool -Name delta, lazygit, posh-git

# ── Group 3: Dev tools ────────────────────────────────────────────────────────
# Registers: gh/fpr/fgi (GitHub CLI), nvm/fnv, npm/nls/fns, uv/fvenv
Register-DFTool -Name gh, nvm, npm, uv, chezmoi
