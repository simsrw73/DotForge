# Companion for claude-code: applies the session theme (Tools/claude-code.json theme block:
# ClaudeTheme -> Theme -> default) through Set-DFClaudeTheme, which does nothing when settings.json
# already has it, so a normal load starts no claude process.
# Helpers: Tools/claude-code/common.ps1 (shared with claude-code.setup.ps1).
. (Join-Path $PSScriptRoot 'claude-code' 'common.ps1')

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
if ($_theme -and $_theme.Native) { Set-DFClaudeTheme -Name $_theme.Native -Background }
