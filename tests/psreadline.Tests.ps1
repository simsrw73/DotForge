BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'psreadline tool sidecar' {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg




        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {

        $script:DFToolDb     = $null

        Set-DFTestConfig $null
        Remove-Variable DFPSReadLineColors    -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'Select-PSReadLineTheme', 'Invoke-DFApplyPSReadLineTheme'
        Remove-Alias fprl -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg
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
        Set-DFTestConfig @{ PSReadLineEditMode = 'Windows' }
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
        Set-DFTestConfig @{ PSReadLineTheme = 'light' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        # Light theme Command color is #0000ff — VT sequence contains "0;0;255"
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        $commandColor | Should -Match '0;0;255'
    }

    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> mocha)' {
        # Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # catppuccin-mocha Command color is #cba6f7 -> VT contains "203;166;247"
        $commandColor | Should -Match '203;166;247'
    }

    It 'lets PSReadLineTheme override the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; PSReadLineTheme = 'light' }
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
        Set-DFTestConfig @{ PSReadLineTheme = 'dark' }
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
        Set-DFTestConfig @{ PSReadLineTheme = 'badcolors' }
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
        Set-DFTestConfig @{ PSReadLineTheme = 'nonexistent-theme' }
        $warnings = Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'not found' } | Should -Not -BeNullOrEmpty
    }

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        Set-DFTestConfig $null
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
