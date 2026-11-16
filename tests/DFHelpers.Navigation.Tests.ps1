BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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

Describe 'Get-DFLocationRoot and Set-DFLocationRoot' {
    BeforeEach {
        $script:SavedLocation = Get-Location
        $script:Repo = Join-Path $TestDrive 'repo'
        $script:Deep = Join-Path $script:Repo 'src' 'lib'
        New-Item -ItemType Directory -Path $script:Deep -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.git') -Force | Out-Null
        $script:Outside = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $script:Outside -Force | Out-Null
    }
    AfterEach {
        Set-Location $script:SavedLocation
        Remove-Item -LiteralPath $script:Repo, $script:Outside -Recurse -Force
    }

    It 'pwr returns the repository root as a PathInfo, like pwd' {
        Set-Location $script:Deep
        $root = pwr
        $root | Should -BeOfType System.Management.Automation.PathInfo
        $root.Path | Should -Be $script:Repo
    }

    It 'cdr moves from a nested folder to the repository root' {
        Set-Location $script:Deep
        cdr
        (Get-Location).Path | Should -Be $script:Repo
    }

    It 'stops at the nearest root: a worktree or submodule has a .git file' {
        $inner = Join-Path $script:Repo 'sub'
        New-Item -ItemType Directory -Path (Join-Path $inner 'docs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $inner '.git') -Value 'gitdir: ../.git/modules/sub'
        Set-Location (Join-Path $inner 'docs')
        (pwr).Path | Should -Be $inner
    }

    It 'finds a jj repository' {
        $jj = Join-Path $script:Outside 'jjrepo'
        New-Item -ItemType Directory -Path (Join-Path $jj '.jj'), (Join-Path $jj 'x') -Force | Out-Null
        Set-Location (Join-Path $jj 'x')
        (pwr).Path | Should -Be $jj
    }

    It 'cdr -WhatIf names the root and stays put' {
        Set-Location $script:Deep
        cdr -WhatIf
        (Get-Location).Path | Should -Be $script:Deep
    }

    It 'outside a repository both warn, return nothing and stay put' {
        Set-Location $script:Outside
        pwr -WarningVariable warned -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $warned | Should -Match 'not inside a repository'
        cdr -WarningAction SilentlyContinue
        (Get-Location).Path | Should -Be $script:Outside
    }

    It 'warns in a location that is not a file-system folder' {
        Set-Location Env:
        pwr -WarningVariable warned -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $warned | Should -Match 'not a file-system folder'
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
