BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
}

Describe 'Ensure-DFDir' {
    It 'creates a directory that does not exist' {
        $dir = Join-Path $TestDrive 'newdir'
        Ensure-DFDir $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'is idempotent — no error when directory already exists' {
        $dir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $dir | Out-Null
        { Ensure-DFDir $dir } | Should -Not -Throw
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'creates nested directories' {
        $dir = Join-Path $TestDrive 'a' 'b' 'c'
        Ensure-DFDir $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'silently skips empty string' {
        { Ensure-DFDir '' } | Should -Not -Throw
    }

    It 'silently skips null' {
        { Ensure-DFDir $null } | Should -Not -Throw
    }
}
