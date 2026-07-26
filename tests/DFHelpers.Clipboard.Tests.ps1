BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.Clipboard.ps1"
}

# These tests mock Set-Clipboard / Get-Clipboard rather than round-tripping through
# the real Windows clipboard. The clipboard is a single global OS resource, so a
# real round-trip is racy: under a full-suite run (or any concurrent process that
# touches the clipboard), Get-Clipboard can return a value another writer clobbered,
# producing intermittent failures. Mocking makes the tests assert the wrapper's own
# logic — pipeline collection and newline joining — deterministically. This mirrors
# the Invoke-DFFzf pattern (a private wrapper so tests never spawn a real process).

Describe 'Copy-DFToClipboard' {
    BeforeEach {
        $script:Captured = $null
        Mock Set-Clipboard { $script:Captured = $Value }
    }

    It 'sets clipboard from a positional argument' {
        Copy-DFToClipboard 'direct text'
        $script:Captured | Should -Be 'direct text'
        Should -Invoke Set-Clipboard -Times 1 -Exactly
    }

    It 'sets clipboard from pipeline input' {
        'hello world' | Copy-DFToClipboard
        $script:Captured | Should -Be 'hello world'
    }

    It 'joins multiple pipeline items with newlines' {
        'line1', 'line2', 'line3' | Copy-DFToClipboard
        $script:Captured | Should -Be "line1`nline2`nline3"
    }

    It 'is aliased to yank' {
        (Get-Alias -Name yank -ErrorAction SilentlyContinue).Definition |
            Should -Be 'Copy-DFToClipboard'
    }
}

Describe 'Get-DFFromClipboard' {
    It 'returns clipboard contents' {
        Mock Get-Clipboard { 'test clipboard content' }
        Get-DFFromClipboard | Should -Be 'test clipboard content'
        Should -Invoke Get-Clipboard -Times 1 -Exactly
    }

    It 'is aliased to paste' {
        (Get-Alias -Name paste -ErrorAction SilentlyContinue).Definition |
            Should -Be 'Get-DFFromClipboard'
    }
}
