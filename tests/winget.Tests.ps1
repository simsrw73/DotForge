BeforeAll {
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/winget.ps1'
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"

    # A fzf stand-in: returns whatever lines the test sets in $script:FzfOut, after
    # recording the items the picker fed in. Mocked per-test via Set-Variable.
    function script:FakePkg ($Name, $Id, $Ver, [switch]$Update, $Avail, $Source = 'winget') {
        [pscustomobject]@{
            Name = $Name; Id = $Id; Version = $Ver; InstalledVersion = $Ver
            IsUpdateAvailable = [bool]$Update; AvailableVersions = @($Avail, $Ver)
            Source = $Source
        }
    }
}

Describe 'winget companion' {
    BeforeEach {
        . $script:CompanionPath
    }
    AfterEach {
        'Select-WingetPackage', 'Remove-WingetPackage', 'Invoke-WingetUpdate', 'Assert-DFWingetModule' |
            ForEach-Object { Remove-Item "function:global:$_" -ErrorAction Ignore }
        'wins', 'wrm', 'wup' |
            ForEach-Object { Remove-Item "alias:global:$_" -ErrorAction Ignore }
        Remove-PSReadLineKeyHandler -Chord 'Ctrl+g,w' -ErrorAction Ignore
    }

    It 'defines wins/wrm/wup functions and aliases globally' {
        (Get-Command Select-WingetPackage -CommandType Function) | Should -Not -BeNullOrEmpty
        (Get-Command Remove-WingetPackage -CommandType Function) | Should -Not -BeNullOrEmpty
        (Get-Command Invoke-WingetUpdate  -CommandType Function) | Should -Not -BeNullOrEmpty
        (Get-Alias wins).Definition | Should -Be 'Select-WingetPackage'
        (Get-Alias wrm).Definition  | Should -Be 'Remove-WingetPackage'
        (Get-Alias wup).Definition  | Should -Be 'Invoke-WingetUpdate'
    }

    It 'binds Ctrl+G,W to the install-command prefill when PSReadLine is present' {
        (Get-PSReadLineKeyHandler | Where-Object { $_.Key -eq 'Ctrl+g,w' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'installs the pickers as GLOBAL functions that survive Register-DFTool''s scope' {
        # Register-DFTool dot-sources the companion INSIDE its own function scope;
        # `function global:` must make the pickers survive that scope's return.
        function Invoke-LikeRegisterDFTool {
            . $script:CompanionPath
            (Get-Command wins -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        }
        Invoke-LikeRegisterDFTool
        (Get-Command Select-WingetPackage -CommandType Function -ErrorAction Ignore) |
            Should -Not -BeNullOrEmpty
    }

    Context 'module guard' {
        It 'returns without invoking the picker when the module is absent' {
            Mock Assert-DFWingetModule { $false }
            Mock Invoke-DFPicker { throw 'picker should not run' }
            { Select-WingetPackage -Query 'x' } | Should -Not -Throw
            Should -Invoke Invoke-DFPicker -Times 0
        }

        It 'reports available when Find-WinGetPackage resolves' {
            # The module is installed in this environment, so the real guard is true.
            Assert-DFWingetModule | Should -BeTrue
        }
    }

    Context 'search / install picker (wins)' {
        BeforeEach {
            Mock Find-WinGetPackage { FakePkg 'RipGrep' 'BurntSushi.ripgrep.MSVC' '15.2.0' }
        }

        It 'feeds fzf a tab-delimited "<display>`t<id>" line built from object properties' {
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems; '' ; @($InputItems)[0] }
            Select-WingetPackage -Query 'ripgrep' | Out-Null
            @($script:fed)[0] | Should -Match "`tBurntSushi\.ripgrep\.MSVC$"
            @($script:fed)[0] | Should -Match 'RipGrep'
        }

        It 'returns the install command string on Enter (empty key line)' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[0] }
            $out = Select-WingetPackage -Query 'ripgrep'
            $out | Should -Be 'winget install --id BurntSushi.ripgrep.MSVC --exact'
        }

        It 'calls Install-WinGetPackage on Alt-R' {
            Mock Invoke-DFFzf { 'alt-r' ; @($InputItems)[0] }
            Mock Install-WinGetPackage { }
            Select-WingetPackage -Query 'ripgrep' | Out-Null
            Should -Invoke Install-WinGetPackage -ParameterFilter { $Id -eq 'BurntSushi.ripgrep.MSVC' }
        }

        It 'returns nothing when the user cancels' {
            Mock Invoke-DFFzf { }
            Select-WingetPackage -Query 'ripgrep' | Should -BeNullOrEmpty
        }
    }

    Context 'uninstall picker (wrm)' {
        BeforeEach {
            Mock Get-WinGetPackage { FakePkg 'draw.io' 'JGraph.Draw' '30.3.14' }
        }

        It 'calls Uninstall-WinGetPackage on Enter' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[0] }
            Mock Uninstall-WinGetPackage { }
            Remove-WingetPackage | Out-Null
            Should -Invoke Uninstall-WinGetPackage -ParameterFilter { $Id -eq 'JGraph.Draw' }
        }

        It 'returns the uninstall command on Alt-C' {
            Mock Invoke-DFFzf { 'alt-c' ; @($InputItems)[0] }
            Remove-WingetPackage | Should -Be 'winget uninstall --id JGraph.Draw'
        }

        It 'filters the list to -Source, dropping other/ARP entries' {
            Mock Get-WinGetPackage {
                FakePkg 'draw.io'  'JGraph.Draw'  '30.3.14' -Source winget
                FakePkg 'SomeArp'  'ARP\X\Y'      '1.0'     -Source ''
                FakePkg 'AStore'   'Store.App'    '2.0'     -Source msstore
            }
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems }
            Remove-WingetPackage -Source winget | Out-Null
            @($script:fed).Count | Should -Be 1
            ($script:fed -join "`n") | Should -Match 'JGraph.Draw'
            ($script:fed -join "`n") | Should -Not -Match 'ARP'
        }

        It 'lists every source when -Source is omitted' {
            Mock Get-WinGetPackage {
                FakePkg 'draw.io' 'JGraph.Draw' '30.3.14' -Source winget
                FakePkg 'SomeArp' 'ARP\X\Y'     '1.0'     -Source ''
            }
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems }
            Remove-WingetPackage | Out-Null
            @($script:fed).Count | Should -Be 2
        }
    }

    Context 'update picker (wup)' {
        BeforeEach {
            Mock Get-WinGetPackage {
                FakePkg 'Claude'  'Anthropic.Claude' '1.0' -Update -Avail '2.0'
                FakePkg 'Codex'   'OpenAI.Codex'     '0.1' -Update -Avail '0.2'
                FakePkg 'Stable'  'Some.Stable'      '9.0'          -Avail '9.0'
            }
        }

        It 'lists only upgradable packages' {
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems; }
            Invoke-WingetUpdate | Out-Null
            @($script:fed).Count | Should -Be 2
            ($script:fed -join "`n") | Should -Not -Match 'Some\.Stable'
        }

        It 'updates each selected package on Enter (multi-select)' {
            Mock Invoke-DFFzf { '' ; $InputItems }   # Enter, both items selected
            Mock Update-WinGetPackage { }
            Invoke-WingetUpdate | Out-Null
            Should -Invoke Update-WinGetPackage -Times 2
        }

        It 'runs winget upgrade --all on Alt-A' {
            Mock Invoke-DFFzf { 'alt-a' }
            Mock winget { }
            Invoke-WingetUpdate | Out-Null
            Should -Invoke winget -ParameterFilter { $args -contains 'upgrade' -and $args -contains '--all' }
        }
    }
}
