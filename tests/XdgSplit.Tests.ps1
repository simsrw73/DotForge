BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'xdg.vars is path-templates-only after the split' {
    It 'tool <Name> has no non-XDG value in xdg.vars' -ForEach @(
        @{ Name = 'fzf' }, @{ Name = 'delta' }, @{ Name = 'less' }, @{ Name = 'mdcat' }
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
    It 'fzf env carries the fuzzy-finder settings' {
        $j = Get-Content (Join-Path $script:RealTools 'fzf.json') -Raw | ConvertFrom-Json
        $j.env.FZF_DEFAULT_COMMAND | Should -Be 'fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
        # Exact full-value match so corruption anywhere in the multiline opts is caught
        # (JSON \n decodes to LF, so compare against a `n-joined string). Color flags
        # moved to Tools/fzf/catppuccin-mocha.json + Tools/fzf.ps1 -- see fzf.Tests.ps1.
        # Matches the user's zsh config exactly (fuzzy match, not --exact/--no-sort/
        # --cycle) -- see the 2026-09-06 zsh-parity investigation.
        $expectedFzfOpts = @(
            '--layout=reverse'
            '--inline-info'
            '--height=40%'
            '--border'
        ) -join "`n"
        $j.env.FZF_DEFAULT_OPTS | Should -Be $expectedFzfOpts
        $j.env.FZF_CTRL_T_OPTS  | Should -Be "--preview `"bat -n --color=always {}`" --bind 'ctrl-/:change-preview-window(down|hidden|)'"
    }
    It 'delta env carries GIT_PAGER (DELTA_FEATURES moved to the sidecar)' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.env.GIT_PAGER | Should -Be 'delta'
        $j.env.PSObject.Properties['DELTA_FEATURES'] | Should -BeNullOrEmpty
    }
    It 'less keeps its XDG paths and moves LESS to env' {
        $j = Get-Content (Join-Path $script:RealTools 'less.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.LESSHISTFILE | Should -Match '\$\{XDG_STATE_HOME\}'
        $j.xdg.vars.LESSKEY      | Should -Match '\$\{XDG_CONFIG_HOME\}'
        $j.xdg.vars.PSObject.Properties['LESS'] | Should -BeNullOrEmpty
        $j.env.LESS | Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
    }
    It 'mdcat moves MDCAT_THEME to env and is method default' {
        $j = Get-Content (Join-Path $script:RealTools 'mdcat.json') -Raw | ConvertFrom-Json
        $j.xdg.method     | Should -Be 'default'
        $j.env.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
}

Describe 'Register applies the migrated env settings (tools without a sidecar)' {
    BeforeEach {
        $script:DFToolAvailability = @{}
        $script:SavedFzf   = $Env:FZF_DEFAULT_OPTS
        $script:SavedPager = $Env:GIT_PAGER
        $script:SavedLess  = $Env:LESS
        $script:SavedState = $Env:XDG_STATE_HOME
        $script:SavedCfg   = $Env:XDG_CONFIG_HOME
        $script:SavedGitConfigGlobal = $Env:GIT_CONFIG_GLOBAL
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        # Registering delta for real (below) dot-sources the real Tools/delta.setup.ps1,
        # which calls `git config --global`. Redirect it explicitly rather than relying
        # on XDG_CONFIG_HOME alone -- git only falls back to $XDG_CONFIG_HOME/git/config
        # when no ~/.gitconfig exists, so a developer machine that has one would
        # otherwise have this test write into its real global git config.
        $Env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
    }
    AfterEach {
        $Env:FZF_DEFAULT_OPTS = $script:SavedFzf
        $Env:GIT_PAGER        = $script:SavedPager
        $Env:LESS             = $script:SavedLess
        $Env:XDG_STATE_HOME   = $script:SavedState
        $Env:XDG_CONFIG_HOME  = $script:SavedCfg
        $Env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal
    }

    It 'sets FZF_DEFAULT_OPTS from fzf.json env' {
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match '--layout=reverse'
    }
    It 'sets GIT_PAGER from delta.json env' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:GIT_PAGER | Should -Be 'delta'
    }
    It 'sets LESS from less.json env and still sets the XDG history path' {
        Register-DFTool -Name 'less' -ToolsPath $script:RealTools
        $Env:LESS         | Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
        $Env:LESSHISTFILE | Should -Be (Join-Path $Env:XDG_STATE_HOME 'less' 'history')
    }
}
