BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
}

Describe 'Invoke-DFToolCompanion' {
    BeforeEach {
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null
        $script:SavedStateHome = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive 'state'
    }
    AfterEach {
        $Env:XDG_STATE_HOME = $script:SavedStateHome
        Remove-Variable -Name CompanionSawCurrentTool -Scope Global -ErrorAction Ignore
    }

    It 'dot-sources the regular companion, exposing $DFCurrentTool to it' {
        '$global:CompanionSawCurrentTool = $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'companiontool.ps1')
        $tool = '{ "name": "companiontool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        $global:CompanionSawCurrentTool | Should -Be 'companiontool'
    }

    It 'does not leak $DFCurrentTool beyond Invoke-DFToolCompanion''s own scope' {
        # PowerShell tears down a function's local scope automatically on return,
        # so this holds regardless of whether Remove-Variable executes -- confirmed
        # empirically during review. This guards the invariant itself (no accidental
        # global/script leak), not the Remove-Variable calls, whose own effect isn't
        # independently observable from outside the function.
        'Set-Content (Join-Path $TestDrive "marker.txt") -Value "ran"' |
            Set-Content (Join-Path $script:TmpTools 'nodfcurrenttool.ps1')
        $tool = '{ "name": "nodfcurrenttool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        Get-Variable -Name DFCurrentTool -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
        Get-Variable -Name DFCurrentTool -ErrorAction Ignore | Should -BeNullOrEmpty
    }

    It 'does nothing when no companion .ps1 exists' {
        $tool = '{ "name": "nocompaniontool" }' | ConvertFrom-Json
        { Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'runs the one-time setup companion and it can call Complete-DFToolSetup' {
        'Complete-DFToolSetup -Name $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'setuptool.setup.ps1')
        $tool = '{ "name": "setuptool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        (Get-DFToolSetupState).PSObject.Properties['setuptool'] | Should -Not -BeNullOrEmpty
    }

    It 'does not re-run one-time setup on a second call' {
        $runCountFile = Join-Path $TestDrive 'runcount.txt'
        # Double-quoted here-string interpolates $runCountFile now, but the backtick
        # keeps `$DFCurrentTool` literal -- it must only be evaluated later, when
        # Invoke-DFToolCompanion dot-sources this generated file.
        @"
'x' | Add-Content -Path '$runCountFile'
Complete-DFToolSetup -Name `$DFCurrentTool.name
"@ | Set-Content (Join-Path $script:TmpTools 'oncetool.setup.ps1')
        $tool = '{ "name": "oncetool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        (Get-Content $runCountFile).Count | Should -Be 1
    }

    It 'skips one-time setup when the tool is in -SkipSetup' {
        'Complete-DFToolSetup -Name $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'skippedtool.setup.ps1')
        $tool = '{ "name": "skippedtool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -SkipSetup @('skippedtool')
        (Get-DFToolSetupState).PSObject.Properties['skippedtool'] | Should -BeNullOrEmpty
    }

    It 'warns and continues when the one-time setup script throws' {
        'throw "boom"' | Set-Content (Join-Path $script:TmpTools 'throwtool.setup.ps1')
        $tool = '{ "name": "throwtool" }' | ConvertFrom-Json
        { Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -WarningVariable warns 3>$null } |
            Should -Not -Throw
        (Get-DFToolSetupState).PSObject.Properties['throwtool'] | Should -BeNullOrEmpty
    }
}
