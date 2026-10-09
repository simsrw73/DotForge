BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'Tools/delta.json' {
    BeforeEach { Reset-DFTestSession }
    It 'sets GIT_PAGER only as the diff role winner, and carries no top-level env (no DELTA_FEATURES)' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.PSObject.Properties['env'] | Should -BeNullOrEmpty
        $j.roles.diff.env.GIT_PAGER | Should -Be 'delta'
    }
}

Describe 'Tools/delta/catppuccin.gitconfig' {
    BeforeEach { Reset-DFTestSession }
    It 'exists and defines the catppuccin-mocha feature' {
        $path = Join-Path $script:RealTools 'delta' 'catppuccin.gitconfig'
        Test-Path $path | Should -BeTrue
        (Get-Content $path -Raw) | Should -Match '\[delta "catppuccin-mocha"\]'
    }
}

Describe 'delta tool sidecar' {
    BeforeAll {
        # These tests run the real git against a private GIT_CONFIG_GLOBAL. A git
        # function or alias left by another test file would swallow those calls.
        $shadow = Get-Command git -CommandType Function, Alias -ErrorAction Ignore
        if ($shadow) { throw "A '$($shadow.CommandType)' named git shadows git.exe; an earlier test did not clean it up (use Remove-DFTestGlobal)." }
    }
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb   = $null
        $script:DFToolAvailability = @{}
        $script:SavedFeat  = $Env:DELTA_FEATURES
        $Env:DELTA_FEATURES = $null
        Set-DFTestConfig $null
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\delta.exe' } }

        Set-DFTestXdg

        $script:SavedGitConfigGlobal = $Env:GIT_CONFIG_GLOBAL


        $Env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        Remove-Item $Env:XDG_CONFIG_HOME, $Env:XDG_STATE_HOME, $Env:GIT_CONFIG_GLOBAL -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        $Env:DELTA_FEATURES = $script:SavedFeat
        Set-DFTestConfig $null

        $Env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal
        Restore-DFTestXdg
    }

    It 'sets DELTA_FEATURES to the canonical default, additively (+), when no theme is configured' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
    }
    It 'follows the shared $DFConfig[Theme]' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
    }
    It 'lets $DFConfig[DeltaTheme] override with a verbatim (non-canonical) name, additively' {
        Set-DFTestConfig @{ DeltaTheme = 'my-custom-feature' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+my-custom-feature'
    }

    It 'deploys the bundled catppuccin theme file to $XDG_CONFIG_HOME/delta' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'
        Test-Path $deployed | Should -BeTrue
        (Get-Content $deployed -Raw) | Should -Match '\[delta "catppuccin-mocha"\]'
    }

    It 'deploys a byte-identical copy and leaves it untouched on a second registration' {
        # Set-Content appends a newline, so a copy written without -NoNewline never
        # compares equal to the bundled file and was rewritten on every start.
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'
        $bundled  = Join-Path $script:RealTools 'delta' 'catppuccin.gitconfig'
        (Get-Content $deployed -Raw) | Should -BeExactly (Get-Content $bundled -Raw)
        $first = (Get-Item $deployed).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        (Get-Item $deployed).LastWriteTimeUtc | Should -Be $first
    }

    It 'adds exactly one include.path entry and records setup state on first registration' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'

        @(git config --global --get-all include.path) | Should -Contain $deployed
        (Get-DFToolSetupState).PSObject.Properties['delta'] | Should -Not -BeNullOrEmpty
        (Get-DFToolSetupState).delta.actions[0].path | Should -Be $deployed
    }

    It 'does not re-invoke git config on a second registration (state entry short-circuits it)' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'
        git config --global --unset-all include.path *>$null

        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools

        @(git config --global --get-all include.path 2>$null) | Should -Not -Contain $deployed
    }

    It 'skips the git-config edit and setup state entirely when SkipSetup names delta' {
        Set-DFTestConfig @{ SkipSetup = @('delta') }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools

        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
        @(git config --global --get-all include.path 2>$null) | Should -BeNullOrEmpty
        (Get-DFToolSetupState).PSObject.Properties['delta'] | Should -BeNullOrEmpty
    }

    It 'prints a visible confirmation naming the removal command on first add' {
        $out = Register-DFTool -Name 'delta' -ToolsPath $script:RealTools 6>&1 | Out-String
        $out | Should -Match 'git config --global --unset-all include\.path'
    }
}
