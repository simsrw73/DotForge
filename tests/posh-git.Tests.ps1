BeforeAll {
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/posh-git.ps1'
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
}

Describe 'posh-git pickers' {
    BeforeEach {
        . $script:CompanionPath
        $script:added = [System.Collections.Generic.List[string]]::new()
        Mock git {
            if ($args[0] -eq 'add') { $script:added.Add($args[1]) }
        }
    }
    AfterEach {
        'Select-GitBranch', 'Select-GitLog', 'Select-GitFile', 'Select-GitStash' |
            ForEach-Object { Remove-Item "function:global:$_" -ErrorAction Ignore }
        'fco', 'flog', 'fga', 'fstash' | ForEach-Object { Remove-Item "alias:global:$_" -ErrorAction Ignore }
    }

    It 'defines fco/flog/fga/fstash globally' {
        (Get-Alias fco).Definition    | Should -Be 'Select-GitBranch'
        (Get-Alias flog).Definition   | Should -Be 'Select-GitLog'
        (Get-Alias fga).Definition    | Should -Be 'Select-GitFile'
        (Get-Alias fstash).Definition | Should -Be 'Select-GitStash'
    }

    Context 'fga stages the path from each git status --short line' {
        # git status --short lines are 'XY PATH': two status columns, a space, the
        # path. An unstaged change has a blank X column, so the line starts with a
        # space; splitting on whitespace would take 'M path' as the path.
        It 'stages <Path> from <Line>' -ForEach @(
            @{ Line = ' M Public/foo.ps1';        Path = 'Public/foo.ps1' }
            @{ Line = 'M  staged.ps1';            Path = 'staged.ps1' }
            @{ Line = '?? new file.txt';          Path = 'new file.txt' }
            @{ Line = 'R  old.ps1 -> renamed.ps1'; Path = 'renamed.ps1' }
        ) {
            Mock Invoke-DFFzf { $Line }
            Select-GitFile | Out-Null
            $script:added | Should -Be @($Path)
        }
    }
}
