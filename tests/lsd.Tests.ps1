BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:LsdJson = Get-Content "$PSScriptRoot/../Tools/lsd.json" -Raw | ConvertFrom-Json
    # The aliases DotForge builds for lsd when it wins listing: the role's words, lsd's flags.
    $listing = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['listing']
    $record = Get-DFTestToolRecord 'lsd'
    $script:LsdAliases = Get-DFRoleBehaviorAlias -RoleDefinition $listing -Block $record.roles.listing -Tool $record
}

Describe 'Tools/lsd.json' {
    It 'unquotes names with spaces in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # lsd's spelling of eza's --no-quotes.
        $script:LsdAliases.$_.args | Should -Contain '--literal'
    }

    It 'does not emit hyperlinks in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        $script:LsdAliases.$_.args | Where-Object { $_ -match '^--hyperlink' } | Should -BeNullOrEmpty
    }

    It 'wraps lsd to pass --config-file only when its XDG config exists' {
        $script:LsdJson.xdg.method | Should -Be 'wrapper'
        $script:LsdJson.wrapper.args[0].ifFile | Should -Be '${XDG_CONFIG_HOME}/lsd/config.yaml'
        $script:LsdJson.wrapper.args[0].args | Should -Be @('--config-file', '{file}')
    }
}
