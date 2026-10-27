# One-time setup for claude-code: Windows-friendly settings in $CLAUDE_CONFIG_DIR\settings.json,
# each added only when the file doesn't have it (a key you set is never changed):
#   defaultShell = powershell                 (! commands run in PowerShell)
#   env.CLAUDE_CODE_USE_POWERSHELL_TOOL = 1   (the PowerShell tool)
#   env.CLAUDE_CODE_GIT_BASH_PATH             (Git Bash, for the Bash and Monitor tools, when git is installed)
# A settings.json that isn't valid JSON is left alone, with a setup note, and setup isn't recorded,
# so it runs again on the next load. The theme is the companion's (Tools/claude-code.ps1).
. (Join-Path $PSScriptRoot 'claude-code' 'common.ps1')

$_settings = Read-DFClaudeSettings
if ($null -eq $_settings) {
    Add-DFToolSetupNote -Name 'claude-code' -Text "$(Get-DFClaudeSettingsPath) isn't valid JSON, so DotForge didn't add its PowerShell and Git Bash settings; fix the file and open a new shell."
    return
}
if ($null -ne $_settings) {
    $_changed = $false
    if (-not $_settings.ContainsKey('defaultShell')) { Set-DFClaudeSetting -Object $_settings -Key 'defaultShell' -Value 'powershell'; $_changed = $true }
    if (-not $_settings.ContainsKey('env')) { $_settings['env'] = [System.Text.Json.Nodes.JsonObject]::new(); $_changed = $true }
    $_env = $_settings['env']
    if ($_env -is [System.Text.Json.Nodes.JsonObject]) {
        if (-not $_env.ContainsKey('CLAUDE_CODE_USE_POWERSHELL_TOOL')) { Set-DFClaudeSetting -Object $_env -Key 'CLAUDE_CODE_USE_POWERSHELL_TOOL' -Value '1'; $_changed = $true }
        $_bash = Find-DFGitBash
        if ($_bash -and -not $_env.ContainsKey('CLAUDE_CODE_GIT_BASH_PATH')) { Set-DFClaudeSetting -Object $_env -Key 'CLAUDE_CODE_GIT_BASH_PATH' -Value $_bash; $_changed = $true }
    }
    if ($_changed) { Save-DFClaudeSettings -Settings $_settings }
}
Complete-DFToolSetup -Name 'claude-code'
