#Requires -Version 7.0
# DotForge profile with VS Code terminal fast-path
# ─────────────────────────────────────────────────────────────────────────────
# VS Code's integrated terminal doesn't need oh-my-posh, transcripts, or
# diagnostics — just the tools. The fast-path returns early to save ~300ms.

$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')
    SkipTools           = @('lsd')
}

Import-Module DotForge

# ── VS Code fast-path ─────────────────────────────────────────────────────────
if ($Env:TERM_PROGRAM -eq 'vscode') {
    Initialize-DFEnvironment
    Register-DFTool -All
    return   # skip oh-my-posh, transcript, diagnostics below
}

# ── Full init (standard terminals) ────────────────────────────────────────────

Initialize-DFEnvironment
Register-DFTool -All

# Prompt theme (skipped in VS Code terminal above)
if (Get-Command oh-my-posh -ErrorAction Ignore) {
    $ompConfig = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh' 'theme.omp.yaml'
    if (Test-Path $ompConfig) {
        oh-my-posh init pwsh --config $ompConfig | Invoke-Expression
    }
}

# Session transcript
$transcriptDir = Join-Path $HOME 'Documents' 'PowerShell.Transcripts' (Get-Date -Format 'yyyy-MM-dd')
New-Item -ItemType Directory -Force -Path $transcriptDir | Out-Null
Start-Transcript -Path (Join-Path $transcriptDir "$PID.txt") -Append | Out-Null

# Weekly completion refresh (Fridays)
if ((Get-Date).DayOfWeek -eq 'Friday') {
    Update-DFCompletions
}
