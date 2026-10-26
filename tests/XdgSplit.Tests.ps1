BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'xdg.vars is path-templates-only after the split' {
    BeforeEach { Reset-DFTestSession }
    It 'tool <Name> has no non-XDG value in xdg.vars' -ForEach @(
        @{ Name = 'fzf' }, @{ Name = 'delta' }, @{ Name = 'less' }, @{ Name = 'mdcat' },
        @{ Name = 'rustup' }, @{ Name = 'vcpkg' }
    ) {
        $j = Get-Content (Join-Path $script:RealTools "$Name.json") -Raw | ConvertFrom-Json
        $vars = $j.xdg.PSObject.Properties['vars']?.Value
        if ($vars) {
            foreach ($p in $vars.PSObject.Properties) {
                $p.Value | Should -Match '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}' `
                    -Because "$Name xdg.vars['$($p.Name)'] must be an XDG path template"
            }
        }
    }
}

Describe 'env-block relocation preserves the migrated values' {
    BeforeEach { Reset-DFTestSession }
    It 'fzf env carries the fuzzy-finder settings; its base options are the seeded fzfrc' {
        $j = Get-Content (Join-Path $script:RealTools 'fzf.json') -Raw | ConvertFrom-Json
        $j.env.FZF_DEFAULT_COMMAND | Should -Be 'fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
        # Exact match of the options (comments aside) so corruption anywhere is caught. Color
        # flags are in Tools/fzf/catppuccin-mocha.json + Tools/fzf.ps1 -- see fzf.Tests.ps1.
        # Matches the user's zsh config exactly (fuzzy match, not --exact/--no-sort/
        # --cycle) -- see the 2026-09-06 zsh-parity investigation.
        $expectedFzfOpts = @(
            '--layout=reverse'
            '--inline-info'
            '--height=40%'
            '--border'
        )
        @(Get-Content (Join-Path $script:RealTools 'fzf' 'fzfrc') | Where-Object { $_ -notmatch '^\s*#' }) | Should -Be $expectedFzfOpts
        $j.env.FZF_CTRL_T_OPTS  | Should -Be "--preview `"bat -n --color=always {}`" --bind 'ctrl-/:change-preview-window(down|hidden|)'"
    }
    It 'delta carries GIT_PAGER in its diff role block (DELTA_FEATURES moved to the sidecar)' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.roles.diff.env.GIT_PAGER | Should -Be 'delta'
        $j.PSObject.Properties['env'] | Should -BeNullOrEmpty
    }
    It 'less keeps its XDG paths; its flags live in the seeded lesskey, not LESS' {
        $j = Get-Content (Join-Path $script:RealTools 'less.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.LESSHISTFILE | Should -Match '\$\{XDG_STATE_HOME\}'
        $j.xdg.vars.LESSKEYIN    | Should -Match '\$\{XDG_CONFIG_HOME\}'
        $j.xdg.vars.PSObject.Properties['LESS'] | Should -BeNullOrEmpty
        $j.PSObject.Properties['env'] | Should -BeNullOrEmpty
    }
    It 'mdcat moves MDCAT_THEME out of xdg.vars to its theme block and is method default' {
        $j = Get-Content (Join-Path $script:RealTools 'mdcat.json') -Raw | ConvertFrom-Json
        $j.xdg.method     | Should -Be 'default'
        $vars = $j.xdg.PSObject.Properties['vars']?.Value
        if ($vars) { $vars.PSObject.Properties['MDCAT_THEME'] | Should -BeNullOrEmpty }
        $j.theme.env.MDCAT_THEME | Should -Be '{theme}'
        $j.theme.default | Should -Be 'catppuccin-mocha'
    }
}

Describe 'Register applies the migrated env settings (tools without a sidecar)' {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolAvailability = @{}
        $script:SavedFzf   = $Env:FZF_DEFAULT_OPTS
        $script:SavedPager = $Env:GIT_PAGER
        $script:SavedLess  = $Env:LESS
        $script:SavedLessHist = $Env:LESSHISTFILE
        # tool xdg.vars never overwrite a variable that is already set, so start
        # from none (the developer's own profile may have set it)
        Remove-Item Env:\LESSHISTFILE, Env:\LESS, Env:\FZF_DEFAULT_OPTS, Env:\FZF_DEFAULT_OPTS_FILE -ErrorAction Ignore
        Set-DFTestXdg

        $script:SavedGitConfigGlobal = $Env:GIT_CONFIG_GLOBAL


        # Registering delta for real (below) dot-sources the real Tools/delta.setup.ps1,
        # which calls `git config --global`. Redirect it explicitly rather than relying
        # on XDG_CONFIG_HOME alone -- git only falls back to $XDG_CONFIG_HOME/git/config
        # when no ~/.gitconfig exists, so a developer machine that has one would
        # otherwise have this test write into its real global git config.
        $Env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        # These tests fake "installed" with Mock Get-Command / Get-Module; route the PATH and module probes through them.
        Mock Test-DFExecutableOnPath { [bool](Get-Command $Name -ErrorAction Ignore) }
        Mock Test-DFModuleOnPath { [bool](Get-Module -ListAvailable -Name $Name -ErrorAction Ignore) }
    }
    AfterEach {
        $Env:FZF_DEFAULT_OPTS = $script:SavedFzf
        $Env:GIT_PAGER        = $script:SavedPager
        $Env:LESS             = $script:SavedLess
        $Env:LESSHISTFILE     = $script:SavedLessHist

        $Env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal
        Restore-DFTestXdg
    }

    It 'points fzf at its seeded options file; FZF_DEFAULT_OPTS holds no layout' {
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS_FILE | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'fzfrc'))
        $Env:FZF_DEFAULT_OPTS | Should -Not -Match '--layout'
    }
    It 'sets GIT_PAGER from delta.json env' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:GIT_PAGER | Should -Be 'delta'
    }
    It 'leaves LESS unset (the seeded lesskey holds the flags) and still sets the XDG history path' {
        Register-DFTool -Name 'less' -ToolsPath $script:RealTools
        $Env:LESS         | Should -BeNullOrEmpty
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'less' 'lesskey') | Should -BeTrue
        $Env:LESSHISTFILE | Should -Be (Join-Path $Env:XDG_STATE_HOME 'less' 'history')
    }
}
