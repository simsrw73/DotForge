BeforeAll {
    . "$PSScriptRoot/../build/DFToolVariables.ps1"
    $script:Names = @(Get-DFToolVariableName -ToolsPath "$PSScriptRoot/../Tools" -RolesPath "$PSScriptRoot/../data/roles.json")
}

# build/Test-DFFull.ps1 clears every variable DotForge's tools set, so a test can't pass only
# because the developer's shell already ran DotForge.
Describe 'Get-DFToolVariableName' {
    It 'lists record variables: env, xdg.vars, role env and theme env' {
        foreach ($name in 'FZF_DEFAULT_COMMAND', 'LESSHISTFILE', 'Picker', 'BAT_THEME', 'GIT_PAGER') { $script:Names | Should -Contain $name }
    }
    It 'lists role-level variables from roles.json' {
        foreach ($name in 'PAGER', 'BAT_PAGER') { $script:Names | Should -Contain $name }
    }
    It 'lists variables companions set in code' {
        foreach ($name in 'LS_COLORS', 'FZF_DEFAULT_OPTS', 'FZF_DEFAULT_OPTS_FILE', 'SKIM_DEFAULT_OPTIONS', 'STARSHIP_CONFIG', 'CARAPACE_BRIDGES') { $script:Names | Should -Contain $name }
    }
    It 'never lists the XDG folders, Path, or the gate''s own variables' {
        $script:Names | Where-Object { $_ -like 'XDG_*' -or $_ -eq 'Path' -or $_ -like 'DF_TEST_*' } | Should -BeNullOrEmpty
    }
}
