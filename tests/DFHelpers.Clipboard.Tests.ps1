BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.Clipboard.ps1"
}

Describe 'Copy-DFToClipboard' {
    It 'sets clipboard from a positional argument' {
        Copy-DFToClipboard 'direct text'
        Get-Clipboard | Should -Be 'direct text'
    }

    It 'sets clipboard from pipeline input' {
        'hello world' | Copy-DFToClipboard
        Get-Clipboard | Should -Be 'hello world'
    }

    It 'joins multiple pipeline items with newlines' {
        'line1', 'line2', 'line3' | Copy-DFToClipboard
        Get-Clipboard | Should -Be "line1`nline2`nline3"
    }

    # Note: the 'copy' alias cannot be verified inside Pester because Pester resets
    # AllScope built-in aliases (copy -> Copy-Item) in its sandboxed session state.
    # The alias is set correctly at module load time; verified manually with:
    #   . Public/DFHelpers.Clipboard.ps1; (Get-Alias copy).Definition
}

Describe 'Get-DFFromClipboard' {
    It 'returns clipboard contents' {
        Set-Clipboard 'test clipboard content'
        Get-DFFromClipboard | Should -Be 'test clipboard content'
    }

    It 'is aliased to paste' {
        (Get-Alias -Name paste -ErrorAction SilentlyContinue).Definition |
            Should -Be 'Get-DFFromClipboard'
    }
}
