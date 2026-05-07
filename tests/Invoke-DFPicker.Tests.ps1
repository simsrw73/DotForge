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
}
