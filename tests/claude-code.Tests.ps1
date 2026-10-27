BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    $script:Json = Get-Content (Join-Path $script:RealTools 'claude-code.json') -Raw | ConvertFrom-Json
}

# Claude Code: installed natively into the XDG locations, config in $XDG_CONFIG_HOME\claude,
# PowerShell preferred, theme from the claude-themes plugin, cc/ccc/ccr
# (docs/superpowers/specs/2026-10-27-claude-code-design.md).
Describe 'Tools/claude-code.json' {
    It 'installs with Claude''s own script first, then winget or npm' {
        $script:Json.packages.script.id | Should -Be 'https://claude.ai/install.ps1'
        $script:Json.packages.script.installed | Should -Be '${HOME}/.local/bin/claude.exe'
        @($script:Json.packages.script.update) | Should -Be @('claude', 'update')
        @($script:Json.packages.script.remove) | Should -Be @('${HOME}/.local/bin/claude.exe', '${XDG_DATA_HOME}/claude')
        $script:Json.packages.winget | Should -Be 'Anthropic.ClaudeCode'
        $script:Json.packages.npm | Should -Be '@anthropic-ai/claude-code'
        @($script:Json.install.prefer) | Should -Be @('script')
    }
    It 'keeps its config in $XDG_CONFIG_HOME\claude, links the old one, and offers it to desktop apps' {
        $script:Json.xdg.vars.CLAUDE_CONFIG_DIR | Should -Be '${XDG_CONFIG_HOME}/claude'
        @($script:Json.xdg.native.CLAUDE_CONFIG_DIR) | Should -Be @('${HOME}/.claude')
        @($script:Json.xdg.native.'${XDG_CONFIG_HOME}/claude/.claude.json') | Should -Be @('${HOME}/.claude.json')
        @($script:Json.desktop) | Should -Be @('CLAUDE_CONFIG_DIR')
    }
    It 'adds cc, ccc and ccr, each only where the name is free' {
        $script:Json.aliases.cc.command | Should -Be 'claude'
        @($script:Json.aliases.ccc.args) | Should -Be @('--continue')
        @($script:Json.aliases.ccr.args) | Should -Be @('--resume')
        foreach ($name in 'cc', 'ccc', 'ccr') { $script:Json.aliases.$name.ifFree | Should -BeTrue }
    }
    It 'ccr passes your arguments through' {
        function global:claude { "claude $($args -join ' ')" }
        Mock Test-DFCommandExists { $false }
        try {
            Register-DFToolAliases -Tool (ConvertTo-DFToolRecord $script:Json)
            ccr abc123 | Should -Be 'claude --resume abc123'
            ccc | Should -Be 'claude --continue'
        } finally {
            Remove-DFTestGlobal -Function 'claude', 'ccc', 'ccr'
            Remove-Alias cc -Force -Scope Global -ErrorAction Ignore
        }
    }
    It 'ranks the script installer first' {
        $db = Import-DFToolDb -Name 'claude-code', 'script', 'winget', 'npm', 'scoop' -ToolsPath $script:RealTools -Force
        (Get-DFInstallSourceOrder -Tool $db['claude-code'] -ToolDb $db)[0] | Should -Be 'script'
    }
}

# The theme steps: marketplace known, plugin installed and enabled, only then the theme key.
Describe 'Set-DFClaudeTheme' {
    BeforeAll { . "$PSScriptRoot/../Tools/claude-code/common.ps1" }
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:SavedConfigDir = $Env:CLAUDE_CONFIG_DIR
        $Env:CLAUDE_CONFIG_DIR = Join-Path $TestDrive "claude-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Force $Env:CLAUDE_CONFIG_DIR | Out-Null
        $script:Settings = Join-Path $Env:CLAUDE_CONFIG_DIR 'settings.json'
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Marketplaces = '[]'
        $script:Plugins = '[]'
        $script:Fail = ''
        Mock Invoke-DFClaudeCli {
            $line = $Arguments -join ' '
            $script:Calls.Add($line)
            if ($script:Fail -and $line -like "$($script:Fail)*") { return [pscustomobject]@{ ExitCode = 1; Output = 'network unreachable' } }
            $out = switch -Wildcard ($line) {
                'plugin marketplace list*' { $script:Marketplaces }
                'plugin list*' { $script:Plugins }
                default { '{}' }
            }
            [pscustomobject]@{ ExitCode = 0; Output = $out }
        }
    }
    AfterEach {
        $Env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
        Restore-DFTestXdg
    }

    It 'adds the marketplace, then installs the plugin, then sets the theme, in that order' {
        Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-mocha'
        $order = @($script:Calls | Where-Object { $_ -match 'marketplace add|plugin install' })
        $order[0] | Should -Match '^plugin marketplace add matcra587/claude-themes --scope user'
        $order[1] | Should -Match '^plugin install catppuccin@claude-themes --scope user'
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).theme | Should -Be 'custom:catppuccin:catppuccin-mocha'
    }
    It 'skips the marketplace and the install when both are there' {
        $script:Marketplaces = '[{ "name": "claude-themes" }]'
        $script:Plugins = '[{ "id": "catppuccin@claude-themes", "enabled": true }]'
        Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-latte'
        $script:Calls | Where-Object { $_ -match 'add|install|enable' } | Should -BeNullOrEmpty
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).theme | Should -Be 'custom:catppuccin:catppuccin-latte'
    }
    It 'enables an installed but disabled plugin before setting the theme' {
        $script:Marketplaces = '[{ "name": "claude-themes" }]'
        $script:Plugins = '[{ "id": "catppuccin@claude-themes", "enabled": false }]'
        Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-mocha'
        $script:Calls | Should -Contain 'plugin enable catppuccin@claude-themes --scope user'
    }
    It 'leaves the theme alone and says why when a step fails' {
        '{ "theme": "dark" }' | Set-Content $script:Settings
        $script:Fail = 'plugin install'
        { Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-mocha' } | Should -Not -Throw
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).theme | Should -Be 'dark'
        Get-DFToolNote -Tool 'claude-code' | Should -Match 'network unreachable'
    }
    It 'leaves a settings.json that isn''t valid JSON alone' {
        '{ "theme": "dark", // mine' | Set-Content $script:Settings
        $script:Marketplaces = '[{ "name": "claude-themes" }]'
        $script:Plugins = '[{ "id": "catppuccin@claude-themes", "enabled": true }]'
        Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-mocha'
        Get-Content $script:Settings -Raw | Should -Match '// mine'
        Get-DFToolNote -Tool 'claude-code' | Should -Match 'settings.json'
    }
    It 'does nothing, not even run claude, when the theme is already set' {
        '{ "theme": "custom:catppuccin:catppuccin-mocha" }' | Set-Content $script:Settings
        Set-DFClaudeTheme -Name 'custom:catppuccin:catppuccin-mocha'
        $script:Calls.Count | Should -Be 0
    }
    It 'sets one of Claude''s own themes directly, and leaves an unknown name alone with a note' {
        Set-DFClaudeTheme -Name 'light'
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).theme | Should -Be 'light'
        Set-DFClaudeTheme -Name 'nord-ish'
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).theme | Should -Be 'light'
        Get-DFToolNote -Tool 'claude-code' | Should -Match 'nord-ish'
    }
}

Describe 'Find-DFGitBash' {
    BeforeAll { . "$PSScriptRoot/../Tools/claude-code/common.ps1" }
    It 'prefers scoop''s current folder over the versioned one' {
        $apps = Join-Path $TestDrive 'apps' 'git'
        New-Item -ItemType File -Force (Join-Path $apps '2.56.0.2' 'bin' 'bash.exe'), (Join-Path $apps 'current' 'bin' 'bash.exe') | Out-Null
        Mock Invoke-DFGitExecPath { Join-Path $apps '2.56.0.2' 'ucrt64' 'libexec' 'git-core' }
        Find-DFGitBash | Should -Be (ConvertTo-DFPath (Join-Path $apps 'current' 'bin' 'bash.exe'))
    }
    It 'uses the git folder itself without a current link' {
        $git = Join-Path $TestDrive 'Git'
        New-Item -ItemType File -Force (Join-Path $git 'bin' 'bash.exe') | Out-Null
        Mock Invoke-DFGitExecPath { Join-Path $git 'mingw64' 'libexec' 'git-core' }
        Find-DFGitBash | Should -Be (ConvertTo-DFPath (Join-Path $git 'bin' 'bash.exe'))
    }
    It 'returns nothing without git' {
        Mock Invoke-DFGitExecPath { $null }
        Find-DFGitBash | Should -BeNullOrEmpty
    }
}

Describe 'claude-code companion' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        Mock Test-DFToolAvailable { $true }
        Mock Set-DFClaudeTheme { }
    }
    AfterEach {
        Remove-Alias cc -Force -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'ccc', 'ccr'
        $script:DFToolDb = $null
        Restore-DFTestXdg
    }
    It 'applies the session theme when the tool loads' {
        function script:Set-DFClaudeTheme { param($Name) }
        Register-DFTool -Name 'claude-code' -ToolsPath $script:RealTools 3>$null 6>$null
        Should -Invoke Set-DFClaudeTheme -Times 1 -Exactly -ParameterFilter { $Name -eq 'custom:catppuccin:catppuccin-mocha' }
    }
}

# One-time setup: Windows-friendly settings, added only where settings.json doesn't have them.
Describe 'claude-code setup' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:SavedConfigDir = $Env:CLAUDE_CONFIG_DIR
        $Env:CLAUDE_CONFIG_DIR = Join-Path $TestDrive "claude-setup-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $script:Settings = Join-Path $Env:CLAUDE_CONFIG_DIR 'settings.json'
        Mock Complete-DFToolSetup { }
        Mock Find-DFGitBash { 'C:\Git\bin\bash.exe' }
        $script:RunSetup = { $DFCurrentTool = (Import-DFToolDb -Name 'claude-code' -ToolsPath $script:RealTools -Force)['claude-code']; . (Join-Path $script:RealTools 'claude-code.setup.ps1') }
    }
    AfterEach {
        $Env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
        Restore-DFTestXdg
    }

    It 'creates settings.json with PowerShell preferred and Git Bash found, on a fresh machine' {
        & $script:RunSetup
        $settings = Get-Content $script:Settings -Raw | ConvertFrom-Json
        $settings.defaultShell | Should -Be 'powershell'
        $settings.env.CLAUDE_CODE_USE_POWERSHELL_TOOL | Should -Be '1'
        $settings.env.CLAUDE_CODE_GIT_BASH_PATH | Should -Be 'C:\Git\bin\bash.exe'
        Should -Invoke Complete-DFToolSetup -Times 1 -Exactly -ParameterFilter { $Name -eq 'claude-code' }
    }
    It 'adds only missing keys, never changing yours' {
        New-Item -ItemType Directory -Force $Env:CLAUDE_CONFIG_DIR | Out-Null
        '{ "defaultShell": "bash", "env": { "FOO": "bar", "CLAUDE_CODE_USE_POWERSHELL_TOOL": "0" }, "model": "x" }' | Set-Content $script:Settings
        & $script:RunSetup
        $settings = Get-Content $script:Settings -Raw | ConvertFrom-Json
        $settings.defaultShell | Should -Be 'bash'
        $settings.env.FOO | Should -Be 'bar'
        $settings.env.CLAUDE_CODE_USE_POWERSHELL_TOOL | Should -Be '0'
        $settings.env.CLAUDE_CODE_GIT_BASH_PATH | Should -Be 'C:\Git\bin\bash.exe'
        $settings.model | Should -Be 'x'
    }
    It 'leaves out the Git Bash path without git' {
        Mock Find-DFGitBash { $null }
        & $script:RunSetup
        (Get-Content $script:Settings -Raw | ConvertFrom-Json).env.PSObject.Properties.Name | Should -Not -Contain 'CLAUDE_CODE_GIT_BASH_PATH'
    }
    It 'leaves a settings.json that isn''t valid JSON alone, and still completes' {
        New-Item -ItemType Directory -Force $Env:CLAUDE_CONFIG_DIR | Out-Null
        '{ "defaultShell": "bash", // mine' | Set-Content $script:Settings
        & $script:RunSetup
        Get-Content $script:Settings -Raw | Should -Match '// mine'
        Should -Invoke Complete-DFToolSetup -Times 1 -Exactly
    }
    It 'records nothing when it fails' {
        Mock Save-DFClaudeSettings { throw 'disk full' }
        { & $script:RunSetup } | Should -Throw '*disk full*'
        Should -Invoke Complete-DFToolSetup -Times 0 -Exactly
    }
}
