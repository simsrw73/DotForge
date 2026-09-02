BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/scoop.preview.ps1'
    # Pester's Mock needs a command to already exist before it can attach an
    # interception to it — Invoke-DFScoopInfo's real definition lives inside
    # Tools/scoop.preview.ps1 itself and is only defined when that standalone
    # script actually runs (it isn't dot-sourced anywhere ahead of time). This
    # throwaway stand-in exists purely so `Mock -CommandName Invoke-DFScoopInfo`
    # below has something to grab onto; once Mock has intercepted the name, its
    # replacement wins even inside the separately-`&`-invoked script, which
    # defines its own "real" Invoke-DFScoopInfo locally when it runs.
    function Invoke-DFScoopInfo { param([string]$Name) }
    # Real `scoop info git` output, captured during design (ANSI color codes
    # included — 32;1 = bright green bold label, 0 = reset).
    $script:GitFixture = @(
        "`e[32;1mName        : `e[0mgit"
        "`e[32;1mDescription : `e[0mA free and open source distributed version control system."
        "`e[32;1mVersion     : `e[0m2.55.0.5"
        "`e[32;1mSource      : `e[0mmain"
        "`e[32;1mWebsite     : `e[0mhttps://gitforwindows.org"
        "`e[32;1mLicense     : `e[0mGPL-2.0-only"
        "`e[32;1mUpdated at  : `e[0m2026-08-25 02:18:48"
        "`e[32;1mUpdated by  : `e[0mA1gaE"
        "`e[32;1mBinaries    : `e[0mbin\sh.exe | bin\git.exe | git-bash.exe"
        "`e[32;1mShortcuts   : `e[0mGit\Git Bash | Git\Git CMD | Git\Git GUI"
    )
}

Describe 'scoop.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/License/Homepage summary above the full output, ANSI stripped' {
        # Assign to a local variable before the Mock scriptblock: a $script:-scoped
        # variable referenced directly inside -MockWith does not resolve when the
        # mocked command is invoked from inside a separately-invoked script file
        # (confirmed during Task 3 — Pester 6.1.0 behavior). A local closure variable
        # works correctly.
        $fixture = $script:GitFixture
        Mock -CommandName Invoke-DFScoopInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Name 'git'

        $result[0] | Should -Be 'Name: git'
        $result[1] | Should -Be 'Description: A free and open source distributed version control system.'
        $result[2] | Should -Be 'Version: 2.55.0.5'
        $result[3] | Should -Be 'Last Updated: 2026-08-25 02:18:48'
        $result[4] | Should -Be 'License: GPL-2.0-only'
        $result[5] | Should -Be 'Homepage: https://gitforwindows.org'
        $result[6] | Should -Be ''
        $result[7] | Should -Match '^-+$'
        # The fixture's own ANSI reset code (`e[0m) sits literally between the
        # label and value ("Updated by  : `e[0mA1gaE"), so a plain contiguous
        # 'Updated by  : A1gaE' substring can never appear in the RAW body
        # (Format-DFPreviewSummary is given $rawLines, colors intact, by
        # design). Match the actual raw bytes instead of the ANSI-stripped text.
        ($result -join "`n") | Should -Match 'Updated by\s*:\s*(\x1b\[0m)?A1gaE'
        # Only the summary block (indices 0-7: the six fields, the blank line,
        # and the separator) is required to be ANSI-free — the raw body below
        # it (index 8+) intentionally keeps scoop info's original color codes
        # per this script's documented design (see the brief's implementation
        # note: Format-DFPreviewSummary is given $rawLines, not ANSI-stripped
        # $lines, so the full output renders exactly as scoop info prints it).
        ($result[0..7] -join "`n") | Should -Not -Match '\x1b\['
    }

    It 'does not include a Publisher line (scoop has no equivalent field)' {
        $fixture = $script:GitFixture
        Mock -CommandName Invoke-DFScoopInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Name 'git'
        ($result -join "`n") | Should -Not -Match 'Publisher:'
    }

    It 'falls back to plain output when scoop info returns nothing recognizable' {
        Mock -CommandName Invoke-DFScoopInfo -MockWith { @('some unexpected output') }
        $result = & $script:ScriptPath -Name 'nonsense'
        $result | Should -Be @('some unexpected output')
    }

    It 'does not throw and produces sane output when scoop info yields a single null line' {
        # `@(Invoke-DFScoopInfo ...)` wraps a lone $null pipeline value into a
        # 1-element array — the actual crash shape (Format-DFPreviewSummary's
        # -Body binds as an empty string on a degenerate @($null)/@('') array).
        Mock -CommandName Invoke-DFScoopInfo -MockWith { $null }
        { $script:Result = & $script:ScriptPath -Name 'nonsense' } | Should -Not -Throw
        $script:Result | Should -Not -BeNullOrEmpty
    }
}
