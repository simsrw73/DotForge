BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'

    # A fake btop install: btop.exe, plus LibreHardwareMonitorLib.dll for the lhm build.
    function script:New-FakeBtop([string]$Build) {
        $dir = Join-Path $TestDrive "btop-$Build-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Force (Join-Path $dir 'themes') | Out-Null
        New-Item -ItemType File -Force (Join-Path $dir 'btop.exe') | Out-Null
        Set-Content (Join-Path $dir 'btop.conf') 'color_theme = "Default"'
        if ($Build -eq 'lhm') { New-Item -ItemType File -Force (Join-Path $dir 'LibreHardwareMonitorLib.dll') | Out-Null }
        $dir
    }
}

Describe 'Get-DFBtopBuild' {
    BeforeAll { . (Join-Path $script:Tools 'btop.ps1') }
    It 'tells the lhm build from the plain one, and gives nothing for a missing exe' {
        Get-DFBtopBuild -Executable (Join-Path (New-FakeBtop 'lhm') 'btop.exe') | Should -Be 'lhm'
        Get-DFBtopBuild -Executable (Join-Path (New-FakeBtop 'plain') 'btop.exe') | Should -Be 'plain'
        Get-DFBtopBuild -Executable (Join-Path $TestDrive 'nowhere' 'btop.exe') | Should -BeNullOrEmpty
        Get-DFBtopBuild -Executable '' | Should -BeNullOrEmpty
    }
}

Describe 'btop companion: elevating btop-lhm' {
    BeforeEach {
        Reset-DFTestSession
        $script:SavedPath = $Env:Path
        $global:ElevatorArgs = $null
        function global:fake-elevator.exe { $global:ElevatorArgs = @($args) }
        $DFCurrentTool = [pscustomobject]@{ name = 'btop' }
    }
    AfterEach {
        $Env:Path = $script:SavedPath
        Remove-DFTestGlobal -Function btop, fake-elevator.exe
        Remove-Variable ElevatorArgs -Scope Global -ErrorAction Ignore
    }

    It 'runs the lhm build through the active elevator, passing your arguments' {
        $dir = New-FakeBtop 'lhm'; $Env:Path = "$dir;$Env:Path"
        Mock Get-DFElevationMethod { [pscustomobject]@{ Method = 'Elevator'; Executable = 'fake-elevator.exe'; Tool = 'gsudo' } }
        . (Join-Path $script:Tools 'btop.ps1')
        btop -p 1
        $global:ElevatorArgs | Should -Be @((Join-Path $dir 'btop.exe'), '-p', '1')
    }
    It 'wraps nothing without an active elevator: <Method>' -ForEach @(@{ Method = 'RunAs' }, @{ Method = 'WindowsSudo' }, @{ Method = 'Unavailable' }, @{ Method = 'Direct' }) {
        $dir = New-FakeBtop 'lhm'; $Env:Path = "$dir;$Env:Path"
        Mock Get-DFElevationMethod { [pscustomobject]@{ Method = $Method; Executable = $null; Tool = $null } }
        . (Join-Path $script:Tools 'btop.ps1')
        Get-Command btop -CommandType Function -ErrorAction Ignore | Should -BeNullOrEmpty
    }
    It 'wraps nothing for the plain build' {
        $dir = New-FakeBtop 'plain'; $Env:Path = "$dir;$Env:Path"
        Mock Get-DFElevationMethod { [pscustomobject]@{ Method = 'Elevator'; Executable = 'fake-elevator.exe'; Tool = 'gsudo' } }
        . (Join-Path $script:Tools 'btop.ps1')
        Get-Command btop -CommandType Function -ErrorAction Ignore | Should -BeNullOrEmpty
        Should -Invoke Get-DFElevationMethod -Times 0
    }
    It 'wraps nothing, without an error, when btop isn''t on PATH' {
        $Env:Path = Join-Path $TestDrive 'empty-path'
        { . (Join-Path $script:Tools 'btop.ps1') } | Should -Not -Throw
        Get-Command btop -CommandType Function -ErrorAction Ignore | Should -BeNullOrEmpty
    }
}

Describe 'btop setup: catppuccin themes' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Get-DFToolSetupStatePath) -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
        $script:SavedPath = $Env:Path
        $script:Dir = New-FakeBtop 'plain'; $Env:Path = "$script:Dir;$Env:Path"
    }
    AfterEach { $Env:Path = $script:SavedPath; Remove-DFTestGlobal -Function btop; Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'copies the four themes into btop''s themes folder and tells you which to choose' {
        Start-DFSession -Config @{ Tools = @('btop'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        @(Get-ChildItem (Join-Path $script:Dir 'themes') -Filter 'catppuccin_*.theme').Count | Should -Be 4
        "$((Get-DFToolSetupState).btop.notes)" | Should -Match 'color_theme = "catppuccin_latte"'
        Get-Content (Join-Path $script:Dir 'btop.conf') -Raw | Should -Match 'color_theme = "Default"' -Because 'btop.conf is yours'
    }
    It 'records nothing and promises nothing when the themes can''t be copied, so the next load retries' {
        $themes = Join-Path $script:Dir 'themes'
        Remove-Item $themes -Recurse -Force
        Set-Content $themes 'not a folder'
        # A user's shell, where a failed copy is a non-terminating error (the gate runs with Stop).
        $ErrorActionPreference = 'Continue'
        Start-DFSession -Config @{ Tools = @('btop') } -ToolsPath $script:Tools 2>$null 3>$null
        (Get-DFToolSetupState).PSObject.Properties['btop'] | Should -BeNullOrEmpty
        "$(Get-DFPendingSetupNote -Name btop)" | Should -Not -Match 'themes are in'
    }
    It 'joins process-viewer and orders after the elevator' {
        $record = (Import-DFToolDb -ToolsPath $script:Tools -Name btop).btop
        $record.roles.PSObject.Properties.Name | Should -Contain 'process-viewer'
        $record.after | Should -Contain 'role:elevator'
    }
}
