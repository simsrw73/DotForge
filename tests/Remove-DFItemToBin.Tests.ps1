BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Never exercises the real Recycle Bin: only the rename step, which runs first.
Describe 'Remove-DFItemToBin' {
    It 'throws for a path that does not exist' {
        { Remove-DFItemToBin -Path (Join-Path $TestDrive 'nothing-here') } | Should -Throw
    }
    It 'throws and changes nothing when a file inside is in use' -Skip:(-not $IsWindows) {
        $dir = Join-Path $TestDrive 'busy'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $file = Join-Path $dir 'locked'
        Set-Content $file 'x'
        $handle = [IO.File]::Open($file, 'Open', 'Read', 'None')
        try {
            { Remove-DFItemToBin -Path $dir } | Should -Throw
            Test-Path $dir | Should -BeTrue
            Test-Path "$dir.dotforge-moved" | Should -BeFalse
        } finally { $handle.Dispose() }
    }
    It 'renames the item to <name>.dotforge-moved' -Skip:$IsWindows {
        $dir = Join-Path $TestDrive 'old'
        New-Item -ItemType Directory -Force $dir | Out-Null
        Remove-DFItemToBin -Path $dir
        Test-Path $dir | Should -BeFalse
        Test-Path "$dir.dotforge-moved" | Should -BeTrue
    }
}
