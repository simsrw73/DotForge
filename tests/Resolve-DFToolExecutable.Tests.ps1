BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFToolExecutable.ps1"
}

Describe 'Resolve-DFToolExecutable' {
    BeforeEach {
        $script:Hits = @()
        Mock Get-Command { $script:Hits | ForEach-Object { [pscustomobject]@{ Source = $_ } } }
    }

    It 'returns the first resolved path that no exclude pattern matches' {
        $script:Hits = @('C:\Program Files\Git\usr\bin\less.exe', 'C:\Users\x\scoop\shims\less.exe')
        $tool = [pscustomobject]@{ executable = 'less.exe'; executableExclude = @('*\Git\usr\bin\*') }
        Resolve-DFToolExecutable -Tool $tool | Should -Be 'C:\Users\x\scoop\shims\less.exe'
    }

    It 'matches exclude patterns case-insensitively' {
        $script:Hits = @('C:\program files\git\USR\BIN\less.exe')
        $tool = [pscustomobject]@{ executable = 'less.exe'; executableExclude = @('*\Git\usr\bin\*') }
        Resolve-DFToolExecutable -Tool $tool | Should -BeNullOrEmpty
    }

    It 'returns the first hit when the tool excludes nothing' {
        $script:Hits = @('C:\a\less.exe', 'C:\b\less.exe')
        Resolve-DFToolExecutable -Tool ([pscustomobject]@{ executable = 'less.exe'; executableExclude = @() }) | Should -Be 'C:\a\less.exe'
    }
}

Describe 'ConvertTo-DFToolExePathToken' {
    It 'uses forward slashes' {
        Mock Resolve-DFToolExecutable { 'C:\Users\x\scoop\shims\less.exe' }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be 'C:/Users/x/scoop/shims/less.exe'
    }

    It 'quotes a path that contains a space' {
        Mock Resolve-DFToolExecutable { 'C:\Program Files\less\less.exe' }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be '"C:/Program Files/less/less.exe"'
    }

    It 'falls back to the bare name when nothing qualifies' {
        Mock Resolve-DFToolExecutable { $null }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be 'less'
    }
}
