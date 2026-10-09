#Requires -Version 7.0
# DotForge profile with VS Code terminal fast-path
# ─────────────────────────────────────────────────────────────────────────────
# VS Code's integrated terminal doesn't need oh-my-posh or transcripts — just
# the tools. The fast path skips them and returns early, so it starts faster.

$DFConfig = @{
    Tools               = @('+core', '+prompt')
    InstallOrder        = @('scoop', 'winget')
    Defaults            = @{ listing = 'eza' }  # eza fills the listing role (ls/ll/la/tree)
}

Import-Module DotForge

# ── VS Code fast-path ─────────────────────────────────────────────────────────
if ($Env:TERM_PROGRAM -eq 'vscode') {
    $DFConfig.ExcludeTools = @('oh-my-posh')   # VS Code shows its own status
    Start-DFSession -Config $DFConfig
    return   # skip the transcript below
}

# ── Full init (standard terminals) ────────────────────────────────────────────

Start-DFSession -Config $DFConfig   # oh-my-posh and zoxide inits handled by companions

# Session transcript
$transcriptDir = Join-Path $HOME 'Documents' 'PowerShell.Transcripts' (Get-Date -Format 'yyyy-MM-dd')
New-DFDirectory $transcriptDir
Start-Transcript -Path (Join-Path $transcriptDir "$PID.txt") -Append | Out-Null

