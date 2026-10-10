BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'Invoke-DFBoundedProcess' {
    It 'returns the output lines and exit code' {
        $r = Invoke-DFBoundedProcess -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', 'Write-Output one; Write-Output two; exit 3' -TimeoutSeconds 30
        $r.Lines | Should -Be @('one', 'two')
        $r.ExitCode | Should -Be 3
    }

    It 'passes each argument as one argument, spaces included' {
        $r = Invoke-DFBoundedProcess -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', 'Write-Output "a b"' -TimeoutSeconds 30
        $r.Lines | Should -Be @('a b')
    }

    It 'leaves stderr out of the lines' {
        $r = Invoke-DFBoundedProcess -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', '[Console]::Error.WriteLine("noise"); Write-Output kept' -TimeoutSeconds 30
        $r.Lines | Should -Be @('kept')
    }

    It 'kills a process that runs past the timeout and throws, naming the command' {
        $marker = "df-bounded-$(Get-Random)"
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        { Invoke-DFBoundedProcess -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', "Start-Sleep 60 # $marker" -TimeoutSeconds 1 } |
            Should -Throw "*did not finish within 1 s*"
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
        Start-Sleep -Milliseconds 500
        @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" | Where-Object CommandLine -like "*$marker*") | Should -HaveCount 0
    }
}

Describe 'winget CLI seams are bounded' {
    BeforeEach {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\fake\winget.exe' } }
        Mock Invoke-DFBoundedProcess { [pscustomobject]@{ Lines = @('line 1', 'line 2'); ExitCode = 0 } }
    }

    It 'runs winget search through the bounded runner' {
        Invoke-DFCatalogWingetCli -Query 'ripgrep' | Should -Be @('line 1', 'line 2')
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\fake\winget.exe' -and $TimeoutSeconds -gt 0 -and
            ($ArgumentList -join ' ') -eq 'search --query ripgrep --source winget --disable-interactivity'
        }
    }

    It 'runs winget show through the bounded runner' {
        Invoke-DFCatalogWingetShowCli -PackageId 'BurntSushi.ripgrep.MSVC' | Should -Be @('line 1', 'line 2')
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\fake\winget.exe' -and $TimeoutSeconds -gt 0 -and
            ($ArgumentList -join ' ') -eq 'show --id BurntSushi.ripgrep.MSVC --exact --source winget --disable-interactivity'
        }
    }
}
