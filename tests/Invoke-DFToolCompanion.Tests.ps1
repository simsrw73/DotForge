BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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

    It 'calls a won role hook from the companion with -Tool and -Role, and not a lost one' {
        @'
function Initialize-DFRoleWon  { param($Tool, $Role) $global:HookSaw = "$($Tool.name):$Role" }
function Initialize-DFRoleLost { param($Tool, $Role) $global:HookSaw = 'lost' }
'@ | Set-Content (Join-Path $script:TmpTools 'hooktool.ps1')
        $tool = '{ "name": "hooktool" }' | ConvertFrom-Json
        $won = [pscustomobject]@{ Role = 'won'; Hook = 'Initialize-DFRoleWon'; HookRequired = $true }
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -WonRoles @($won)
        $global:HookSaw | Should -Be 'hooktool:won'
        Remove-Variable HookSaw -Scope Global
    }

    It 'is not thrown off by a companion or hook that reuses its local variable names' {
        @'
$Tool = $null; $ToolsPath = 'C:
owhere'; $WonRoles = @(); $SkipSetup = @('clobtool')
$companion = 'C:
owhere.ps1'; $hasCompanion = $false; $setupCompanion = 'C:
owhere.setup.ps1'
function Initialize-DFRoleOne { param($Tool, $Role) $global:ClobCalls += "one:$($Tool.name)"; $won = $null; $WonRoles = @(); $hook = $null }
function Initialize-DFRoleTwo { param($Tool, $Role) $global:ClobCalls += "two:$($Tool.name)" }
'@ | Set-Content (Join-Path $script:TmpTools 'clobtool.ps1')
        '$global:ClobCalls += "setup"' | Set-Content (Join-Path $script:TmpTools 'clobtool.setup.ps1')
        $global:ClobCalls = @()
        $tool = '{ "name": "clobtool" }' | ConvertFrom-Json
        $won = @(
            [pscustomobject]@{ Role = 'one'; Hook = 'Initialize-DFRoleOne'; HookRequired = $true }
            [pscustomobject]@{ Role = 'two'; Hook = 'Initialize-DFRoleTwo'; HookRequired = $true }
        )
        try {
            Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -WonRoles $won -WarningAction SilentlyContinue
            $global:ClobCalls | Should -Be @('one:clobtool', 'two:clobtool', 'setup')
        } finally { Remove-Variable ClobCalls -Scope Global -ErrorAction Ignore }
    }

    It 'leaves hook functions out of every scope after it returns' {
        'function Initialize-DFRoleWon { }' | Set-Content (Join-Path $script:TmpTools 'hooktool.ps1')
        $tool = '{ "name": "hooktool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -WonRoles @()
        Test-Path function:Initialize-DFRoleWon | Should -BeFalse
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
