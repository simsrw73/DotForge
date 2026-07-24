BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
}

Describe 'Add-DFToPath' {
    BeforeEach { $script:SavedPath = $Env:Path }
    AfterEach  { $Env:Path = $script:SavedPath }

    It 'appends an absolute path not already in PATH' {
        $Env:Path = 'C:\Windows\system32'
        Add-DFToPath 'C:\tools\bin'
        $Env:Path -split [IO.Path]::PathSeparator | Should -Contain 'C:\tools\bin'
    }

    It 'does not add a path already present (case-insensitive)' {
        $Env:Path = 'C:\tools\bin'
        Add-DFToPath 'c:\tools\bin'
        @($Env:Path -split [IO.Path]::PathSeparator |
            Where-Object { $_ -ieq 'C:\tools\bin' }).Count | Should -Be 1
    }

    It 'prepends when -Prepend is specified' {
        $Env:Path = 'C:\Windows\system32'
        Add-DFToPath 'C:\tools\bin' -Prepend
        ($Env:Path -split [IO.Path]::PathSeparator)[0] | Should -Be 'C:\tools\bin'
    }

    It 'silently skips empty string' {
        $before = $Env:Path
        Add-DFToPath ''
        $Env:Path | Should -Be $before
    }

    It 'skips relative paths and emits a warning' {
        $before = $Env:Path
        Add-DFToPath 'relative\path' -WarningVariable warns 3>$null
        $Env:Path | Should -Be $before
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'normalizes .. segments before dedup comparison' {
        $Env:Path = 'C:\tools\bin'
        Add-DFToPath 'C:\tools\other\..\bin'
        @($Env:Path -split [IO.Path]::PathSeparator |
            Where-Object { $_ -ieq 'C:\tools\bin' }).Count | Should -Be 1
    }

    It 'handles malformed PATH entries without throwing' {
        $Env:Path = 'C:\good\path;:::bad:::;C:\other'
        { Add-DFToPath 'C:\new\path' } | Should -Not -Throw
        $Env:Path -split [IO.Path]::PathSeparator | Should -Contain 'C:\new\path'
    }

    It 'dedups a path that differs only by trailing separator / .. against its canonical form' {
        $saved = $Env:Path
        try {
            $Env:Path = 'C:\tools\bin'
            Add-DFToPath 'C:\tools\extra\..\bin\'
            ($Env:Path -split ';' | Where-Object { $_ -eq 'C:\tools\bin' }).Count | Should -Be 1
            $Env:Path | Should -Not -Match 'extra'
        } finally { $Env:Path = $saved }
    }
}
