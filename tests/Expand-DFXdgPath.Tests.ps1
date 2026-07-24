BeforeAll {
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
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

    It 'expands ${XDG_CONFIG_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/bat/bat.conf' | Should -Be 'C:\config\bat\bat.conf'
    }
    It 'expands ${XDG_DATA_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_DATA_HOME}/zoxide' | Should -Be 'C:\data\zoxide'
    }
    It 'expands ${XDG_STATE_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_STATE_HOME}/less/history' | Should -Be 'C:\state\less\history'
    }
    It 'expands ${XDG_CACHE_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_CACHE_HOME}/uv' | Should -Be 'C:\cache\uv'
    }
    It 'collapses a trailing segment to no trailing separator' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/glow/' | Should -Be 'C:\config\glow'
    }
    It 'returns a token-less flag string byte-for-byte' {
        Expand-DFXdgPath '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init' |
            Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
    }
    It 'leaves forward slashes in a token-less string untouched' {
        Expand-DFXdgPath 'fd --type f --exclude .git' | Should -Be 'fd --type f --exclude .git'
    }
}
