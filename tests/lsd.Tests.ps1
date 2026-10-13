BeforeAll {
    $script:LsdJson = Get-Content "$PSScriptRoot/../Tools/lsd.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/lsd.json' {
    It 'unquotes names with spaces in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # lsd's spelling of eza's --no-quotes.
        $script:LsdJson.roles.listing.aliases.$_.args | Should -Contain '--literal'
    }

    It 'does not emit hyperlinks in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        $script:LsdJson.roles.listing.aliases.$_.args | Where-Object { $_ -match '^--hyperlink' } | Should -BeNullOrEmpty
    }

    It 'wraps lsd to pass --config-file only when its XDG config exists' {
        $script:LsdJson.xdg.method | Should -Be 'wrapper'
        $script:LsdJson.wrapper.args[0].ifFile | Should -Be '${XDG_CONFIG_HOME}/lsd/config.yaml'
        $script:LsdJson.wrapper.args[0].args | Should -Be @('--config-file', '{file}')
    }
}
