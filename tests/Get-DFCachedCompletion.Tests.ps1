BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
}

Describe 'Get-DFCachedCompletion' {
    BeforeEach {
        $script:SavedCache  = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
    }

    It 'calls Generate and writes cache file on first run' {
        $fakeExe = Join-Path $TestDrive 'tool1.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $called = $false
        Get-DFCachedCompletion -CacheKey 'tool1' -ExePath $fakeExe -Generate {
            $script:called = $true
            '# completion'
        }

        $script:called | Should -BeTrue
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions' 'tool1.ps1'
        Test-Path $cacheFile | Should -BeTrue
        Get-Content $cacheFile | Should -Be '# completion'
    }

    It 'skips Generate when cache file is newer than the exe' {
        $fakeExe = Join-Path $TestDrive 'tool2.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'tool2.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# cached' | Set-Content $cacheFile
        (Get-Item $cacheFile).LastWriteTime = (Get-Date).AddHours(1)

        $script:called = $false
        Get-DFCachedCompletion -CacheKey 'tool2' -ExePath $fakeExe -Generate { $script:called = $true }
        $script:called | Should -BeFalse
    }

    It 'regenerates when exe is newer than cache' {
        $fakeExe = Join-Path $TestDrive 'tool3.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'tool3.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# old' | Set-Content $cacheFile
        (Get-Item $fakeExe).LastWriteTime = (Get-Date).AddHours(1)

        $script:called = $false
        Get-DFCachedCompletion -CacheKey 'tool3' -ExePath $fakeExe -Generate {
            $script:called = $true
            '# new'
        }
        $script:called | Should -BeTrue
        Get-Content $cacheFile | Should -Be '# new'
    }

    It 'does not throw when ExePath does not exist (tool not installed)' {
        { Get-DFCachedCompletion -CacheKey 'missing' -ExePath 'C:\nonexistent.exe' `
            -Generate { '# x' } } | Should -Not -Throw
    }

    It 'creates the cache directory if it does not exist' {
        $fakeExe = Join-Path $TestDrive 'tool5.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        Test-Path $cacheDir | Should -BeFalse

        Get-DFCachedCompletion -CacheKey 'tool5' -ExePath $fakeExe -Generate { '# c' }
        Test-Path $cacheDir | Should -BeTrue
    }
}
