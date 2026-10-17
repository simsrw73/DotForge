BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function Set-PsFzfOption { param([Parameter(ValueFromRemainingArguments)]$Rest) }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'PSFzf binds only the keys it won' {
    BeforeEach {
        Mock Import-Module { } -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Set-PsFzfOption { }
        Mock Set-DFRoleKeyHandler { & $Bind }
        . (Join-Path $script:Tools 'PSFzf.ps1')
    }
    It 'binds no chord in its companion body' {
        Should -Invoke Set-PsFzfOption -Times 0 -ParameterFilter { $Rest -contains '-PSReadlineChordReverseHistory' -or $Rest -contains '-PSReadlineChordProvider' }
    }
    It 'binds Ctrl+r from the history-search hook' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'PSFzf' }) -Role 'history-search'
        Should -Invoke Set-DFRoleKeyHandler -Times 1 -ParameterFilter { $Role -eq 'history-search' -and $Chord -eq 'Ctrl+r' -and $Tool -eq 'PSFzf' }
        Should -Invoke Set-PsFzfOption -Times 1 -ParameterFilter { $Rest -contains '-PSReadlineChordReverseHistory' }
    }
    It 'binds Ctrl+t from the path-insert hook' {
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'PSFzf' }) -Role 'path-insert'
        Should -Invoke Set-PsFzfOption -Times 1 -ParameterFilter { $Rest -contains '-PSReadlineChordProvider' }
    }
}

Describe 'fzf binds through the shared handler' {
    BeforeEach {
        $script:SavedOpts = $Env:FZF_DEFAULT_OPTS
        Mock Register-DFFuzzyKeyHandler { }
        Mock Get-DFToolTheme { [pscustomobject]@{ Native = 'catppuccin-mocha'; Explicit = $false } }
        $DFCurrentTool = [pscustomobject]@{ name = 'fzf' }
        . (Join-Path $script:Tools 'fzf.ps1')
    }
    AfterEach { $Env:FZF_DEFAULT_OPTS = $script:SavedOpts; Remove-DFTestGlobal -Function 'Invoke-DFApplyFzfTheme' }
    It 'binds History and Path with fzf' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'fzf' }) -Role 'history-search'
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'fzf' }) -Role 'path-insert'
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'fzf' -and $Key -eq 'History' }
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'fzf' -and $Key -eq 'Path' }
    }
}

Describe 'key role winners' {
    It 'ranks PSFzf over fzf in both roles' {
        $db = Import-DFToolDb -ToolsPath $script:Tools -Name fzf, PSFzf
        $db['PSFzf'].roles.'history-search'.priority | Should -BeGreaterThan $db['fzf'].roles.'history-search'.priority
        $db['PSFzf'].roles.'path-insert'.priority | Should -BeGreaterThan $db['fzf'].roles.'path-insert'.priority
    }
}
