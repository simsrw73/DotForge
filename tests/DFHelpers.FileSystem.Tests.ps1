BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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

    Context 'with the same command in two PATH folders' {
        BeforeAll {
            # Get-Command -CommandType Application lists every PATH match even
            # without -All, so which has to pick the first one itself.
            $script:savedPath = $Env:PATH
            $script:first  = Join-Path $TestDrive 'first'
            $script:second = Join-Path $TestDrive 'second'
            foreach ($d in $script:first, $script:second) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
                Set-Content -Path (Join-Path $d 'dfwhichprobe.cmd') -Value '@echo off'
            }
            $Env:PATH = $script:first + [IO.Path]::PathSeparator + $script:second +
                        [IO.Path]::PathSeparator + $Env:PATH
        }
        AfterAll { $Env:PATH = $script:savedPath }

        It 'returns only the first match, the one that runs' {
            @(which dfwhichprobe) | Should -Be @(Join-Path $script:first 'dfwhichprobe.cmd')
        }

        It 'returns every match in PATH order with -All' {
            @(which dfwhichprobe -All) | Should -Be @(
                (Join-Path $script:first 'dfwhichprobe.cmd'),
                (Join-Path $script:second 'dfwhichprobe.cmd'))
        }
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

    It 'opens a URL with Start-Process, not Invoke-Item' {
        # Invoke-Item treats 'https:' as a PowerShell drive and fails.
        Mock Invoke-Item { }
        Mock Start-Process { }
        open 'https://example.com'
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'https://example.com' }
        Should -Invoke Invoke-Item -Times 0
    }
}
