BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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

    It 'canonicalizes an absolute path with .. before creating it' {
        $base = Join-Path $TestDrive 'nd'
        New-DFDirectory (Join-Path $base 'extra\..\real')
        Test-Path (Join-Path $base 'real') -PathType Container | Should -BeTrue
        Test-Path (Join-Path $base 'extra') | Should -BeFalse
    }
    It 'still creates a relative directory without warning' {
        Push-Location $TestDrive
        try {
            $w = $null
            New-DFDirectory 'reldir' -WarningVariable w -WarningAction SilentlyContinue
            Test-Path (Join-Path $TestDrive 'reldir') -PathType Container | Should -BeTrue
            $w | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }

    It 'emits a warning containing the path and does not throw when a file of the same name already exists' {
        $filePath = Join-Path $TestDrive 'file-conflict'
        New-Item -ItemType File -Path $filePath | Out-Null
        $w = $null
        New-DFDirectory $filePath -WarningVariable w
        $w.Count | Should -Be 1
        $w[0].Message | Should -BeLike "*$filePath*"
    }

    It 'emits a warning and does not throw when a file exists under ErrorActionPreference Stop' {
        $filePath = Join-Path $TestDrive 'file-conflict-stop'
        New-Item -ItemType File -Path $filePath | Out-Null
        $w = $null
        $ErrorActionPreference = 'Stop'
        New-DFDirectory $filePath -WarningVariable w
        $w.Count | Should -Be 1
        $w[0].Message | Should -BeLike "*$filePath*"
    }

    It 'produces no warning when directory already exists' {
        $dir = Join-Path $TestDrive 'existing-nowarn'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $w = $null
        New-DFDirectory $dir -WarningVariable w
        $w | Should -BeNullOrEmpty
    }
}
