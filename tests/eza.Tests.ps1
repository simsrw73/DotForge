BeforeAll {
    $script:EzaJson = Get-Content "$PSScriptRoot/../Tools/eza.json" -Raw | ConvertFrom-Json

    # eza declares these with an optional value (`--icons [<WHEN>]`). Written
    # bare, clap fills the empty slot from the next positional -- so a bare
    # occurrence anywhere in an alias's args can swallow a caller's path.
    # Binding the value with `=` leaves nothing for clap to fill.
    $script:OptionalValueFlags = @('--color', '--icons', '--hyperlink')
}

Describe 'Tools/eza.json' {
    It 'binds a value to every optional-value flag in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # Regression (4d29177): appending a bare `--hyperlink` to each alias
        # made `ll .` fail with "invalid value '.' for '--hyperlink [<WHEN>]'".
        $aliasArgs = $script:EzaJson.aliases.$_.args
        foreach ($flag in $script:OptionalValueFlags) {
            $aliasArgs | Should -Not -Contain $flag -Because "$flag must be written as ${flag}=<when> so it cannot consume a path"
        }
    }

    It 'passes a path through as a positional for alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # Guards the whole arg list, not just the known optional-value flags:
        # no arg may be left able to absorb the trailing path.
        $aliasArgs = @($script:EzaJson.aliases.$_.args)
        $trailing = $aliasArgs[-1]
        $trailing | Should -Match '^--[a-z-]+(=.+)?$' -Because 'trailing args must be a bound flag or a pure boolean'
        $script:OptionalValueFlags | Should -Not -Contain $trailing -Because "a trailing bare $trailing would capture the caller's path"
    }
}
