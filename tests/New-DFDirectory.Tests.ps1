BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
}

Describe 'New-DFDirectory' {
    It 'creates a directory that does not exist' {
        $dir = Join-Path $TestDrive 'newdir'
        New-DFDirectory $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'is idempotent — no error when directory already exists' {
        $dir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $dir | Out-Null
        { New-DFDirectory $dir } | Should -Not -Throw
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'creates nested directories' {
        $dir = Join-Path $TestDrive 'a' 'b' 'c'
        New-DFDirectory $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'silently skips empty string' {
        { New-DFDirectory '' } | Should -Not -Throw
    }

    It 'silently skips null' {
        { New-DFDirectory $null } | Should -Not -Throw
    }
}
