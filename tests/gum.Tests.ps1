BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'gum tool' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        $script:Saved = @{}
        foreach ($item in Get-ChildItem Env:GUM_* -ErrorAction Ignore) { $script:Saved[$item.Name] = $item.Value; Remove-Item "Env:$($item.Name)" }
        Mock Test-DFExecutableOnPath { $true }
    }
    AfterEach {
        Get-ChildItem Env:GUM_* -ErrorAction Ignore | ForEach-Object { Remove-Item "Env:$($_.Name)" }
        foreach ($k in $script:Saved.Keys) { Set-Item "Env:$k" $script:Saved[$k] }
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplyGumTheme'
        Restore-DFTestXdg
    }
    It 'sets the catppuccin-mocha colors' {
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_CHOOSE_CURSOR_FOREGROUND | Should -Be '#f5c2e7'
        $Env:GUM_FILTER_MATCH_FOREGROUND | Should -Be '#f38ba8'
    }
    It 'follows Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_CONFIRM_SELECTED_BACKGROUND | Should -Be '#8839ef'
    }
    It 'keeps a color you set yourself' {
        $Env:GUM_FILTER_MATCH_FOREGROUND = '#000000'
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_FILTER_MATCH_FOREGROUND | Should -Be '#000000'
    }
    It 'skips an invalid entry in a theme file you wrote' {
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $file = Join-Path $TestDrive 'mine.json'
        '{ "env": { "GUM_SPIN_TITLE_FOREGROUND": "#ffffff", "PATH": "#000000", "GUM_SPIN_SPINNER_FOREGROUND": "red; calc" } }' | Set-Content $file
        Invoke-DFApplyGumTheme -Name $file 3>$null
        $Env:GUM_SPIN_TITLE_FOREGROUND | Should -Be '#ffffff'
        $Env:GUM_SPIN_SPINNER_FOREGROUND | Should -Not -Be 'red; calc'
    }
}

Describe 'fuzzy group' {
    It 'lists the five fuzzy finders' {
        $groups = Get-Content (Join-Path $PSScriptRoot '..' 'data' 'groups.json') -Raw | ConvertFrom-Json
        $groups.fuzzy.tools | Should -Be @('fzf', 'skim', 'television', 'peco', 'gum')
    }
}
