BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'fzf tool sidecar' {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg
        $script:SavedFzfOpts    = $Env:FZF_DEFAULT_OPTS

        Remove-Item Env:\FZF_DEFAULT_OPTS -ErrorAction Ignore

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:FZF_DEFAULT_OPTS = $script:SavedFzfOpts
        $script:DFToolDb      = $null

        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplyFzfTheme'
        Restore-DFTestXdg
    }

    It 'applies the catppuccin-mocha theme by default, preserving the existing non-color options' {
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
        $Env:FZF_DEFAULT_OPTS | Should -Match 'hl\+:#f38ba8'
        $Env:FZF_DEFAULT_OPTS | Should -Match '--layout=reverse'
        $Env:FZF_DEFAULT_OPTS | Should -Match '--inline-info'
    }

    It 'follows the shared $DFConfig[Theme] key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
    }

    It 'lets $DFConfig[FzfTheme] override the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; FzfTheme = 'custom' }
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        @'
{ "name": "custom", "colors": { "bg+": "#000000", "hl": "#ffffff" } }
'@ | Set-Content (Join-Path $userDir 'custom.json')

        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#000000'
        $Env:FZF_DEFAULT_OPTS | Should -Not -Match 'bg\+:#313244'
    }

    It 'prefers an XDG user-dir theme over a same-named bundled theme' {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        $overridePath = Join-Path $userDir 'catppuccin-mocha.json'
        @'
{ "name": "catppuccin-mocha", "colors": { "bg+": "#ABCDEF" } }
'@ | Set-Content $overridePath

        try {
            Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
            $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#ABCDEF'
        } finally {
            # This file shares a name with the bundled default theme and $TestDrive
            # persists across It blocks in this file -- remove it so later tests
            # relying on the real bundled catppuccin-mocha values aren't polluted.
            Remove-Item $overridePath -ErrorAction Ignore
        }
    }

    It 'rejects a color value that would inject an extra fzf flag, without throwing' {
        # FZF_DEFAULT_OPTS is tokenized by fzf as additional CLI args, so an
        # unvalidated value containing a newline could smuggle in a flag like
        # --bind=execute(...). This must be dropped, not passed through.
        Set-DFTestConfig @{ FzfTheme = 'malicious' }
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        $themeJson = @{
            name   = 'malicious'
            colors = @{ bg = "auto`n--bind=execute(calc.exe)" }
        } | ConvertTo-Json
        Set-Content -Path (Join-Path $userDir 'malicious.json') -Value $themeJson

        $warnings = Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'invalid fzf color entry' } | Should -Not -BeNullOrEmpty
        $Env:FZF_DEFAULT_OPTS | Should -Not -Match '--bind'
    }

    It 'warns when the named theme is not found' {
        Set-DFTestConfig @{ FzfTheme = 'nonexistent-theme' }
        $warnings = Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'not found' } | Should -Not -BeNullOrEmpty
    }

    It 'tolerates $DFConfig being set to $null' {
        Set-DFTestConfig $null
        { Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools } | Should -Not -Throw
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
    }
}
