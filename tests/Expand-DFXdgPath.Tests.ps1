BeforeAll {
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
}

Describe 'Expand-DFXdgPath' {
    BeforeEach {
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedDataHome   = $Env:XDG_DATA_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME = 'C:\config'
        $Env:XDG_DATA_HOME   = 'C:\data'
        $Env:XDG_STATE_HOME  = 'C:\state'
        $Env:XDG_CACHE_HOME  = 'C:\cache'
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_DATA_HOME   = $script:SavedDataHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
    }

    It 'expands ${XDG_CONFIG_HOME}' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/bat/bat.conf' |
            Should -Be 'C:\config/bat/bat.conf'
    }

    It 'expands ${XDG_DATA_HOME}' {
        Expand-DFXdgPath '${XDG_DATA_HOME}/zoxide' |
            Should -Be 'C:\data/zoxide'
    }

    It 'expands ${XDG_STATE_HOME}' {
        Expand-DFXdgPath '${XDG_STATE_HOME}/less/history' |
            Should -Be 'C:\state/less/history'
    }

    It 'expands ${XDG_CACHE_HOME}' {
        Expand-DFXdgPath '${XDG_CACHE_HOME}/uv' | Should -Be 'C:\cache/uv'
    }

    It 'passes through strings with no placeholders unchanged' {
        Expand-DFXdgPath 'C:\absolute\path' | Should -Be 'C:\absolute\path'
    }

    It 'expands multiple placeholders in one string' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/tool and ${XDG_CACHE_HOME}/tool' |
            Should -Be 'C:\config/tool and C:\cache/tool'
    }
}
