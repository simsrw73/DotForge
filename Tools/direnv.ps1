# Companion for direnv — per-directory .envrc loading.
#
# Its hook (only when direnv wins project-env) fills in DIRENV_BASH from Git for
# Windows' bash when unset (direnv.toml's bash_path still wins), and warns while
# the installed direnv has the Windows bug that unloads unrelated variables
# (direnv#1488; see docs/external-dependencies.md).
#
# direnv's pwsh hook attaches to
# $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction (fires on
# Set-Location), not function:prompt like zoxide/oh-my-posh — so unlike that
# pair (see CLAUDE.md's prompt-hook-ordering note), registration order
# relative to them doesn't matter here.
#
# The hook requires PowerShell 7.2+ and throws below that (direnv's own
# generated script does `if ($PSVersionTable.PSVersion... -lt 7.2) { throw }`);
# guard here so a PS 7.0/7.1 session degrades to a warning instead of a
# broken one. Not unit tested: $PSVersionTable is AllScope+Constant, so it
# cannot be shadowed or overridden from a test to exercise the else branch
# without an actual sub-7.2 PowerShell install. The generated hook text
# embeds direnv.exe's own resolved path, so it's still a pure function of
# the binary for Get-DFCachedCommandOutput's path+mtime fingerprint (same
# pattern as Tools/zoxide.ps1).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# Last direnv release with the Windows variable-unloading bug (direnv#1488); see
# docs/external-dependencies.md. Raise it if a release still has the bug.
$DFDirenvLastBuggyVersion = [version]'2.37.1'

function Find-DFGitBash {
    <#
    .SYNOPSIS
        Returns Git for Windows' bash.exe: the first <ancestor>\bin\bash.exe above git.exe, never one under Windows.
    #>
    param([string]$GitPath = (Get-Command git.exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source)
    if (-not $GitPath) { return }
    # A scoop shim (shims\git.exe) sits nowhere near Git's own folder; follow it
    # to the real git.exe first (Resolve-DFExecutableTarget reads the .shim file).
    $GitPath = Resolve-DFExecutableTarget -Path $GitPath
    $dir = Split-Path $GitPath -Parent
    while ($dir) {
        $bash = Join-Path $dir 'bin\bash.exe'
        if ((Test-Path -LiteralPath $bash -PathType Leaf) -and -not ($Env:WINDIR -and $bash -like "$Env:WINDIR\*")) { return $bash }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { return }
        $dir = $parent
    }
}

function Test-DFDirenvBuggyVersion {
    <#
    .SYNOPSIS
        True when direnv's version text is at or below the last release with the Windows unloading bug.
    #>
    param([AllowEmptyString()][string]$VersionText)
    if ($VersionText -notmatch '(\d+\.\d+\.\d+)') { return $false }
    [version]$Matches[1] -le $DFDirenvLastBuggyVersion
}

function Initialize-DFRoleProjectEnv {
    # Called by DotForge only when direnv wins the project-env role.
    param([PSCustomObject]$Tool, [string]$Role)
    # direnv.toml's bash_path, when set, still wins over DIRENV_BASH (direnv's own
    # precedence), and DotForge never writes direnv.toml.
    if (-not $Env:DIRENV_BASH) {
        $gitBash = Find-DFGitBash
        if ($gitBash) { $Env:DIRENV_BASH = $gitBash }
        else { Write-Warning "DotForge: direnv needs Git for Windows' bash; set bash_path in direnv.toml or DIRENV_BASH." }
    }
    $direnvVersion = Get-DFCachedCommandOutput -Name 'direnv-version' -Executable 'direnv' -Generate { direnv version | Out-String }
    if (Test-DFDirenvBuggyVersion -VersionText $direnvVersion) {
        Write-Warning ("DotForge: direnv $($direnvVersion.Trim()) on Windows unloads environment variables it didn't set (direnv#1488). " +
            "Consider ps-dotenv: `$DFConfig.Defaults = @{ 'project-env' = 'ps-dotenv' }")
    }
    if ($PSVersionTable.PSVersion -ge [version]'7.2') {
        Invoke-Expression (Get-DFCachedCommandOutput -Name 'direnv-hook' -Executable 'direnv' -Generate {
            direnv hook pwsh | Out-String
        })
    } else {
        Write-Warning "DotForge: direnv requires PowerShell 7.2+ (found $($PSVersionTable.PSVersion)) — hook not installed."
    }
}
