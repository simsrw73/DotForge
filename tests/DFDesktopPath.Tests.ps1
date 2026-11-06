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
    It 'prefers the segment written as the folder over an earlier one that only resolves to it' -Skip:(-not $IsWindows) {
        # fnm's aliases\default is a junction to an installation folder the user may also have on the Path.
        New-Item -ItemType Junction -Path $script:link -Target $script:real | Out-Null
        Find-DFDesktopPathSegment -Value "$($script:real);C:\x;$($script:link)" -Folder $script:link | Should -Be 2
        Find-DFDesktopPathSegment -Value "$($script:real);C:\x" -Folder $script:link | Should -Be 0
    }
    It 'a match as written needs no file-system call' -Skip:(-not $IsWindows) {
        Mock Resolve-DFDesktopPathFolder { throw 'no file-system call expected' }
        Find-DFDesktopPathSegment -Value '\\unreachable\share;C:\x;C:/Tools/Bin/' -Folder 'c:\tools\bin' | Should -Be 2
        Should -Invoke Resolve-DFDesktopPathFolder -Times 0 -Exactly
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

# Expected entries, the guard and the status note.
Describe 'DFDesktopPath expected entries and note' {
    BeforeEach {
        Set-DFTestXdg
        $script:ours = Join-Path $Env:XDG_DATA_HOME 'deskp'
        $script:deskpTool = ConvertTo-DFToolRecord ([pscustomobject]@{
            name = 'deskp'; executable = 'deskp.exe'
            xdg = [pscustomobject]@{ method = 'env'; vars = [pscustomobject]@{ DESKP_DIR = '${XDG_DATA_HOME}/deskp' }; native = [pscustomobject]@{ DESKP_DIR = @() } }
            desktopPath = @([pscustomobject]@{ path = '${XDG_DATA_HOME}/deskp/current'; commands = @('deskp') })
        })
        $script:deskpEntry = @(Get-DFDesktopPathExpected -Tool $script:deskpTool)[0]
        [Environment]::SetEnvironmentVariable('DESKP_DIR', $null, 'Process')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('DESKP_DIR', $null, 'Process')
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'the entry lives under its own variable' {
        $script:deskpEntry.Under | Should -Be 'DESKP_DIR'
        $script:deskpEntry.UnderValue | Should -Be (ConvertTo-DFPath "$Env:XDG_DATA_HOME\deskp")
        $script:deskpEntry.Path | Should -Be (ConvertTo-DFPath "$Env:XDG_DATA_HOME\deskp\current")
        $script:deskpEntry.Commands | Should -Be @('deskp')
        $other = ConvertTo-DFToolRecord ([pscustomobject]@{
            name = 'deskp'; executable = 'deskp.exe'
            xdg = [pscustomobject]@{ method = 'env'; vars = [pscustomobject]@{ DESKP_DIR = '${XDG_DATA_HOME}/deskp' }; native = [pscustomobject]@{ DESKP_DIR = @() } }
            desktopPath = @([pscustomobject]@{ path = '${XDG_DATA_HOME}/deskpx/bin' })
        })
        (@(Get-DFDesktopPathExpected -Tool $other)[0]).Under | Should -BeNullOrEmpty
    }
    It 'the guard trips on a different shell value' {
        $Env:DESKP_DIR = 'C:\theirs'
        $trip = Test-DFDesktopPathGuard -Entry $script:deskpEntry
        $trip.Name | Should -Be 'DESKP_DIR'
        $trip.Where | Should -Be 'in this shell'
        $trip.Current | Should -Be 'C:\theirs'
        $trip.Suggested | Should -Be 'C:\theirs\current'
    }
    It 'the guard trips on a different desktop value, and on a planned one' -Skip:(-not $IsWindows) {
        Set-DFDesktopEnvValue -Name DESKP_DIR -Value 'C:\theirs'
        $trip = Test-DFDesktopPathGuard -Entry $script:deskpEntry
        $trip.Where | Should -Be 'for desktop apps'
        $trip.Suggested | Should -Be 'C:\theirs\current'
        Test-DFDesktopPathGuard -Entry $script:deskpEntry -DesktopValue @{ DESKP_DIR = $script:deskpEntry.UnderValue } | Should -BeNullOrEmpty
    }
    It 'no guard when the values match or are unset' {
        Test-DFDesktopPathGuard -Entry $script:deskpEntry -DesktopValue @{} | Should -BeNullOrEmpty
        $Env:DESKP_DIR = $script:deskpEntry.UnderValue
        Test-DFDesktopPathGuard -Entry $script:deskpEntry -DesktopValue @{ DESKP_DIR = $script:deskpEntry.UnderValue } | Should -BeNullOrEmpty
    }
    It 'notes a folder missing from the user Path' -Skip:(-not $IsWindows) {
        Mock Get-DFSystemPathValue { '' }
        Get-DFDesktopPathNote -Tool $script:deskpTool | Should -Be "deskp's folder isn't on the desktop Path; Set-DFDesktopEnv deskp adds it"
    }
    It 'leaves the shadow check to Set-DFDesktopEnv (too slow for every load)' -Skip:(-not $IsWindows) {
        $sys = Join-Path $TestDrive 'sys'
        New-Item -ItemType Directory -Path $sys, $script:deskpEntry.Path -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $sys 'deskp.exe') | Out-Null
        Mock Get-DFSystemPathValue { "$sys" }
        Set-DFUserPathValue -Value $script:deskpEntry.Path
        Get-DFDesktopPathNote -Tool $script:deskpTool | Should -BeNullOrEmpty
        Should -Invoke Get-DFSystemPathValue -Times 0 -Exactly
    }
    It 'says nothing when present and first' -Skip:(-not $IsWindows) {
        New-Item -ItemType Directory -Path $script:deskpEntry.Path -Force | Out-Null
        Mock Get-DFSystemPathValue { '' }
        Set-DFUserPathValue -Value $script:deskpEntry.Path
        Get-DFDesktopPathNote -Tool $script:deskpTool | Should -BeNullOrEmpty
    }
    It 'says why the entry is skipped when the guard trips' -Skip:(-not $IsWindows) {
        $Env:DESKP_DIR = 'C:\theirs'
        Mock Get-DFSystemPathValue { '' }
        Get-DFDesktopPathNote -Tool $script:deskpTool |
            Should -Be "deskp's Path entry is skipped: DESKP_DIR is C:\theirs in this shell, so its folder isn't under $($script:deskpEntry.UnderValue)"
    }
    It 'no desktopPath reads no registry' {
        Mock Get-DFUserPathValue { }
        $plain = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'plain'; executable = 'plain.exe' })
        Get-DFDesktopPathNote -Tool $plain | Should -BeNullOrEmpty
        Get-DFDesktopEnvNote -Tool $plain | Should -BeNullOrEmpty
        Should -Invoke Get-DFUserPathValue -Times 0 -Exactly
    }
}
