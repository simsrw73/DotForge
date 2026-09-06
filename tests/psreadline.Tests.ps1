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

Describe 'psreadline tool sidecar' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:XDG_STATE_HOME     = Join-Path $TestDrive 'state'

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        $script:DFToolDb     = $null

        Remove-Variable DFConfig              -Scope Global -ErrorAction Ignore
        Remove-Variable DFPSReadLineColors    -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Select-PSReadLineTheme'        -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyPSReadLineTheme' -ErrorAction Ignore
        Remove-Alias fprl -Scope Global -Force -ErrorAction Ignore
    }

    It 'registers Select-PSReadLineTheme as a global function' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Test-Path 'function:global:Select-PSReadLineTheme' | Should -BeTrue
    }

    It 'registers fprl as an alias for Select-PSReadLineTheme' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Get-Alias fprl -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'registers Invoke-DFApplyPSReadLineTheme as a global function' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Test-Path 'function:global:Invoke-DFApplyPSReadLineTheme' | Should -BeTrue
    }

    It 'applies PSReadLine settings from tool JSON' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).BellStyle                    | Should -Be 'None'
        (Get-PSReadLineOption).HistoryNoDuplicates          | Should -BeTrue
        (Get-PSReadLineOption).HistorySearchCursorMovesToEnd | Should -BeTrue
        (Get-PSReadLineOption).MaximumHistoryCount | Should -Be 10000
    }

    It 'relocates HistorySavePath under $XDG_STATE_HOME/psreadline' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).HistorySavePath | Should -Be (Join-Path $Env:XDG_STATE_HOME 'psreadline' 'history')
    }

    It 'creates the $XDG_STATE_HOME/psreadline directory' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Test-Path (Join-Path $Env:XDG_STATE_HOME 'psreadline') | Should -BeTrue
    }

    It 'defaults EditMode to Emacs when $DFConfig[PSReadLineEditMode] is not set' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).EditMode | Should -Be 'Emacs'
    }

    It 'lets $DFConfig[PSReadLineEditMode] override the default to Windows' {
        $Global:DFConfig = @{ PSReadLineEditMode = 'Windows' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).EditMode | Should -Be 'Windows'
    }

    It 'binds Ctrl+p to HistorySearchBackward' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $handler = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Ctrl+p' }
        $handler.Function | Should -Be 'HistorySearchBackward'
    }

    It 'binds Ctrl+n to HistorySearchForward' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $handler = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Ctrl+n' }
        $handler.Function | Should -Be 'HistorySearchForward'
    }

    It 'applies the catppuccin-mocha theme by default' {
        # NOTE: Get-PSReadLineOption.Colors returns $null when output is redirected
        # (PSReadLine disables color support without VT). The sidecar also stores the
        # applied colors in $global:DFPSReadLineColors for testability.
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # catppuccin-mocha Command color is #cba6f7 -> VT contains "203;166;247"
        $commandColor | Should -Match '203;166;247'
    }

    It 'applies the theme named in $DFConfig[PSReadLineTheme]' {
        # NOTE: Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
        $Global:DFConfig = @{ PSReadLineTheme = 'light' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        # Light theme Command color is #0000ff — VT sequence contains "0;0;255"
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        $commandColor | Should -Match '0;0;255'
    }

    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> mocha)' {
        # Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # catppuccin-mocha Command color is #cba6f7 -> VT contains "203;166;247"
        $commandColor | Should -Match '203;166;247'
    }

    It 'lets PSReadLineTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; PSReadLineTheme = 'light' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # light theme Command color is #0000ff -> VT contains "0;0;255"
        $commandColor | Should -Match '0;0;255'
    }

    It 'applies a theme from XDG user dir, overriding bundled name' {
        # NOTE: Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
        # Force the theme name explicitly rather than relying on the sidecar's
        # ambient default (now catppuccin-mocha, not dark) — this test is about
        # XDG-user-dir-beats-bundled resolution for a *named* theme, independent
        # of whatever the default happens to be.
        $Global:DFConfig = @{ PSReadLineTheme = 'dark' }
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        @'
{
  "name": "dark",
  "colors": {
    "Command": "#ff0000",
    "Parameter": "#00ff00",
    "String": "#0000ff",
    "Operator": "#ffffff",
    "Variable": "#00ff00",
    "Comment": "#888888",
    "Keyword": "#ff00ff",
    "Error": "#ff0000",
    "InlinePrediction": "#444444",
    "ListPrediction": "#00ffff"
  }
}
'@ | Set-Content (Join-Path $userDir 'dark.json')

        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        # User dark overrides bundled: Command = #ff0000 → VT contains "255;0;0"
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        $commandColor | Should -Match '255;0;0'
    }

    It 'warns and continues when an invalid hex color is in the theme' {
        $Global:DFConfig = @{ PSReadLineTheme = 'badcolors' }
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        @'
{
  "name": "badcolors",
  "colors": {
    "Command": "notahex",
    "Parameter": "#9cdcfe"
  }
}
'@ | Set-Content (Join-Path $userDir 'badcolors.json')

        $warnings = Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'invalid color' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when named theme is not found' {
        $Global:DFConfig = @{ PSReadLineTheme = 'nonexistent-theme' }
        $warnings = Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'not found' } | Should -Not -BeNullOrEmpty
    }

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        $Global:DFConfig = $null
        { Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools } | Should -Not -Throw
        Test-Path 'function:global:Invoke-DFApplyPSReadLineTheme' | Should -BeTrue
    }

    It 'Invoke-DFApplyPSReadLineTheme accepts an absolute path directly' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $themePath = Join-Path $script:RealTools 'psreadline' 'light.json'
        { Invoke-DFApplyPSReadLineTheme -Name $themePath } | Should -Not -Throw
        $colors = if ((Get-PSReadLineOption).Colors.Command) {
            (Get-PSReadLineOption).Colors.Command
        } else { $global:DFPSReadLineColors['Command'] }
        $colors | Should -Match '0;0;255'
    }
}
