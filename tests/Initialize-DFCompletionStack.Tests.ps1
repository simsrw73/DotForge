BeforeAll {
    $completionStackPath = Join-Path $PSScriptRoot '..' 'Private' 'Initialize-DFCompletionStack.ps1'
    if (Test-Path $completionStackPath) { . $completionStackPath }
}

Describe 'Completion stack coordinator' {
    BeforeEach {
        $script:hadConfig = Test-Path Variable:Global:DFConfig
        if ($script:hadConfig) { $script:originalConfig = $Global:DFConfig }
        $script:hadBridges = Test-Path Env:CARAPACE_BRIDGES
        if ($script:hadBridges) { $script:originalBridges = $Env:CARAPACE_BRIDGES }
    }

    AfterEach {
        if ($script:hadConfig) { $Global:DFConfig = $script:originalConfig } else { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }
        if ($script:hadBridges) { $Env:CARAPACE_BRIDGES = $script:originalBridges } else { Remove-Item Env:CARAPACE_BRIDGES -ErrorAction Ignore }
    }

    Context 'Get-DFCompletionMode' {
        It 'defaults to Native' {
            Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
            Get-DFCompletionMode | Should -Be 'Native'
        }

        It 'warns and falls back for an invalid value' {
            $Global:DFConfig = @{ CompletionMode = 'invalid' }
            Get-DFCompletionMode -WarningVariable warns 3>$null | Should -Be 'Native'
            $warns | Should -Match 'CompletionMode'
        }
    }

    Context 'Enable-DFCarapaceInshellisenseBridge' {
        It 'deduplicates the bridge without changing user casing' {
            $Global:DFConfig = @{ CompletionMode = 'Native' }
            $Env:CARAPACE_BRIDGES = 'bash,InShelliSense,fish'
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\bin\is.exe' } }

            Enable-DFCarapaceInshellisenseBridge | Should -BeTrue
            $Env:CARAPACE_BRIDGES | Should -Be 'bash,InShelliSense,fish'
        }

        It 'appends inshellisense when no user bridge entry exists' {
            $Global:DFConfig = @{ CompletionMode = 'Native' }
            $Env:CARAPACE_BRIDGES = 'bash,fish'
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\bin\is.exe' } }

            Enable-DFCarapaceInshellisenseBridge | Should -BeTrue
            $Env:CARAPACE_BRIDGES | Should -Be 'bash,fish,inshellisense'
        }
        It 'returns false when the native bridge executable is unavailable' {
            $Global:DFConfig = @{ CompletionMode = 'Native' }
            Mock Get-Command { $null }

            Enable-DFCarapaceInshellisenseBridge | Should -BeFalse
        }
    }

    Context 'Enable-DFFzfAnsiOption' {
        BeforeEach {
            $script:hadFzfOpts = Test-Path Env:FZF_DEFAULT_OPTS
            if ($script:hadFzfOpts) { $script:originalFzfOpts = $Env:FZF_DEFAULT_OPTS }
        }
        AfterEach {
            if ($script:hadFzfOpts) { $Env:FZF_DEFAULT_OPTS = $script:originalFzfOpts } else { Remove-Item Env:FZF_DEFAULT_OPTS -ErrorAction Ignore }
        }

        It 'adds --ansi when FZF_DEFAULT_OPTS is unset' {
            Remove-Item Env:FZF_DEFAULT_OPTS -ErrorAction Ignore
            Enable-DFFzfAnsiOption
            $Env:FZF_DEFAULT_OPTS | Should -Be '--ansi'
        }

        It 'appends --ansi while preserving existing options' {
            $Env:FZF_DEFAULT_OPTS = '--height=40% --reverse'
            Enable-DFFzfAnsiOption
            $Env:FZF_DEFAULT_OPTS | Should -Be '--height=40% --reverse --ansi'
        }

        It 'is idempotent — does not duplicate --ansi' {
            $Env:FZF_DEFAULT_OPTS = '--ansi --reverse'
            Enable-DFFzfAnsiOption
            $Env:FZF_DEFAULT_OPTS | Should -Be '--ansi --reverse'
        }
    }
}
Describe 'Initialize-DFCompletionStack' {
    BeforeEach {
        $script:hadConfig = Test-Path Variable:Global:DFConfig
        if ($script:hadConfig) { $script:originalConfig = $Global:DFConfig }
        Mock Set-PSReadLineKeyHandler {}
    }

    AfterEach {
        if ($script:hadConfig) { $Global:DFConfig = $script:originalConfig } else { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }
    }

    It 'binds PSFzf Tab completion with its script block' {
        Initialize-DFCompletionStack -RegisteredTools 'PSFzf', 'Carapace'
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Key -eq 'Tab' -and $ScriptBlock }
    }

    It 'enables fzf --ansi when PSFzf and Carapace are both registered' {
        Mock Enable-DFFzfAnsiOption {}
        Initialize-DFCompletionStack -RegisteredTools 'PSFzf', 'Carapace'
        Assert-MockCalled Enable-DFFzfAnsiOption -Times 1
    }

    It 'does not enable fzf --ansi when Carapace is absent' {
        Mock Enable-DFFzfAnsiOption {}
        Initialize-DFCompletionStack -RegisteredTools 'PSFzf'
        Assert-MockCalled Enable-DFFzfAnsiOption -Times 0
    }

    It 'binds Carapace Tab completion when PSFzf is absent' {
        Initialize-DFCompletionStack -RegisteredTools 'Carapace'
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Key -eq 'Tab' -and $Function -eq 'MenuComplete' }
    }

    It 'does not bind Tab without a registered completion component' {
        Initialize-DFCompletionStack -RegisteredTools @()
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 0
    }

    It 'warns and uses the Native result when Inshellisense is unavailable' {
        $Global:DFConfig = @{ CompletionMode = 'Inshellisense' }
        Mock Get-Command { $null }
        Initialize-DFCompletionStack -RegisteredTools 'Carapace' -WarningVariable warns 3>$null
        $warns | Should -Match 'Inshellisense'
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Function -eq 'MenuComplete' }
    }

    It 'falls back to Native when only the inshellisense command is available' {
        $Global:DFConfig = @{ CompletionMode = 'Inshellisense' }
        function Start-DFInshellisense {}
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'inshellisense') { [pscustomobject]@{ Source = 'C:\bin\inshellisense.exe' } }
        }
        Mock Start-DFInshellisense {}

        Initialize-DFCompletionStack -RegisteredTools 'Carapace' -WarningVariable warns 3>$null

        $warns | Should -Match 'Inshellisense'
        Assert-MockCalled Start-DFInshellisense -Times 0
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Function -eq 'MenuComplete' }
    }
    It 'falls back to Native when the Inshellisense starter is unavailable' {
        $Global:DFConfig = @{ CompletionMode = 'Inshellisense' }
        Remove-Item Function:Start-DFInshellisense -ErrorAction Ignore
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'is') { [pscustomobject]@{ Source = 'C:\bin\is.exe' } }
        }

        Initialize-DFCompletionStack -RegisteredTools 'Carapace' -WarningVariable warns 3>$null

        $warns | Should -Match 'starter'
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Function -eq 'MenuComplete' }
    }
    It 'starts Inshellisense and does not bind Tab when its executable is available' {
        $Global:DFConfig = @{ CompletionMode = 'Inshellisense' }
        function Start-DFInshellisense {}
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\bin\is.exe' } }
        Mock Start-DFInshellisense {}
        Initialize-DFCompletionStack -RegisteredTools 'PSFzf', 'Carapace'
        Assert-MockCalled Start-DFInshellisense -Times 1
        Assert-MockCalled Set-PSReadLineKeyHandler -Times 0
    }
}