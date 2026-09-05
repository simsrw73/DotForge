BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFPackageManagerPicker.ps1"
}

Describe 'Invoke-DFPackageManagerPicker' {
    It 'feeds fzf the -ListItems output and adds the ping debounce prefix to the preview' {
        Mock Invoke-DFFzf {
            $script:fedItems = $InputItems
            $script:fedArgs  = $FzfArgs
            ''
            @($InputItems)[0]
        }
        Invoke-DFPackageManagerPicker -ListItems { "a`tA"; "b`tB" } `
            -PreviewCommand 'scoop info {2}' -Header 'h' -ExpectKey 'alt-r' | Out-Null

        @($script:fedItems) | Should -Contain "a`tA"
        ($script:fedArgs -join ' ') | Should -Match ([regex]::Escape('ping -n 2 127.0.0.1 >nul & scoop info {2}'))
    }

    It 'always sets --delimiter tab, --with-nth 1, and --preview-window right:60%' {
        Mock Invoke-DFFzf { $script:fedArgs = $FzfArgs; ''; @($InputItems)[0] }
        Invoke-DFPackageManagerPicker -ListItems { 'x' } `
            -PreviewCommand 'p' -Header 'h' -ExpectKey 'alt-r' | Out-Null

        $joined = $script:fedArgs -join ' '
        $joined | Should -Match "--delimiter\s+`t"
        $joined | Should -Match '--with-nth\s+1'
        $joined | Should -Match '--preview-window\s+right:60%'
    }

    It 'parses the fzf line on tab and returns the second field via .Selected' {
        Mock Invoke-DFFzf { ''; "display text`tparsed-key" }
        $result = Invoke-DFPackageManagerPicker -ListItems { 'x' } `
            -PreviewCommand 'p' -Header 'h' -ExpectKey 'alt-r'
        $result.Selected | Should -Contain 'parsed-key'
    }

    It 'includes the --bind spec when -Bind is given' {
        Mock Invoke-DFFzf { $script:fedArgs = $FzfArgs; ''; @($InputItems)[0] }
        Invoke-DFPackageManagerPicker -ListItems { 'x' } -PreviewCommand 'p' -Header 'h' `
            -ExpectKey 'alt-r' -Bind 'alt-i:execute(scoop install {2})' | Out-Null
        ($script:fedArgs -join ' ') | Should -Match ([regex]::Escape('alt-i:execute(scoop install {2})'))
    }

    It 'omits --bind entirely when -Bind is not given' {
        Mock Invoke-DFFzf { $script:fedArgs = $FzfArgs; ''; @($InputItems)[0] }
        Invoke-DFPackageManagerPicker -ListItems { 'x' } -PreviewCommand 'p' -Header 'h' -ExpectKey 'alt-a' | Out-Null
        ($script:fedArgs -join ' ') | Should -Not -Match '--bind'
    }

    It 'passes --multi through when -Multi is requested' {
        Mock Invoke-DFFzf { $script:fedArgs = $FzfArgs; ''; @($InputItems) }
        Invoke-DFPackageManagerPicker -ListItems { 'x'; 'y' } -PreviewCommand 'p' -Header 'h' `
            -ExpectKey 'alt-a' -Multi | Out-Null
        ($script:fedArgs -join ' ') | Should -Match '--multi'
    }

    It 'does not pass --multi when -Multi is not requested' {
        Mock Invoke-DFFzf { $script:fedArgs = $FzfArgs; ''; @($InputItems)[0] }
        Invoke-DFPackageManagerPicker -ListItems { 'x' } -PreviewCommand 'p' -Header 'h' -ExpectKey 'alt-r' | Out-Null
        ($script:fedArgs -join ' ') | Should -Not -Match '--multi'
    }
}
