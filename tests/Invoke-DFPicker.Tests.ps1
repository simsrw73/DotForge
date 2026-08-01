BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
}

Describe 'Invoke-DFPicker' {
    It 'outputs the selected item when no Action is given' {
        Mock Invoke-DFFzf { 'selected-item' }
        $result = Invoke-DFPicker -List { 'item1'; 'item2' } -Header 'Test'
        $result | Should -Be 'selected-item'
    }

    It 'calls Action with the selected item' {
        Mock Invoke-DFFzf { 'selected-item' }
        $script:received = $null
        Invoke-DFPicker -List { 'item1' } -Action { param($v) $script:received = $v }
        $script:received | Should -Be 'selected-item'
    }

    It 'applies Parse before Action — $_ is the raw line' {
        Mock Invoke-DFFzf { 'abc  def  ghi' }
        $script:parsed = $null
        Invoke-DFPicker -List { 'abc  def  ghi' } `
            -Parse { ($_ -split '\s+')[0] } `
            -Action { param($v) $script:parsed = $v }
        $script:parsed | Should -Be 'abc'
    }

    It 'returns nothing when fzf produces no selection (user cancelled)' {
        Mock Invoke-DFFzf { $null }
        $result = Invoke-DFPicker -List { 'item' }
        $result | Should -BeNullOrEmpty
    }

    It 'passes --preview-window to fzf' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -PreviewWindow 'right:60%'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--preview-window' -and $FzfArgs -contains 'right:60%'
        }
    }

    It 'passes --ansi to fzf when -Ansi is specified' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -Ansi
        Should -Invoke Invoke-DFFzf -ParameterFilter { $FzfArgs -contains '--ansi' }
    }

    It 'passes --header to fzf when -Header is specified' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -Header 'Pick one'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--header' -and $FzfArgs -contains 'Pick one'
        }
    }

    It 'handles multi-select — Action called once per selected item' {
        Mock Invoke-DFFzf { 'item1', 'item2' }
        $calls = [System.Collections.Generic.List[string]]::new()
        Invoke-DFPicker -List { 'item1'; 'item2' } -Multi `
            -Action { param($v) $calls.Add($v) }
        $calls.Count | Should -Be 2
        $calls | Should -Contain 'item1'
        $calls | Should -Contain 'item2'
    }

    It 'passes --multi to fzf when -Multi is specified' {
        Mock Invoke-DFFzf { }
        Invoke-DFPicker -List { 'x' } -Multi
        Should -Invoke Invoke-DFFzf -ParameterFilter { $FzfArgs -contains '--multi' }
    }

    It 'passes --expect with comma-joined keys when -Expect is specified' {
        Mock Invoke-DFFzf { }
        Invoke-DFPicker -List { 'x' } -Expect 'alt-r', 'alt-i'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--expect' -and $FzfArgs -contains 'alt-r,alt-i'
        }
    }

    It 'passes one --bind per spec when -Bind is specified' {
        Mock Invoke-DFFzf { }
        Invoke-DFPicker -List { 'x' } -Bind 'alt-i:execute(echo {})', 'alt-x:execute(echo x)'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            ($FzfArgs | Where-Object { $_ -eq '--bind' }).Count -eq 2 -and
            $FzfArgs -contains 'alt-i:execute(echo {})' -and
            $FzfArgs -contains 'alt-x:execute(echo x)'
        }
    }

    It 'appends -FzfArgs verbatim' {
        Mock Invoke-DFFzf { }
        Invoke-DFPicker -List { 'x' } -FzfArgs '--reverse', '--cycle'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--reverse' -and $FzfArgs -contains '--cycle'
        }
    }

    Context 'with -Expect (multi-key mode)' {
        It 'returns a {Key, Selected} object; Key is the first fzf line, Selected is parsed' {
            Mock Invoke-DFFzf { 'alt-r'; 'abc  def' }
            $r = Invoke-DFPicker -List { 'abc  def' } -Expect 'alt-r' `
                -Parse { ($_ -split '\s+')[1] }
            $r.Key      | Should -Be 'alt-r'
            $r.Selected | Should -Be 'def'
        }

        It 'treats an empty first line as the Enter key (not a cancel)' {
            Mock Invoke-DFFzf { ''; 'chosen-item' }
            $r = Invoke-DFPicker -List { 'chosen-item' } -Expect 'alt-r'
            $r.Key      | Should -Be ''
            $r.Selected | Should -Be 'chosen-item'
        }

        It 'collects every selection in Selected under -Multi' {
            Mock Invoke-DFFzf { 'alt-a'; 'one'; 'two' }
            $r = Invoke-DFPicker -List { 'one'; 'two' } -Expect 'alt-a' -Multi
            $r.Key      | Should -Be 'alt-a'
            @($r.Selected).Count | Should -Be 2
            $r.Selected | Should -Contain 'one'
            $r.Selected | Should -Contain 'two'
        }

        It 'returns nothing when the user cancels (fzf produces no output)' {
            Mock Invoke-DFFzf { $null }
            $r = Invoke-DFPicker -List { 'x' } -Expect 'alt-r'
            $r | Should -BeNullOrEmpty
        }

        It 'does not invoke -Action in expect mode' {
            Mock Invoke-DFFzf { 'alt-r'; 'item' }
            $script:actionRan = $false
            Invoke-DFPicker -List { 'item' } -Expect 'alt-r' `
                -Action { param($v) $script:actionRan = $true } | Out-Null
            $script:actionRan | Should -BeFalse
        }
    }
}
