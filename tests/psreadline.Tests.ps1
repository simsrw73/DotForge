BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'psreadline tool sidecar' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
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
        (Get-PSReadLineOption).BellStyle           | Should -Be 'None'
        (Get-PSReadLineOption).HistoryNoDuplicates | Should -BeTrue
    }

    It 'applies the dark theme by default (Colors.Command is non-null)' {
        # NOTE: Get-PSReadLineOption.Colors returns $null when output is redirected
        # (PSReadLine disables color support without VT). The sidecar also stores the
        # applied colors in $global:DFPSReadLineColors for testability.
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        $commandColor | Should -Not -BeNullOrEmpty
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

    It 'applies a theme from XDG user dir, overriding bundled name' {
        # NOTE: Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
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
