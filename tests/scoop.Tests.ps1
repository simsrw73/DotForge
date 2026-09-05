BeforeAll {
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/scoop.ps1'
}

Describe 'scoop companion' {
    AfterEach {
        Remove-Item 'function:global:scoop'        -ErrorAction Ignore
        Remove-Item 'function:global:scoop-search' -ErrorAction Ignore
        Remove-Item 'function:global:git'          -ErrorAction Ignore
    }

    # NOTE: This test runs FIRST on purpose. Defining then removing a global
    # `scoop-search` function (as the two tests below do) leaves a stale
    # Function-typed entry in PowerShell's command-resolution cache that survives
    # PATH clearing — so the absent-scoop-search scenario must be exercised before
    # any test introduces that ghost. Pester runs It blocks in file order.
    It 'does nothing and does not throw when scoop-search is absent' {
        function global:git { }
        # Make scoop-search unresolvable even on a machine where it is really on
        # PATH: it is an Application (a shim), so an empty PATH hides it. (Real exe
        # lookups are not cached across a PATH change; only function ghosts are.)
        # Restore PATH afterward regardless of outcome.
        $savedPath = $env:PATH
        try {
            $env:PATH = ''
            { . $script:CompanionPath } | Should -Not -Throw
            Get-Command scoop -CommandType Function -ErrorAction Ignore |
                Should -BeNullOrEmpty
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'installs the scoop-search hook as a GLOBAL function that survives Register-DFTool''s scope' {
        # Regression: scoop-search --hook emits `function scoop { ... }` with no
        # scope modifier. Register-DFTool dot-sources this companion INSIDE its own
        # function scope, so an unqualified definition would be discarded on return
        # and never reach the prompt. Reproduce that scope with an inner function,
        # then assert the hook survives globally afterward.

        # Stand-in for the real `scoop-search` shim: emits the exact hook text
        # (with an unqualified `function scoop`, as scoop-search does) and ignores
        # the --hook argument. The companion resolves this via Get-Command and & .
        function global:scoop-search {
            'function scoop { if ($args[0] -eq "search") { scoop-search.exe @($args | Select-Object -Skip 1) } else { scoop.ps1 @args } }'
        }
        function global:git { }  # satisfy the git-present check; no warning path

        function Invoke-LikeRegisterDFTool {
            . $script:CompanionPath
            # Inside the dot-sourcing scope the function must resolve...
            (Get-Command scoop -CommandType Function -ErrorAction Ignore) |
                Should -Not -BeNullOrEmpty
        }
        Invoke-LikeRegisterDFTool

        # ...and it must STILL resolve once that scope has returned.
        $fn = Get-Command scoop -CommandType Function -ErrorAction Ignore
        $fn | Should -Not -BeNullOrEmpty
        $fn.Definition | Should -Match 'scoop-search'
    }

    It 'leaves an already-global hook untouched (forward-compat with upstream global:)' {
        # Guard: if scoop-search is changed to emit `function global:scoop { ... }`
        # (a proposed upstream fix), the companion must not rewrite it — no double
        # `global:global:` mangling — and the hook must still install globally.
        function global:scoop-search {
            'function global:scoop { if ($args[0] -eq "search") { scoop-search.exe @($args | Select-Object -Skip 1) } else { scoop.ps1 @args } }'
        }
        function global:git { }

        { . $script:CompanionPath } | Should -Not -Throw
        $fn = Get-Command scoop -CommandType Function -ErrorAction Ignore
        $fn | Should -Not -BeNullOrEmpty
        # No mangled scope token leaked into the definition.
        $fn.Definition | Should -Not -Match 'global:'
    }
}

# NOTE: This Describe MUST come after 'scoop companion' above. Its BeforeEach
# dot-sources the companion with a scoop-search stub present, which installs a
# global `scoop` function (via the hook) — and defining/removing that global
# leaves a command-resolution-cache ghost that survives PATH clearing. The
# 'does nothing when scoop-search is absent' test above depends on running
# before any such ghost exists, so these picker tests are ordered last.
Describe 'scoop pickers' {
    BeforeAll {
        . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
        . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
        . "$PSScriptRoot/../Private/Invoke-DFPackageManagerPicker.ps1"
        Import-Module Scoop -ErrorAction SilentlyContinue   # so *-ScoopApp exist to mock
        function script:SApp ($Name, $Version, $Source) {
            [pscustomobject]@{ Name = $Name; Version = $Version; Source = $Source }
        }
    }

    BeforeEach {
        # scoop-search stand-in: emits hook text for --hook (consumed when the
        # companion loads), canned search results otherwise.
        function global:scoop-search {
            if ($args[0] -eq '--hook') { return 'function scoop { }' }
            "'main' bucket:"
            "    ripgrep (15.2.0) --> includes 'rg.exe'"
            "    rga (0.10.9)"
        }
        function global:git { }        # silence the git-absent warning
        . $script:CompanionPath
    }
    AfterEach {
        'Select-ScoopPackage', 'Remove-ScoopPackage', 'Invoke-ScoopUpdate',
        'Assert-DFScoopModule', 'scoop-search', 'git', 'scoop' |
            ForEach-Object { Remove-Item "function:global:$_" -ErrorAction Ignore }
        'sins', 'srm', 'sup' | ForEach-Object { Remove-Item "alias:global:$_" -ErrorAction Ignore }
        Remove-PSReadLineKeyHandler -Chord 'Ctrl+g,s' -ErrorAction Ignore
    }

    It 'defines sins/srm/sup functions and aliases globally' {
        (Get-Command Select-ScoopPackage -CommandType Function) | Should -Not -BeNullOrEmpty
        (Get-Alias sins).Definition | Should -Be 'Select-ScoopPackage'
        (Get-Alias srm).Definition  | Should -Be 'Remove-ScoopPackage'
        (Get-Alias sup).Definition  | Should -Be 'Invoke-ScoopUpdate'
    }

    It 'binds Ctrl+G,S to the install-command prefill when PSReadLine is present' {
        (Get-PSReadLineKeyHandler | Where-Object { $_.Key -eq 'Ctrl+g,s' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'installs the pickers as GLOBAL functions that survive Register-DFTool''s scope' {
        function Invoke-LikeRegisterDFTool {
            . $script:CompanionPath
            (Get-Command sins -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        }
        Invoke-LikeRegisterDFTool
        (Get-Command Select-ScoopPackage -CommandType Function -ErrorAction Ignore) |
            Should -Not -BeNullOrEmpty
    }

    Context 'search / install (sins)' {
        It 'parses scoop-search output into "<display>`t<name>" lines (bucket header skipped)' {
            $script:fed = $null
            Mock Invoke-DFFzf { $script:fed = $InputItems; '' ; @($InputItems)[0] }
            Select-ScoopPackage -Query 'rip' | Out-Null
            @($script:fed).Count | Should -Be 2
            @($script:fed)[0] | Should -Match "`tripgrep$"
        }

        It 'returns the install command on Enter' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[0] }
            Select-ScoopPackage -Query 'rip' | Should -Be 'scoop install ripgrep'
        }

        It 'calls Install-ScoopApp on Alt-R' {
            Mock Invoke-DFFzf { 'alt-r' ; @($InputItems)[0] }
            Mock Install-ScoopApp { }
            Select-ScoopPackage -Query 'rip' | Out-Null
            Should -Invoke Install-ScoopApp -ParameterFilter { $Name -eq 'ripgrep' }
        }
    }

    Context 'uninstall (srm)' {
        BeforeEach { Mock Get-ScoopApp { SApp '7zip' '26.02' 'main' } }

        It 'calls Uninstall-ScoopApp on Enter' {
            Mock Invoke-DFFzf { '' ; @($InputItems)[0] }
            Mock Uninstall-ScoopApp { }
            Remove-ScoopPackage | Out-Null
            Should -Invoke Uninstall-ScoopApp -ParameterFilter { $Name -eq '7zip' }
        }

        It 'returns the uninstall command on Alt-C' {
            Mock Invoke-DFFzf { 'alt-c' ; @($InputItems)[0] }
            Remove-ScoopPackage | Should -Be 'scoop uninstall 7zip'
        }
    }

    Context 'update (sup)' {
        BeforeEach {
            Mock Get-ScoopApp { SApp 'aria2' '1.37.0' 'main'; SApp 'bat' '0.26.1' 'main' }
        }

        It 'updates each selected app on Enter (multi-select)' {
            Mock Invoke-DFFzf { '' ; $InputItems }
            Mock Update-ScoopApp { }
            Invoke-ScoopUpdate | Out-Null
            Should -Invoke Update-ScoopApp -Times 2
        }

        It 'runs scoop update * on Alt-A' {
            Mock Invoke-DFFzf { 'alt-a' }
            Mock scoop { }
            Invoke-ScoopUpdate | Out-Null
            Should -Invoke scoop -ParameterFilter { $args -contains 'update' -and $args -contains '*' }
        }
    }

    Context 'module guard' {
        It 'returns without invoking the picker when the Scoop module is absent' {
            Mock Assert-DFScoopModule { $false }
            Mock Invoke-DFPicker { throw 'picker should not run' }
            { Select-ScoopPackage -Query 'x' } | Should -Not -Throw
            Should -Invoke Invoke-DFPicker -Times 0
        }
    }
}
