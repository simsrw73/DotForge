BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../Tools/choco.preview.ps1'
    # Pester's Mock needs a command to already exist before it can attach an
    # interception to it — Invoke-DFChocoInfo's real definition lives inside
    # Tools/choco.preview.ps1 itself and is only defined when that standalone
    # script actually runs. This throwaway stand-in exists purely so
    # `Mock -CommandName Invoke-DFChocoInfo` below has something to grab onto;
    # once Mock has intercepted the name, its replacement wins even inside the
    # separately-`&`-invoked script, which defines its own "real"
    # Invoke-DFChocoInfo locally when it runs. Same pattern as
    # tests/scoop.preview.Tests.ps1's Invoke-DFScoopInfo stand-in.
    function Invoke-DFChocoInfo { param([string]$Id) }
    # Real `choco info nodejs` output, captured during design (the leading
    # "Chocolatey vX.Y.Z" banner line is real — choco always prints it first).
    $script:NodeFixture = @(
        'Chocolatey v2.7.4'
        'nodejs 26.8.1 [Approved]'
        ' Title: Node JS | Published: 2026-08-27'
        ' Package approved as a trusted package on Aug 27 2026 18:46:34.'
        ' Package testing status: Passing on Aug 27 2026 17:25:48.'
        ' Number of Downloads: 7013042 | Downloads for this version: 100'
        ' Package url https://community.chocolatey.org/packages/nodejs/26.8.1'
        ' Chocolatey Package Source: https://github.com/chocolatey-community/chocolatey-packages/tree/master/automatic/nodejs'
        ' Tags: nodejs node javascript npm admin foss cross-platform'
        ' Software Site: http://nodejs.org/'
        ' Software License: https://github.com/nodejs/node/blob/master/LICENSE'
        ' Software Source: https://github.com/nodejs/node'
        ' Documentation: https://nodejs.org/en/docs/'
        ' Issues: https://github.com/nodejs/node/issues'
        " Summary: Node JS - Evented I/O for v8 JavaScript."
        " Description: Node.js is a JavaScript runtime built on Chrome's V8 JavaScript engine."
        ' '
        ' This package runs the official Node JS installer.'
        ''
        '1 packages found.'
    )
}

Describe 'choco.preview.ps1' {
    It 'builds a Name/Description/Version/Last Updated/License/Homepage summary above the full output' {
        # Assign to a local variable before the Mock scriptblock: a $script:-scoped
        # variable referenced directly inside -MockWith does not resolve when the
        # mocked command is invoked from inside a separately-invoked script file
        # (confirmed during Task 3 — Pester 6.1.0 behavior). A local closure variable
        # works correctly.
        $fixture = $script:NodeFixture
        Mock -CommandName Invoke-DFChocoInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'

        $result[0] | Should -Be 'Name: nodejs'
        $result[1] | Should -Match "^Description: Node\.js is a JavaScript runtime built on Chrome's V8 JavaScript engine\.$"
        $result[2] | Should -Be 'Version: 26.8.1'
        $result[3] | Should -Be 'Last Updated: 2026-08-27'
        $result[4] | Should -Be 'License: https://github.com/nodejs/node/blob/master/LICENSE'
        $result[5] | Should -Be 'Homepage: http://nodejs.org/'
        $result[6] | Should -Be ''
        $result[7] | Should -Match '^-+$'
        ($result -join "`n") | Should -Not -Match 'Publisher:'
    }

    It 'skips the leading "Chocolatey vX.Y.Z" banner line and finds the real header' {
        $fixture = $script:NodeFixture
        Mock -CommandName Invoke-DFChocoInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'
        ($result -join "`n") | Should -Not -Match 'Name: Chocolatey'
    }

    It 'does not misparse an embedded URL as a field ("Package url https://...")' {
        $fixture = $script:NodeFixture
        Mock -CommandName Invoke-DFChocoInfo -MockWith { $fixture }
        $result = & $script:ScriptPath -Id 'nodejs'
        # Scoped to the summary block (indices 0-7: the six fields, the blank line,
        # and the separator) rather than the whole $result — the raw, unmodified
        # `choco info` body legitimately preserves the "Package url https://..."
        # line below the separator by design (this script's header comment: "that
        # content stays visible, unstyled, in the full output below the
        # separator"), so a whole-array check would always fail regardless of
        # whether the field parser actually misparsed it. Same scoping rationale as
        # Tools/scoop.preview.ps1's ANSI check in tests/scoop.preview.Tests.ps1.
        ($result[0..7] -join "`n") | Should -Not -Match 'Package url https'
    }

    It 'falls back to plain output when choco info returns nothing recognizable' {
        Mock -CommandName Invoke-DFChocoInfo -MockWith { @('some unexpected output') }
        $result = & $script:ScriptPath -Id 'nonsense'
        $result | Should -Be @('some unexpected output')
    }

    It 'does not throw and produces non-empty output when choco info returns $null' {
        Mock -CommandName Invoke-DFChocoInfo -MockWith { $null }
        { $script:NullResult = & $script:ScriptPath -Id 'nonsense' } | Should -Not -Throw
        $script:NullResult | Should -Not -BeNullOrEmpty
    }
}
