BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # Native completers can't be unregistered, so every test uses its own command name.
    function script:New-LazyTestName { "dflazy$([guid]::NewGuid().ToString('N').Substring(0, 8))" }
    function script:Get-Completion([string]$line) {
        @((TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText)
    }
}

Describe 'Register-DFLazyCompleter' {
    It 'does not run the loader when it registers' {
        $name  = New-LazyTestName
        $state = @{ Loads = 0 }
        Register-DFLazyCompleter -CommandName $name -Load { $state.Loads++ }.GetNewClosure()
        $state.Loads | Should -Be 0
    }

    It 'runs the loader on the first Tab and answers that Tab with the real completer' {
        $name  = New-LazyTestName
        $state = @{ Loads = 0 }
        $load = {
            $state.Loads++
            Register-ArgumentCompleter -Native -CommandName $name -ScriptBlock {
                param($wordToComplete, $commandAst, $cursorPosition)
                'alpha', 'beta' | Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
            }
        }.GetNewClosure()
        Register-DFLazyCompleter -CommandName $name -Load $load

        Get-Completion "$name a" | Should -Be @('alpha')
        Get-Completion "$name b" | Should -Be @('beta')
        $state.Loads | Should -Be 1
    }

    It 'answers a first Tab after a trailing space with the next argument, not the command name' {
        # The command's extent stops before the space, so the cursor sits past its end.
        $name = New-LazyTestName
        $load = {
            Register-ArgumentCompleter -Native -CommandName $name -ScriptBlock {
                param($wordToComplete, $commandAst, $cursorPosition)
                'alpha', 'beta' | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
            }
        }.GetNewClosure()
        Register-DFLazyCompleter -CommandName $name -Load $load

        Get-Completion "$name " | Should -Be @('alpha', 'beta')
    }

    It 'loads once and does not loop when the loader registers no completer' {
        # PowerShell then falls back to file names, which is the right answer.
        $name  = New-LazyTestName
        $state = @{ Loads = 0 }
        Register-DFLazyCompleter -CommandName $name -Load { $state.Loads++ }.GetNewClosure()

        Get-Completion "$name a" | Out-Null
        Get-Completion "$name a" | Out-Null
        $state.Loads | Should -Be 1
    }

    It 'returns nothing when the loader throws' {
        $name = New-LazyTestName
        Register-DFLazyCompleter -CommandName $name -Load { throw 'no completer here' }
        { Get-Completion "$name a" } | Should -Not -Throw
    }
}
