BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# The user and system PATH primitives behind desktop Path entries
# (docs/superpowers/specs/2026-11-03-desktop-path-design.md).
Describe 'DFDesktopPath' {
    BeforeEach {
        Set-DFTestXdg
        $script:real = Join-Path $TestDrive 'real'
        $script:link = Join-Path $TestDrive 'link'
        New-Item -ItemType Directory -Path $script:real -Force | Out-Null
    }
    AfterEach {
        # Delete the junction itself first: Pester's TestDrive cleanup trips on a link to a non-empty folder.
        if (Test-Path -LiteralPath $script:link) { [IO.Directory]::Delete($script:link) }
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'reads and writes the user Path keeping ExpandString and %VARS%' -Skip:(-not $IsWindows) {
        $key = Get-DFDesktopEnvKey
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name Path -Value '%USERPROFILE%\a;C:\b' -PropertyType ExpandString | Out-Null
        Set-DFUserPathValue -Value (Add-DFDesktopPathSegment -Value (Get-DFUserPathValue) -Segment 'C:\c')
        Get-DFUserPathValue | Should -Be '%USERPROFILE%\a;C:\b;C:\c'
        (Get-Item $key).GetValueKind('Path') | Should -Be 'ExpandString'
    }
    It 'adds to a missing or empty Path' -Skip:(-not $IsWindows) {
        Get-DFUserPathValue | Should -Be ''
        Set-DFUserPathValue -Value (Add-DFDesktopPathSegment -Value (Get-DFUserPathValue) -Segment 'C:\c')
        Get-DFUserPathValue | Should -Be 'C:\c'
        (Get-Item (Get-DFDesktopEnvKey)).GetValueKind('Path') | Should -Be 'ExpandString'
        Add-DFDesktopPathSegment -Value '' -Segment 'C:\c' | Should -Be 'C:\c'
    }
    It 'keeps empty segments and never doubles a separator' {
        Add-DFDesktopPathSegment -Value 'a;;b;' -Segment 'c' | Should -Be 'a;;b;c'
        Add-DFDesktopPathSegment -Value 'a;;b' -Segment 'c' -BeforeIndex 2 | Should -Be 'a;;c;b'
        Remove-DFDesktopPathSegment -Value 'a;;c;b' -Index 2 | Should -Be 'a;;b'
    }
    It 'matches the folder written differently or through a junction' -Skip:(-not $IsWindows) {
        New-Item -ItemType Junction -Path $script:link -Target $script:real | Out-Null
        Find-DFDesktopPathSegment -Value "X;$($script:real.ToUpper())\;Y" -Folder $script:real | Should -Be 1
        Find-DFDesktopPathSegment -Value "$($script:link)" -Folder $script:real | Should -Be 0
        $key = Get-DFDesktopEnvKey
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name DFTESTHOME -Value "$TestDrive" -PropertyType String | Out-Null
        Find-DFDesktopPathSegment -Value 'X;%DFTESTHOME%\real' -Folder $script:real | Should -Be 1
    }
    It 'skips relative, missing and empty segments without warnings' -Skip:(-not $IsWindows) {
        $value = '.;;C:\nope-df-task3;relative\x'
        Find-DFDesktopPathSegment -Value $value -Folder $script:real -WarningVariable w | Should -Be -1
        $w | Should -BeNullOrEmpty
        Mock Get-DFSystemPathValue { $value }
        Set-DFUserPathValue -Value $value
        @(Find-DFDesktopPathOtherCopy -Command 'node' -Folder $script:real -WarningVariable w2).Count | Should -Be 0
        $w2 | Should -BeNullOrEmpty
    }
    It 'finds another copy, system first, honoring PATHEXT' -Skip:(-not $IsWindows) {
        $sys = Join-Path $TestDrive 'sys'; $usr = Join-Path $TestDrive 'usr'; $ours = $script:real
        New-Item -ItemType Directory -Path $sys, $usr -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $usr 'node.cmd') | Out-Null
        Mock Get-DFSystemPathValue { "$sys" }
        Set-DFUserPathValue -Value "$usr;$ours"
        New-Item -ItemType File -Path (Join-Path $sys 'node.exe') | Out-Null
        $hit = @(Find-DFDesktopPathOtherCopy -Command 'node' -Folder $ours)
        $hit.Count | Should -Be 1
        $hit[0].Scope | Should -Be 'System'
        $hit[0].Path | Should -Be $sys
        $hit[0].Command | Should -Be 'node'
        Remove-Item (Join-Path $sys 'node.exe')
        $hit = @(Find-DFDesktopPathOtherCopy -Command 'node' -Folder $ours)
        $hit.Count | Should -Be 1
        $hit[0].Scope | Should -Be 'User'
        $hit[0].Index | Should -Be 0
        Set-DFUserPathValue -Value "$ours;$usr"
        @(Find-DFDesktopPathOtherCopy -Command 'node' -Folder $ours -StopAtFolder).Count | Should -Be 0
    }
    It 'doesn''t count DotForge''s own folder, even through a junction' -Skip:(-not $IsWindows) {
        $ours = $script:real
        New-Item -ItemType File -Path (Join-Path $ours 'node.exe') | Out-Null
        New-Item -ItemType Junction -Path $script:link -Target $ours | Out-Null
        Mock Get-DFSystemPathValue { '' }
        Set-DFUserPathValue -Value "$($script:link)"
        @(Find-DFDesktopPathOtherCopy -Command 'node' -Folder $ours).Count | Should -Be 0
    }
}
