BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'ConvertTo-DFColorOption' {
    It 'joins valid colors and skips an entry that could inject an option' {
        $file = Join-Path $TestDrive 't.json'
        '{ "colors": { "bg": "#1e1e2e", "matched": "red:bold", "bad": "x --bind=execute(calc)" } }' | Set-Content $file
        ConvertTo-DFColorOption -Path $file -Tool skim 3>$null | Should -Be '--color=bg:#1e1e2e,matched:red:bold'
    }
}

Describe 'skim tool' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        $script:Saved = @{ O = $Env:SKIM_DEFAULT_OPTIONS; C = $Env:SKIM_DEFAULT_COMMAND }
        Remove-Item Env:SKIM_DEFAULT_OPTIONS, Env:SKIM_DEFAULT_COMMAND -ErrorAction Ignore
        Mock Test-DFExecutableOnPath { $true }
        Mock Get-DFCachedCommandOutput { '' }
    }
    AfterEach {
        $Env:SKIM_DEFAULT_OPTIONS = $script:Saved.O; $Env:SKIM_DEFAULT_COMMAND = $script:Saved.C
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplySkimTheme'
        Restore-DFTestXdg
    }
    It 'gets fzf''s layout defaults and the catppuccin-mocha colors' {
        Register-DFTool -Name skim -ToolsPath $script:Tools
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match '--layout=reverse'
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match 'current_bg:#313244'
        $Env:SKIM_DEFAULT_COMMAND | Should -Match '^fd '
    }
    It 'follows Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name skim -ToolsPath $script:Tools
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match 'bg:#eff1f5'
    }
    It 'joins the picker role below fzf, setting Picker to sk' {
        $db = Import-DFToolDb -ToolsPath $script:Tools -Name skim, fzf
        $db['skim'].roles.picker.env.Picker | Should -Be 'sk'
        $db['skim'].roles.picker.priority | Should -BeLessThan $db['fzf'].roles.picker.priority
    }
}

Describe 'skim key hooks' {
    BeforeEach {
        $script:SavedOpts = $Env:SKIM_DEFAULT_OPTIONS
        Mock Register-DFFuzzyKeyHandler { }
        Mock Get-DFCachedCommandOutput { '' }
        Mock Get-DFToolTheme { [pscustomobject]@{ Native = 'catppuccin-mocha'; Explicit = $false } }
        $DFCurrentTool = [pscustomobject]@{ name = 'skim' }
        . (Join-Path $script:Tools 'skim.ps1')
    }
    AfterEach { $Env:SKIM_DEFAULT_OPTIONS = $script:SavedOpts; Remove-DFTestGlobal -Function 'Invoke-DFApplySkimTheme' }
    It 'binds History and Path with sk' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'skim' }) -Role 'history-search'
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'skim' }) -Role 'path-insert'
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'sk' -and $Key -eq 'History' }
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'sk' -and $Key -eq 'Path' }
        Initialize-DFRoleDirectoryJump -Tool ([pscustomobject]@{ name = 'skim' }) -Role 'directory-jump'
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'sk' -and $Key -eq 'Directory' -and $Accent -eq '#cba6f7' }
    }
}
