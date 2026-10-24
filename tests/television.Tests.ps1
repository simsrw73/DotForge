BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
    # A stripped tv init script (Remove-DFKeyHandlerCall has run on it).
    $script:Init = @'
function Invoke-TvSmartAutocomplete { 'auto' }
function Invoke-TvShellHistory { 'history' }
'@
}

Describe 'television companion' {
    BeforeEach {
        Mock Set-DFRoleKeyHandler { & $Bind }
        Mock Set-PSReadLineKeyHandler { }
    }
    AfterEach { Remove-Module DotForge.Television -ErrorAction Ignore }

    It 'loads tv''s functions without its key bindings and binds Ctrl+r from the hook' {
        Mock Get-DFCachedCommandOutput { $script:Init }
        . (Join-Path $script:Tools 'television.ps1')
        Get-Command Invoke-TvShellHistory -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        Should -Invoke Set-PSReadLineKeyHandler -Times 0
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'television' }) -Role 'history-search'
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+r' }
    }
    It 'leaves Ctrl+t unbound, with a note, when tv no longer defines its function' {
        Reset-DFTestSession
        Mock Get-DFCachedCommandOutput { 'function Invoke-TvShellHistory { }' }
        . (Join-Path $script:Tools 'television.ps1')
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'television' }) -Role 'path-insert'
        Should -Invoke Set-PSReadLineKeyHandler -Times 0
        Get-DFToolNote -Tool television | Should -Match 'Invoke-TvSmartAutocomplete'
    }
    It 'loads nothing, with a note, when tv''s script couldn''t be read' {
        Reset-DFTestSession
        Mock Get-DFCachedCommandOutput { $null }
        $DFCurrentTool = [pscustomobject]@{ name = 'television' }
        . (Join-Path $script:Tools 'television.ps1')
        Get-Module DotForge.Television | Should -BeNullOrEmpty
        Get-DFToolNote -Tool television | Should -Match 'integration'
    }
}

Describe 'television setup' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'television') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Get-DFCachedCommandOutput { '' }
        Mock Write-Host { }
        $global:DFTestTvExit = 0
        $global:DFTestTvCalls = @()
        function global:tv { }
        Mock Invoke-DFBoundedProcess { $global:DFTestTvCalls += ,@($ArgumentList); [pscustomobject]@{ Lines = @(); ExitCode = $global:DFTestTvExit } }
        $script:Config = Join-Path $Env:XDG_CONFIG_HOME 'television' 'config.toml'
        # Start unset: a developer may have TELEVISION_CONFIG in their own environment.
        $script:SavedTvConfig = $Env:TELEVISION_CONFIG
        $Env:TELEVISION_CONFIG = $null
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'tv'
        Remove-Variable -Scope Global -Name DFTestTvExit, DFTestTvCalls -ErrorAction Ignore
        Remove-Module DotForge.Television -ErrorAction Ignore
        $Env:TELEVISION_CONFIG = $script:SavedTvConfig
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'seeds the config with the theme, the four theme files, and downloads the channels once' {
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Match 'theme = "catppuccin-mocha"'
        @(Get-ChildItem (Join-Path $Env:XDG_CONFIG_HOME 'television' 'themes') -Filter 'catppuccin-*.toml').Count | Should -Be 4
        @($global:DFTestTvCalls | Where-Object { $_ -contains 'update-channels' }).Count | Should -Be 1
        @((Get-DFToolSetupState).television.notes) | Should -BeNullOrEmpty
        $Env:TELEVISION_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'television')
    }
    It 'follows Theme in the seeded config' {
        Start-DFSession -Config @{ Tools = @('television'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Match 'theme = "catppuccin-latte"'
    }
    It 'keeps an existing config and leaves a note about ui.theme' {
        New-Item -ItemType Directory (Split-Path $script:Config) -Force | Out-Null
        Set-Content $script:Config 'mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be 'mine'
        "$((Get-DFToolSetupState).television.notes)" | Should -Match 'ui\.theme'
    }
    It 'still completes when the download fails, with a note to run it by hand' {
        $global:DFTestTvExit = 1
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['television'] | Should -Not -BeNullOrEmpty
        "$((Get-DFToolSetupState).television.notes)" | Should -Match 'tv update-channels'
    }
    It 'gives up on a download that hangs, still completes, and leaves the note' {
        Mock Invoke-DFBoundedProcess { throw "DotForge: 'tv update-channels' did not finish within 60 s and was stopped." }
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -ParameterFilter { $TimeoutSeconds -le 120 -and $ArgumentList -contains 'update-channels' }
        (Get-DFToolSetupState).PSObject.Properties['television'] | Should -Not -BeNullOrEmpty
        "$((Get-DFToolSetupState).television.notes)" | Should -Match 'tv update-channels'
    }
}
