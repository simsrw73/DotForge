BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:PSFzfCompanion = Join-Path $PSScriptRoot '../Tools/PSFzf.ps1'
    $script:CarapaceCompanion = Join-Path $PSScriptRoot '../Tools/carapace.ps1'
    $script:InshellisenseCompanion = Join-Path $PSScriptRoot '../Tools/inshellisense.ps1'
    # PSFzf is not installed in the test environment; Pester can only mock commands
    # that exist, so stub them. (Assert-MockCalled must not be used: Pester 6 removed
    # it, and calling it auto-imports Windows PowerShell's Pester 3.4.0.)
    function Set-PsFzfOption { param([Parameter(ValueFromRemainingArguments)]$Rest) }
    function Invoke-FzfTabCompletion { }
}

Describe 'tab-completion sidecar hooks' {
    BeforeEach {
        $script:SavedFzfDefaultOpts = $Env:FZF_DEFAULT_OPTS
        $script:SavedCarapaceBridges = $Env:CARAPACE_BRIDGES
        Set-DFTestXdg
        Remove-Item function:Initialize-DFRoleTabCompletion -ErrorAction Ignore
        Remove-DFTestGlobal -Function Start-DFInshellisense
    }
    AfterEach {
        if ($null -eq $script:SavedFzfDefaultOpts) { Remove-Item Env:FZF_DEFAULT_OPTS -ErrorAction Ignore } else { $Env:FZF_DEFAULT_OPTS = $script:SavedFzfDefaultOpts }
        if ($null -eq $script:SavedCarapaceBridges) { Remove-Item Env:CARAPACE_BRIDGES -ErrorAction Ignore } else { $Env:CARAPACE_BRIDGES = $script:SavedCarapaceBridges }
        Remove-Item function:Initialize-DFRoleTabCompletion, function:Enable-DFCarapaceInshellisenseBridge -ErrorAction Ignore
        Remove-DFTestGlobal -Function Start-DFInshellisense
        Restore-DFTestXdg
    }

    Context 'PSFzf' {
        BeforeEach {
            Mock Import-Module { } -ParameterFilter { $Name -eq 'PSFzf' }
            Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }
            Mock Set-PsFzfOption { }
            Mock Set-PSReadLineKeyHandler { }
        }

        It 'binds Tab to a ScriptBlock that invokes Invoke-FzfTabCompletion' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'carapace' }
            . $script:PSFzfCompanion
            Initialize-DFRoleTabCompletion -Tool ([pscustomobject]@{}) -Role 'tab-completion'

            Should -Invoke Set-PSReadLineKeyHandler -Times 1 -Exactly -ParameterFilter {
                $Key -eq 'Tab' -and $ScriptBlock -is [scriptblock] -and $ScriptBlock.ToString() -match 'Invoke-FzfTabCompletion'
            }
        }

        It 'adds --ansi only once when carapace is resolvable and preserves existing options' {
            $Env:FZF_DEFAULT_OPTS = '--height 40% --ansi --layout reverse'
            Mock Get-Command { [pscustomobject]@{ Name = 'carapace' } } -ParameterFilter { $Name -eq 'carapace' }
            . $script:PSFzfCompanion
            Initialize-DFRoleTabCompletion -Tool ([pscustomobject]@{}) -Role 'tab-completion'

            $Env:FZF_DEFAULT_OPTS | Should -Be '--height 40% --ansi --layout reverse'
        }

        It 'leaves FZF_DEFAULT_OPTS unchanged when carapace is absent' {
            $Env:FZF_DEFAULT_OPTS = '--height 40% --layout reverse'
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'carapace' }
            . $script:PSFzfCompanion
            Initialize-DFRoleTabCompletion -Tool ([pscustomobject]@{}) -Role 'tab-completion'

            $Env:FZF_DEFAULT_OPTS | Should -Be '--height 40% --layout reverse'
        }
    }

    Context 'carapace' {
        BeforeEach {
            Mock Get-DFXdgPath { Join-Path $TestDrive 'xdg-config' }
            Mock New-DFDirectory { }
            Mock Get-DFCachedCommandOutput { 'return' }
            Mock Invoke-Expression { }
            Mock Get-Command { $null }
            Mock Get-DFRole { [pscustomobject]@{ Winner = 'carapace' } }
            Mock Set-PSReadLineKeyHandler { }
        }

        It 'binds Tab to MenuComplete' {
            . $script:CarapaceCompanion
            Initialize-DFRoleTabCompletion -Tool ([pscustomobject]@{}) -Role 'tab-completion'
            Should -Invoke Set-PSReadLineKeyHandler -Times 1 -Exactly -ParameterFilter { $Key -eq 'Tab' -and $Function -eq 'MenuComplete' }
        }

        It 'looks up the tab-completion winner once per startup' {
            # The bridge itself is covered below; this guards the startup cost (one Get-DFRole call).
            Mock Get-Command { [pscustomobject]@{ Name = 'is' } } -ParameterFilter { $Name -eq 'is' }
            . $script:CarapaceCompanion
            Should -Invoke Get-DFRole -Times 1 -Exactly -ParameterFilter { $Name -eq 'tab-completion' }
        }

        It 'merges inshellisense into user bridges without duplicates when it did not win Tab' {
            $Env:CARAPACE_BRIDGES = 'zsh,InShelliSense,bash,ZSH'
            Mock Get-Command { [pscustomobject]@{ Name = 'is' } } -ParameterFilter { $Name -eq 'is' }
            . $script:CarapaceCompanion
            Enable-DFCarapaceInshellisenseBridge -TabCompletionWinner 'carapace' | Should -BeTrue
            $Env:CARAPACE_BRIDGES | Should -Be 'zsh,InShelliSense,bash'
        }

        It 'does not bridge when inshellisense won Tab' {
            Mock Get-Command { [pscustomobject]@{ Name = 'is' } } -ParameterFilter { $Name -eq 'is' }
            . $script:CarapaceCompanion
            $Env:CARAPACE_BRIDGES = 'zsh'
            Enable-DFCarapaceInshellisenseBridge -TabCompletionWinner 'inshellisense' | Should -BeFalse
            $Env:CARAPACE_BRIDGES | Should -Be 'zsh'
        }

        It 'does not bridge when inshellisense is not installed' {
            . $script:CarapaceCompanion
            $Env:CARAPACE_BRIDGES = 'zsh'
            Enable-DFCarapaceInshellisenseBridge -TabCompletionWinner 'carapace' | Should -BeFalse
            $Env:CARAPACE_BRIDGES | Should -Be 'zsh'
        }
    }

    It 'starts inshellisense without binding Tab' {
        Mock Set-PSReadLineKeyHandler { }
        . $script:InshellisenseCompanion
        Mock Start-DFInshellisense { }
        Initialize-DFRoleTabCompletion -Tool ([pscustomobject]@{}) -Role 'tab-completion'
        Should -Invoke Start-DFInshellisense -Times 1 -Exactly
        Should -Invoke Set-PSReadLineKeyHandler -Times 0 -Exactly -ParameterFilter { $Key -eq 'Tab' }
    }
}

Describe 'Register-DFTool tab-completion role activation' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:TabCalls = @()
        $script:Tools = Join-Path $TestDrive "tools-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:Tools | Out-Null
        '{ "tab-completion": { "kind": "single", "hook": "Initialize-DFRoleTabCompletion" } }' | Set-Content (Join-Path $TestDrive 'roles-tab.json')
        $script:DFRoleDb = Get-DFRoleDb -Path (Join-Path $TestDrive 'roles-tab.json')
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Set-PSReadLineKeyHandler { param($Key) if ($Key -eq 'Tab') { $script:TabCalls += 'Tab' } }
        function script:Write-TabTool([string]$Name, [int]$Priority) {
            "{ `"name`": `"$Name`", `"executable`": `"$Name.exe`", `"roles`": { `"tab-completion`": { `"priority`": $Priority } } }" | Set-Content (Join-Path $script:Tools "$Name.json")
            "function Initialize-DFRoleTabCompletion { param(`$Tool, `$Role) `$script:TabCalls += '$Name' }" | Set-Content (Join-Path $script:Tools "$Name.ps1")
        }
        Write-TabTool high 20
        Write-TabTool low 10
        '{ "name": "plain", "executable": "plain.exe" }' | Set-Content (Join-Path $script:Tools 'plain.json')
    }
    AfterEach { $script:DFRoleDb = $null; Remove-Variable TabCalls -Scope Script -ErrorAction Ignore }

    It 'runs only the highest-priority tab-completion hook' {
        Register-DFTool -Name high, low -ToolsPath $script:Tools
        $script:TabCalls | Should -Contain 'high'
        $script:TabCalls | Should -Not -Contain 'low'
    }

    It 'does not bind Tab when no registered tool is a tab-completion candidate' {
        Register-DFTool -Name plain -ToolsPath $script:Tools
        @($script:TabCalls | Where-Object { $_ -eq 'Tab' }).Count | Should -Be 0
    }
}
