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
# psreadline must come before PSFzf (PSFzf depends on it for key-binding setup).
# Terminal-Icons has no ordering constraint.
Register-DFTool -Name psreadline, Terminal-Icons, oh-my-posh
Register-DFTool -Name PSFzf

# ── Group 1: Core file tools ───────────────────────────────────────────────────
# Registers: ls/ll/la/tree aliases (eza), cat alias (bat), ff picker (eza+bat),
#            ffd picker (fd), frg picker (ripgrep), fzo directory picker + cd/cdi (zoxide)
Register-DFTool -Name eza, bat, fd, ripgrep, fzf, zoxide

# ── Group 2: Git stack ────────────────────────────────────────────────────────
# Registers: git diff pager (delta), lazygit/lg alias, fco/flog/fga/fstash pickers (posh-git)
Register-DFTool -Name delta, lazygit, posh-git

# ── Group 3: Dev tools ────────────────────────────────────────────────────────
# Registers: gh/fpr/fgi (GitHub CLI), npm/nls/fns, uv/fvenv, fnm (Node version mgr)
# fnm's --use-on-cd hook rebinds `cd`, so it must register AFTER zoxide (done in
# Group 1) — its companion captures zoxide's `cd` and chains through it, so the
# smart jump and the per-directory Node switch both fire. In one combined
# Register-DFTool call, fnm.json's "dependsOn": ["zoxide"] enforces this order for
# you; across separate calls like this, just keep zoxide's group first.
Register-DFTool -Name gh, npm, uv, chezmoi, fnm
