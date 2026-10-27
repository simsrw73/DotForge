# One-time setup for claude-code: Windows-friendly settings in $CLAUDE_CONFIG_DIR\settings.json,
# each added only when the file doesn't have it (a key you set is never changed):
#   defaultShell = powershell                 (! commands run in PowerShell)
#   env.CLAUDE_CODE_USE_POWERSHELL_TOOL = 1   (the PowerShell tool)
#   env.CLAUDE_CODE_GIT_BASH_PATH             (Git Bash, for the Bash and Monitor tools, when git is installed)
# A settings.json that isn't valid JSON is left alone (Read-DFClaudeSettings notes it). The theme
# is the companion's (Tools/claude-code.ps1), which runs right after this.
. (Join-Path $PSScriptRoot 'claude-code' 'common.ps1')

$_settings = Read-DFClaudeSettings
if ($null -ne $_settings) {
    $_changed = $false
    if (-not $_settings.Contains('defaultShell')) { $_settings['defaultShell'] = 'powershell'; $_changed = $true }
    if (-not $_settings.Contains('env')) { $_settings['env'] = [ordered]@{}; $_changed = $true }
    $_env = $_settings['env']
    if ($_env -is [System.Collections.IDictionary]) {
        if (-not $_env.Contains('CLAUDE_CODE_USE_POWERSHELL_TOOL')) { $_env['CLAUDE_CODE_USE_POWERSHELL_TOOL'] = '1'; $_changed = $true }
        $_bash = Find-DFGitBash
        if ($_bash -and -not $_env.Contains('CLAUDE_CODE_GIT_BASH_PATH')) { $_env['CLAUDE_CODE_GIT_BASH_PATH'] = $_bash; $_changed = $true }
    }
    if ($_changed) { Save-DFClaudeSettings -Settings $_settings }
}
Complete-DFToolSetup -Name 'claude-code'
