BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    Import-Module PSReadLine -ErrorAction Ignore
}

Describe 'key-binding roles' {
    It 'defines history-search and path-insert with their hooks, and the fuzzy-finder category' {
        $db = Get-DFRoleDb
        $db['history-search'].hook | Should -Be 'Initialize-DFRoleHistorySearch'
        $db['path-insert'].hook | Should -Be 'Initialize-DFRolePathInsert'
        $db['history-search'].reserved.code | Should -Contain 'Set-DFRoleKeyHandler'
        $db['fuzzy-finder'].kind | Should -Be 'category'
    }
}

Describe 'Set-DFRoleKeyHandler' {
    BeforeEach {
        Reset-DFTestSession
        $script:DFBoundKeys.Clear()
        $script:DFSessionRoleWinners = @{ 'history-search' = [pscustomobject]@{ Winner = 'fzf'; Reason = 'priority' } }
        $script:Bound = 0
        $script:BindIt = { $script:Bound++ }
    }

    It 'binds a key that has only PSReadLine''s own handler' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'ReverseSearchHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 1
    }
    It 'keeps a binding the user made, with a status note' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'MyHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 0
        Get-DFToolNote -Tool fzf | Should -Match 'kept your own Ctrl\+r binding'
    }
    It 'replaces the user''s binding, with a warning, when Defaults names the tool' {
        $script:DFSessionRoleWinners['history-search'] = [pscustomobject]@{ Winner = 'fzf'; Reason = 'Defaults' }
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'MyHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt -WarningVariable warned 3>$null
        $script:Bound | Should -Be 1
        "$warned" | Should -Match 'Defaults'
    }
    It 'rebinds its own earlier binding when the tool registers again' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'DotForge history-search (fzf)' } }
        [void]$script:DFBoundKeys.Add('Ctrl+r')
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 1
    }
    It 'binds nothing, without error, when PSReadLine isn''t available' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Set-PSReadLineKeyHandler' }
        { Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt } | Should -Not -Throw
        $script:Bound | Should -Be 0
    }
}

Describe 'shared fuzzy key handler' {
    BeforeEach { Reset-DFTestSession; $script:DFBoundKeys.Clear(); $script:DFSessionRoleWinners = @{} }

    It 'reads history newest first, without repeats, joining multi-line entries' {
        $file = Join-Path $TestDrive 'hist.txt'
        Set-Content $file -Value @('git status', 'if ($x) {`', '  y`', '}', 'ls', 'git status')
        Get-DFHistoryCandidate -Path $file | Should -Be @('git status', 'ls', "if (`$x) {`n  y`n}")
    }
    It 'returns nothing for a missing history file' {
        Get-DFHistoryCandidate -Path (Join-Path $TestDrive 'none.txt') | Should -BeNullOrEmpty
    }
    It 'quotes inserted paths that hold a space or a quote' {
        Format-DFPathInsert -Path @('a.txt', 'my file.txt', "it's.txt") | Should -Be "a.txt 'my file.txt' 'it''s.txt'"
    }
    It 'quotes a path that PowerShell would read as code' {
        foreach ($name in '$(calc).txt', 'a;b.txt', 'x&y', 'tick`n', '(x).txt', '@a', '{b}', 'c|d', 'e>f', '#g', '-h') {
            Format-DFPathInsert -Path $name | Should -Be ("'" + $name.Replace("'", "''") + "'") -Because "$name must stay one literal argument"
        }
        Format-DFPathInsert -Path 'src/a.ps1', 'C:\x\y.txt' | Should -Be 'src/a.ps1 C:\x\y.txt'
    }
    It 'History: runs the engine on the history with the line as query and replaces the line' {
        $file = Join-Path $TestDrive 'h2.txt'
        Set-Content $file -Value @('git status')
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'git'; Cursor = 3 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = $file } }
        Mock Invoke-DFFuzzyEngine { 'git status' }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine sk -Key History
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { $Engine -eq 'sk' -and ($Arguments -join ' ') -eq '--no-sort --query git' -and @($InputObject) -contains 'git status' }
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Replace -eq 'git status' }
    }
    It 'History: a multi-line entry comes back exactly as saved' {
        $file = Join-Path $TestDrive 'h3.txt'
        Set-Content $file -Value @('a `', 'b')
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = ''; Cursor = 0 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = $file } }
        Mock Invoke-DFFuzzyEngine { @($InputObject)[0] }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key History
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Replace -eq "a `nb" }
    }
    It 'Esc changes nothing but redraws the prompt' {
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'x'; Cursor = 1 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = (Join-Path $TestDrive 'none.txt') } }
        Mock Invoke-DFFuzzyEngine { }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key History
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { -not $Replace -and -not $Insert }
    }
    It 'Path: runs the engine''s own default command with --multi and inserts the quoted picks' {
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'code '; Cursor = 5 } }
        Mock Invoke-DFFuzzyEngine { 'src/a.ps1'; 'my dir/b.ps1' }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Path
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq '--multi' -and -not $PSBoundParameters.ContainsKey('InputObject') }
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Insert -eq "src/a.ps1 'my dir/b.ps1'" }
    }
    It 'binds Ctrl+r for History and Ctrl+t for Path' {
        Mock Get-PSReadLineKeyHandler { }
        Mock Set-PSReadLineKeyHandler { }
        Register-DFFuzzyKeyHandler -Engine fzf -Key History -Tool fzf
        Register-DFFuzzyKeyHandler -Engine fzf -Key Path -Tool fzf
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+r' }
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+t' }
    }
}

Describe 'Remove-DFKeyHandlerCall' {
    It 'removes every Set-PSReadLineKeyHandler call and keeps the rest' {
        $script = @'
function Invoke-A { 'a' }
Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -ScriptBlock {
    Invoke-A
}
Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -ScriptBlock { Set-PSReadLineKeyHandler -Chord x -ScriptBlock {} }
'@
        $out = Remove-DFKeyHandlerCall -Script $script
        $out | Should -Not -Match 'Set-PSReadLineKeyHandler'
        $out | Should -Match 'function Invoke-A'
    }
    It 'returns $null for a script that doesn''t parse' {
        Remove-DFKeyHandlerCall -Script 'function {' | Should -BeNullOrEmpty
    }
}
