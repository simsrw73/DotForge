BeforeAll {
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/choco.ps1'
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFPackageManagerPicker.ps1"
}

Describe 'choco pickers' {
    BeforeEach {
        . $script:CompanionPath
        # choco stand-in: machine-readable (-r) rows keyed off the sub-command.
        Mock choco {
            if     ($args -contains 'search')   { 'recur|0.2.5'; 'ripgrep|14.1.0' }
            elseif ($args -contains 'list')     { 'chocolatey|2.7.3'; 'ripgrep|14.1.0' }
            elseif ($args -contains 'outdated') { 'ripgrep|13.0.0|14.1.0|false' }
        }
    }
    AfterEach {
        'Select-ChocoPackage', 'Remove-ChocoPackage', 'Invoke-ChocoUpdate',
        'Assert-DFChoco', 'Invoke-DFChocoElevated' |
            ForEach-Object { Remove-Item "function:global:$_" -ErrorAction Ignore }
        'cins', 'crm', 'cup' | ForEach-Object { Remove-Item "alias:global:$_" -ErrorAction Ignore }
        Remove-Alias sudo -Scope Global -Force -ErrorAction Ignore
        Remove-Item 'function:global:gsudo' -ErrorAction Ignore
        Remove-PSReadLineKeyHandler -Chord 'Ctrl+g,c' -ErrorAction Ignore
    }

    It 'defines cins/crm/cup functions and aliases globally' {
        (Get-Command Select-ChocoPackage -CommandType Function) | Should -Not -BeNullOrEmpty
        (Get-Alias cins).Definition | Should -Be 'Select-ChocoPackage'
        (Get-Alias crm).Definition  | Should -Be 'Remove-ChocoPackage'
        (Get-Alias cup).Definition  | Should -Be 'Invoke-ChocoUpdate'
    }

    It 'binds Ctrl+G,C to the install-command prefill when PSReadLine is present' {
        (Get-PSReadLineKeyHandler | Where-Object { $_.Key -eq 'Ctrl+g,c' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'installs the pickers as GLOBAL functions that survive Register-DFTool''s scope' {
        function Invoke-LikeRegisterDFTool {
            . $script:CompanionPath
            (Get-Command cins -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        }
        Invoke-LikeRegisterDFTool
        (Get-Command Select-ChocoPackage -CommandType Function -ErrorAction Ignore) |
            Should -Not -BeNullOrEmpty
    }

    Context 'search / install (cins)' {
        It 'parses "name|version" rows into "<display>`t<id>" lines' {
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems; '' ; @($InputItems)[0] }
            Select-ChocoPackage -Query 'rip' | Out-Null
            @($script:fed).Count | Should -Be 2
            @($script:fed)[0] | Should -Match "`trecur$"
        }

        It 'returns the install command on Enter' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[1] }
            Select-ChocoPackage -Query 'rip' | Should -Be 'choco install ripgrep -y'
        }

        It 'installs elevated on Alt-R' {
            Mock Invoke-DFFzf { 'alt-r' ; @($InputItems)[1] }
            Mock Invoke-DFChocoElevated { }
            Select-ChocoPackage -Query 'rip' | Out-Null
            Should -Invoke Invoke-DFChocoElevated -ParameterFilter {
                $ChocoArgs -contains 'install' -and $ChocoArgs -contains 'ripgrep'
            }
        }
    }

    Context 'uninstall (crm)' {
        It 'uninstalls elevated on Enter' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[0] }
            Mock Invoke-DFChocoElevated { }
            Remove-ChocoPackage | Out-Null
            Should -Invoke Invoke-DFChocoElevated -ParameterFilter {
                $ChocoArgs -contains 'uninstall' -and $ChocoArgs -contains 'chocolatey'
            }
        }

        It 'returns the uninstall command on Alt-C' {
            Mock Invoke-DFFzf { 'alt-c' ; @($InputItems)[0] }
            Remove-ChocoPackage | Should -Be 'choco uninstall chocolatey -y'
        }
    }

    Context 'update (cup)' {
        It 'parses "name|current|available|pinned" into "cur -> avail" lines' {
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems; }
            Invoke-ChocoUpdate | Out-Null
            @($script:fed)[0] | Should -Match '13.0.0 -> 14.1.0'
            @($script:fed)[0] | Should -Match "`tripgrep$"
        }

        It 'upgrades elevated for each selection on Enter' {
            Mock Invoke-DFFzf { '' ; $InputItems }
            Mock Invoke-DFChocoElevated { }
            Invoke-ChocoUpdate | Out-Null
            Should -Invoke Invoke-DFChocoElevated -ParameterFilter {
                $ChocoArgs -contains 'upgrade' -and $ChocoArgs -contains 'ripgrep'
            }
        }

        It 'runs "upgrade all" elevated on Alt-A' {
            Mock Invoke-DFFzf { 'alt-a' }
            Mock Invoke-DFChocoElevated { }
            Invoke-ChocoUpdate | Out-Null
            Should -Invoke Invoke-DFChocoElevated -ParameterFilter {
                $ChocoArgs -contains 'upgrade' -and $ChocoArgs -contains 'all'
            }
        }
    }

    Context 'guard' {
        It 'returns without invoking the picker when choco is absent' {
            Mock Assert-DFChoco { $false }
            Mock Invoke-DFPicker { throw 'picker should not run' }
            { Select-ChocoPackage -Query 'x' } | Should -Not -Throw
            Should -Invoke Invoke-DFPicker -Times 0
        }
    }

    It 'uses the configured sudo alias for elevated Chocolatey commands' {
        function global:gsudo { }
        Set-Alias -Name sudo -Value gsudo -Scope Global -Force
        Mock gsudo { }

        Invoke-DFChocoElevated install ripgrep -y

        Should -Invoke gsudo -Times 1 -ParameterFilter {
            $args -contains 'choco' -and $args -contains 'install' -and $args -contains 'ripgrep'
        }
    }
}
