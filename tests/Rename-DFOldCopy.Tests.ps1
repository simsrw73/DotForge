BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# A moved tool's old copy is renamed next to where it was, never deleted.
Describe 'Rename-DFOldCopy' {
    BeforeEach {
        $script:Old = Join-Path $TestDrive "old-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:Old | Out-Null
        Set-Content (Join-Path $script:Old 'cfg') 'v'
    }
    It 'renames the item to <name>.dotforge-moved and returns the new path' {
        $aside = Rename-DFOldCopy -Path $script:Old
        $aside | Should -Be "$script:Old.dotforge-moved"
        Test-Path $script:Old | Should -BeFalse
        Get-Content (Join-Path $aside 'cfg') | Should -Be 'v'
    }
    It 'picks a free name when an earlier copy already has that one' {
        New-Item -ItemType Directory -Force "$script:Old.dotforge-moved" | Out-Null
        $aside = Rename-DFOldCopy -Path $script:Old
        $aside | Should -Be "$script:Old.dotforge-moved-2"
        Test-Path "$script:Old.dotforge-moved" | Should -BeTrue
    }
    It 'throws for a path that does not exist' {
        { Rename-DFOldCopy -Path (Join-Path $TestDrive 'nothing-here') } | Should -Throw
    }
    It 'throws and changes nothing when a file inside is in use' -Skip:(-not $IsWindows) {
        $handle = [IO.File]::Open((Join-Path $script:Old 'cfg'), 'Open', 'Read', 'None')
        try {
            { Rename-DFOldCopy -Path $script:Old } | Should -Throw
            Test-Path $script:Old | Should -BeTrue
            Test-Path "$script:Old.dotforge-moved" | Should -BeFalse
        } finally { $handle.Dispose() }
    }
}
