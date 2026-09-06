BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'fzf tool sidecar' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedFzfOpts    = $Env:FZF_DEFAULT_OPTS
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        Remove-Item Env:\FZF_DEFAULT_OPTS -ErrorAction Ignore

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME  = $script:SavedConfigHome
        $Env:FZF_DEFAULT_OPTS = $script:SavedFzfOpts
        $script:DFToolDb      = $null

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyFzfTheme' -ErrorAction Ignore
    }

    It 'applies the catppuccin-mocha theme by default, preserving the existing non-color options' {
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
        $Env:FZF_DEFAULT_OPTS | Should -Match 'hl\+:#f38ba8'
        $Env:FZF_DEFAULT_OPTS | Should -Match '--layout=reverse'
        $Env:FZF_DEFAULT_OPTS | Should -Match '--inline-info'
    }

    It 'follows the shared $DFConfig[Theme] key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
    }

    It 'lets $DFConfig[FzfTheme] override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; FzfTheme = 'custom' }
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
        $Global:DFConfig = @{ FzfTheme = 'malicious' }
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
        $Global:DFConfig = @{ FzfTheme = 'nonexistent-theme' }
        $warnings = Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'not found' } | Should -Not -BeNullOrEmpty
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        { Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools } | Should -Not -Throw
        $Env:FZF_DEFAULT_OPTS | Should -Match 'bg\+:#313244'
    }
}
