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
    It 'binds nothing, without error, when PSReadLine isn''t loaded (a redirected host)' {
        # pwsh 7 always ships PSReadLine, so "available" isn't the test: an interactive console has it loaded.
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'PSReadLine' }
        Mock Get-PSReadLineKeyHandler { }
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
    It 'quotes a name that PowerShell would read as a number' {
        foreach ($name in '1kb', '0x10', '1e3', '42', '+5', '.5', '1.5mb') {
            $line = Format-DFPathInsert -Path $name
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput("echo $line", [ref]$tokens, [ref]$errors)
            $argument = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[1]
            $argument | Should -BeOfType ([System.Management.Automation.Language.StringConstantExpressionAst]) -Because "$name must stay a file name"
            $argument.Value | Should -BeExactly $name
        }
        Format-DFPathInsert -Path 'src/a.txt', '.gitignore', 'v1.txt', 'a1' | Should -Be 'src/a.txt .gitignore v1.txt a1'
    }
    It 'escapes every quote PowerShell accepts as a single quote' {
        foreach ($q in "'", [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B) {
            $name = "a$($q); calc $($q)b"
            $line = Format-DFPathInsert -Path $name
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput("echo $line", [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
            $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements.Count | Should -Be 2 -Because "U+$('{0:X4}' -f [int][char]$q) must not end the quoted name"
            $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[1].Value | Should -BeExactly $name
        }
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
    It 'Directory: streams the folders with --tiebreak=index and moves to the pick''s real path' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = '~'; Path = 'C:\h' }; [pscustomobject]@{ Shown = 'src\lib'; Path = 'C:\w\src\lib' } }
        Mock Invoke-DFFuzzyEngine { @(& $Stream { $false })[1] }
        Mock Enter-DFDirectory { $true }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { $Engine -eq 'fzf' -and $Arguments -contains '--tiebreak=index' }
        Should -Invoke Enter-DFDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\w\src\lib' }
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { -not $Replace -and -not $Insert }
    }
    It 'Directory: ranked folders are drawn in the accent color, and the pick maps back from the plain text' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = 'C:\h\a'; Path = 'C:\h\a'; Ranked = $true }; [pscustomobject]@{ Shown = 'src'; Path = 'C:\w\src'; Ranked = $false } }
        Mock Invoke-DFFuzzyEngine { $script:Sent = @(& $Stream { $false }); 'C:\h\a' }
        Mock Enter-DFDirectory { $true }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory -Accent '#cba6f7'
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { $Arguments -contains '--ansi' }
        $script:Sent[0] | Should -BeExactly "$([char]27)[38;2;203;166;247mC:\h\a$([char]27)[0m"
        $script:Sent[1] | Should -BeExactly 'src'
        Should -Invoke Enter-DFDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\h\a' }
    }
    It 'Directory: without an accent, ranked folders are bold' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = 'C:\h\a'; Path = 'C:\h\a'; Ranked = $true } }
        Mock Invoke-DFFuzzyEngine { $script:Sent = @(& $Stream { $false }) }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory
        $script:Sent[0] | Should -BeExactly "$([char]27)[1mC:\h\a$([char]27)[0m"
    }
    It 'Directory: an accent that isn''t a #rrggbb color is ignored' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = 'C:\h\a'; Path = 'C:\h\a'; Ranked = $true } }
        Mock Invoke-DFFuzzyEngine { $script:Sent = @(& $Stream { $false }) }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory -Accent "red$([char]27)[2J"
        $script:Sent[0] | Should -BeExactly "$([char]27)[1mC:\h\a$([char]27)[0m"
    }
    It 'Directory: a message from the move stays on screen; the prompt is redrawn below it' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = 'gone'; Path = 'C:\gone' } }
        Mock Invoke-DFFuzzyEngine { @(& $Stream { $false })[0] }
        Mock Enter-DFDirectory { Write-DFKeyMessage 'DotForge: C:\gone no longer exists'; $false }
        Mock Write-Host { }
        Mock Invoke-DFPromptRedraw { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory
        Should -Invoke Invoke-DFPromptRedraw -Times 1 -Exactly -ParameterFilter { $Below }
        $script:DFKeyMessageShown | Should -BeFalse -Because 'the flag is used once'
        Update-DFReadLineBuffer
        Should -Invoke Invoke-DFPromptRedraw -Times 1 -Exactly -ParameterFilter { -not $Below }
    }
    It 'Directory: Esc moves nowhere' {
        Mock Get-DFDirectoryJumpCandidate { [pscustomobject]@{ Shown = 'a'; Path = 'C:' } }
        Mock Invoke-DFFuzzyEngine { }
        Mock Enter-DFDirectory { $true }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Directory
        Should -Invoke Enter-DFDirectory -Times 0
    }
    It 'Directory: binds Alt+c for the directory-jump role' {
        Mock Set-DFRoleKeyHandler { }
        Register-DFFuzzyKeyHandler -Engine fzf -Key Directory -Tool fzf
        Should -Invoke Set-DFRoleKeyHandler -Times 1 -ParameterFilter { $Role -eq 'directory-jump' -and $Chord -eq 'Alt+c' -and $Tool -eq 'fzf' }
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
    It 'reads the engine''s output as UTF-8, then restores the console encoding' {
        function global:Invoke-DFTestEngine { [Console]::OutputEncoding.WebName }
        $before = [Console]::OutputEncoding
        try {
            Invoke-DFFuzzyEngine -Engine 'Invoke-DFTestEngine' | Should -Be 'utf-8'
            [Console]::OutputEncoding.WebName | Should -Be $before.WebName
        } finally {
            Remove-DFTestGlobal -Function 'Invoke-DFTestEngine'
        }
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

Describe 'streaming to the engine stops early' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'returns the pick as soon as the engine exits, and the source sees the stop' {
        $source = { param($StopWhen) 'first'; $sw = [Diagnostics.Stopwatch]::StartNew(); while (-not (& $StopWhen) -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 50 }; 'never' }
        Mock Get-Command { [pscustomobject]@{ Source = $script:Pwsh } } -ParameterFilter { $Name -eq 'fake-engine' }
        $time = Measure-Command {
            $script:Picked = @(Invoke-DFFuzzyEngine -Engine 'fake-engine' -Arguments @('-NoProfile', '-Command', '[Console]::In.ReadLine()') -Stream $source)
        }
        $script:Picked | Should -Be @('first')
        $time.TotalSeconds | Should -BeLessThan 15
    }
    It 'stops a declared scan process when told to, instead of waiting for it' {
        $marker = "dfj-scan-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $scan = [pscustomobject]@{ name = 'slowscan'; executable = 'x.exe'; roles = [pscustomobject]@{ 'file-search' = [pscustomobject]@{ directories = $null; enter = $null; directoryScan = @($script:Pwsh, '-NoProfile', '-Command', "'a'; Start-Sleep 30 # $marker {depth}") } } }
        Reset-DFTestSession
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:DFSessionToolDb['slowscan'] = $scan
        $script:DFSessionStatus['slowscan'] = New-DFToolStatus -Name 'slowscan' -State Active -RequestedBy 'Tools'
        $script:Seen = 0
        Push-Location $TestDrive
        try {
            $time = Measure-Command { Get-DFDirectoryJumpCandidate -Depth 2 -StopWhen { $script:Seen -ge 1 } | ForEach-Object { $script:Seen++ } }
        } finally { Pop-Location; Reset-DFTestSession }
        $script:Seen | Should -Be 1
        $time.TotalSeconds | Should -BeLessThan 15
        Start-Sleep -Milliseconds 300
        @(Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like "*$marker*" }).Count | Should -Be 0
    }
}
