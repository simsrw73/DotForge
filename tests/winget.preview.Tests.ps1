BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/winget.preview.ps1'
    # Real `winget show --id Git.Git` output, captured during design.
    $script:GitFixture = @(
        'Found Git [Git.Git]'
        'Version: 2.55.0.3'
        'Publisher: The Git Development Community'
        'Publisher Url: https://gitforwindows.org/'
        'Publisher Support Url: https://github.com/git-for-windows/git/issues'
        'Moniker: git'
        'Description:'
        '  Git is a free and open source distributed version control system designed to handle everything from small to very large projects with speed and efficiency.'
        '  Git for Windows focuses on offering a lightweight, native set of tools that bring the full feature set of the Git SCM to Windows while providing appropriate user interfaces for experienced Git users and novices alike.'
        'Homepage: https://gitforwindows.org/'
        'License: GPL-2.0'
        'License Url: https://github.com/git-for-windows/build-extra/blob/HEAD/LICENSE.txt'
        'Copyright: Copyright (C) 1989, 1991 Free Software Foundation, Inc.'
        'Release Notes:'
        '  Changes since Git for Windows v2.55.0(2) (July 2nd 2026)'
        'Release Notes Url: https://github.com/git-for-windows/git/releases/tag/v2.55.0.windows.3'
        'Documentation:'
        '  Wiki: https://github.com/git-for-windows/git/wiki'
        'Tags:'
        '  git'
        '  vcs'
        'Installer:'
        '  Installer Type: inno'
        '  Installer Url: https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'
        '  Installer SHA256: af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca'
        '  Release Date: 2026-07-14'
        '  Offline Distribution Supported: true'
    )
}

Describe 'winget.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/Publisher/License/Homepage summary above the full output' {
        $fixture = $script:GitFixture
        Mock -CommandName winget -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'Git.Git'

        $result[0] | Should -Be 'Name: Git'
        $result[1] | Should -Match "^Description: Git is a free and open source.*novices alike\.$"
        $result[2] | Should -Be 'Version: 2.55.0.3'
        $result[3] | Should -Be 'Last Updated: 2026-07-14'
        $result[4] | Should -Be 'Publisher: The Git Development Community'
        $result[5] | Should -Be 'License: GPL-2.0'
        $result[6] | Should -Be 'Homepage: https://gitforwindows.org/'
        $result[7] | Should -Be ''
        $result[8] | Should -Match '^-+$'
        ($result -join "`n") | Should -Match 'Installer Type: inno'
    }

    It 'omits Last Updated when no Release Date line is present' {
        $fixture = $script:GitFixture | Where-Object { $_ -notmatch 'Release Date' }
        Mock -CommandName winget -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'Git.Git'
        ($result -join "`n") | Should -Not -Match 'Last Updated'
    }

    It 'falls back to plain output when winget show returns nothing recognizable' {
        Mock -CommandName winget -MockWith { @('some unexpected output', 'that matches nothing') }
        $result = & $script:ScriptPath -Id 'Nonsense.Package'
        $result | Should -Be @('some unexpected output', 'that matches nothing')
    }

    It 'does not throw and produces sane output when winget show yields a single null/empty line' {
        # `@(& winget ...)` wraps a lone $null/'' pipeline value into a 1-element array —
        # the actual crash shape (Format-DFPreviewSummary's -Body binds as an empty string).
        Mock -CommandName winget -MockWith { $null }
        { $script:Result = & $script:ScriptPath -Id 'Empty.Package' } | Should -Not -Throw
        $script:Result | Should -Not -BeNullOrEmpty
    }

    It 'does not throw and produces sane output when winget show produces no output at all' {
        Mock -CommandName winget -MockWith { @() }
        { $script:Result = & $script:ScriptPath -Id 'Empty.Package' } | Should -Not -Throw
        $script:Result | Should -Not -BeNullOrEmpty
    }
}
