BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.FileSystem.ps1"
}

Describe 'New-DFFile' {
    It 'creates a new empty file when path does not exist' {
        $path = Join-Path $TestDrive 'newfile.txt'
        touch $path
        Test-Path $path | Should -BeTrue
        (Get-Item $path).Length | Should -Be 0
    }

    It 'updates LastWriteTime when file already exists' {
        $path = Join-Path $TestDrive 'existing.txt'
        New-Item -ItemType File -Path $path | Out-Null
        $oldTime = (Get-Item $path).LastWriteTime
        Start-Sleep -Milliseconds 100
        touch $path
        (Get-Item $path).LastWriteTime | Should -BeGreaterThan $oldTime
    }

    It 'accepts multiple paths' {
        $a = Join-Path $TestDrive 'a.txt'
        $b = Join-Path $TestDrive 'b.txt'
        touch $a $b
        Test-Path $a | Should -BeTrue
        Test-Path $b | Should -BeTrue
    }
}

Describe 'Get-DFWhich' {
    It 'returns the full path of a known executable' {
        $result = which pwsh
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match '(?i)\.exe$'
    }

    It 'returns nothing silently for an unknown command' {
        $result = which nonexistent-command-xyz-df
        $result | Should -BeNullOrEmpty
    }

    It '-All does not throw' {
        { which pwsh -All } | Should -Not -Throw
    }

    It '-All returns all matches when multiple exist' {
        $results = which pwsh -All
        $results | Should -Not -BeNullOrEmpty
    }
}

Describe 'Open-DFItem' {
    It 'calls Invoke-Item for a single path' {
        Mock Invoke-Item { }
        open 'somefile.txt'
        Should -Invoke Invoke-Item -Times 1 -ParameterFilter { $Path -eq 'somefile.txt' }
    }

    It 'calls Invoke-Item once per path for multiple paths' {
        Mock Invoke-Item { }
        open 'a.txt' 'b.txt'
        Should -Invoke Invoke-Item -Times 2
    }
}
