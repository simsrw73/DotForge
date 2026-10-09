BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/ps-dotenv.ps1'
    $fakeDir = Join-Path $TestDrive 'fake\Dotenv'
    New-Item -ItemType Directory -Force $fakeDir | Out-Null
    $script:FakeModule = Join-Path $fakeDir 'Dotenv.psm1'
    @'
$Dotenv = [pscustomobject]@{ Enabled = $false; SafeMode = $false; Async = $true }
function Enable-Dotenv { $Dotenv.Enabled = $true }
function Approve-DotenvDir { param([Parameter(Mandatory)][string]$Path) if ($Path -like '*bad*') { throw 'nope' }; $global:FakeDotenvCalls += "approve:$Path" }
function Update-Dotenv { $global:FakeDotenvCalls += 'update' }
Export-ModuleMember -Function * -Variable Dotenv
'@ | Set-Content $script:FakeModule
}

Describe 'ps-dotenv project-env hook' {
    BeforeEach {
        $global:FakeDotenvCalls = @()
        $script:SavedLca = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
        $script:SavedLoc = Get-Location
        Remove-Variable DFConfig, DFDotenvLocationHook -Scope Global -ErrorAction Ignore
        Mock Get-Module { [pscustomobject]@{ Path = $script:FakeModule } } -ParameterFilter { $ListAvailable }
        . $script:CompanionPath
    }
    AfterEach {
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:SavedLca
        Set-Location $script:SavedLoc
        Remove-Module Dotenv -Force -ErrorAction Ignore
        Remove-Variable DFConfig, DFDotenvLocationHook, FakeDotenvCalls, Dotenv -Scope Global -ErrorAction Ignore
    }

    It 'imports by the discovered path, enables, turns safe mode on and async off, and loads the start folder' {
        . Initialize-DFRoleProjectEnv -Role project-env
        $Dotenv.Enabled | Should -BeTrue
        $Dotenv.SafeMode | Should -BeTrue
        $Dotenv.Async | Should -BeFalse
        $global:FakeDotenvCalls | Should -Contain 'update'
    }

    It 'leaves safe mode off when DotenvSafeMode is $false' {
        $Global:DFConfig = @{ DotenvSafeMode = $false }
        . Initialize-DFRoleProjectEnv -Role project-env
        $Dotenv.SafeMode | Should -BeFalse
    }

    It 'approves each listed folder, expanding ~, and warns about one that fails' {
        $Global:DFConfig = @{ DotenvApprovedDirs = @('~\projects', 'C:\bad') }
        $w = . Initialize-DFRoleProjectEnv -Role project-env 3>&1
        $global:FakeDotenvCalls | Should -Contain "approve:$(Join-Path $HOME 'projects')"
        "$w" | Should -Match 'C:\\bad'
    }

    It 'skips a relative approved folder instead of binding it to the current folder' {
        $Global:DFConfig = @{ DotenvApprovedDirs = @('relative\dir') }
        . Initialize-DFRoleProjectEnv -Role project-env 3>$null
        @($global:FakeDotenvCalls | Where-Object { $_ -like 'approve:*' }).Count | Should -Be 0
    }

    It 'updates on Set-Location, keeping an existing handler' {
        $global:PrevHandlerRan = $false
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = [EventHandler[System.Management.Automation.LocationChangedEventArgs]] { $global:PrevHandlerRan = $true }
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:FakeDotenvCalls = @()
        Set-Location $TestDrive
        $global:FakeDotenvCalls | Should -Contain 'update'
        $global:PrevHandlerRan | Should -BeTrue
        Remove-Variable PrevHandlerRan -Scope Global
    }

    It 'does not chain itself twice when registered again in the same session' {
        . Initialize-DFRoleProjectEnv -Role project-env
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:FakeDotenvCalls = @()
        Set-Location $TestDrive
        @($global:FakeDotenvCalls | Where-Object { $_ -eq 'update' }).Count | Should -Be 1
    }
}
