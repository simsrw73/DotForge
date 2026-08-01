BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Navigation.ps1"
}

Describe 'Set-DFLocationUp' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'moves up one level by default' {
        $deep = Join-Path $TestDrive 'a'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Set-Location $deep
        up
        (Get-Location).Path | Should -Be $TestDrive
    }

    It 'moves up N levels' {
        $deep = Join-Path $TestDrive 'a' 'b' 'c'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Set-Location $deep
        up 3
        (Get-Location).Path | Should -Be $TestDrive
    }
}

Describe 'New-DFDirectoryAndSet' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'creates the directory and sets location to it' {
        $newDir = Join-Path $TestDrive 'newdir'
        mkcd $newDir
        Test-Path $newDir -PathType Container | Should -BeTrue
        (Get-Location).Path | Should -Be $newDir
    }
}

Describe 'Select-DFLocation' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'changes to the selected directory' {
        $target = Join-Path $TestDrive 'target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Mock Invoke-DFFzf { $target }
        fcd
        (Get-Location).Path | Should -Be $target
    }

    It 'does nothing when user cancels' {
        $before = (Get-Location).Path
        Mock Invoke-DFFzf { $null }
        fcd
        (Get-Location).Path | Should -Be $before
    }
}
