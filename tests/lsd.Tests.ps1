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
}
