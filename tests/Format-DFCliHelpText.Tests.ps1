BeforeAll {
    . "$PSScriptRoot/../Private/Format-DFCliHelpText.ps1"
    $script:HEADER = "`e[1;33m"
    $script:FAINT  = "`e[2m"
    $script:RESET  = "`e[0m"
}

Describe 'Format-DFCliHelpText' {
    It 'returns text unchanged when Color is false' {
        $t = "USAGE`n  -f  do it"
        Format-DFCliHelpText -Text $t -Color $false | Should -BeExactly $t
    }

    It 'returns empty string unchanged' {
        Format-DFCliHelpText -Text '' -Color $true | Should -BeExactly ''
    }

    It 'colors an ALL-CAPS header at start of file' {
        $out = Format-DFCliHelpText -Text "USAGE`nstuff" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "$HEADER`USAGE$RESET"
    }

    It 'colors an ALL-CAPS header preceded by a blank line' {
        $out = Format-DFCliHelpText -Text "intro`n`nGLOBAL OPTIONS`nx" -Color $true
        ($out -split "`n")[2] | Should -BeExactly "$HEADER`GLOBAL OPTIONS$RESET"
    }

    It 'colors a header ending in a colon' {
        $out = Format-DFCliHelpText -Text "Options:`n  -h" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "$HEADER`Options:$RESET"
    }

    It 'does NOT color an indented colon line' {
        $out = Format-DFCliHelpText -Text "intro`n`n  Options:`n" -Color $true
        ($out -split "`n")[2] | Should -BeExactly '  Options:'
    }

    It 'does NOT color a header-looking line that is not preceded by a blank line' {
        $out = Format-DFCliHelpText -Text "foo`nBAR" -Color $true
        ($out -split "`n")[1] | Should -BeExactly 'BAR'
    }

    It 'faintly tints only the flag portion of an option line' {
        $out = Format-DFCliHelpText -Text "  -f, --force   overwrite" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "  $FAINT-f, --force`e[22m   overwrite"
    }

    It 'tints a lone flag with no description' {
        $out = Format-DFCliHelpText -Text "  --version" -Color $true
        ($out -split "`n")[0] | Should -BeExactly "  $FAINT--version`e[22m"
    }
}
