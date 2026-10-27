# PSScriptAnalyzer settings for tests/: the repo's settings plus the rules a stub
# breaks by design. Stubs take the name of what they stand in for (a function
# `oh-my-posh`, `Set-PsFzfOption`), so naming rules don't apply. Everything that
# catches real mistakes stays on, globals and unused variables included: tests
# have shipped bugs that strict checking would have caught.
@{
    ExcludeRules = @(
        'PSUseBOMForUnicodeEncodedFile'                # as in ../PSScriptAnalyzerSettings.psd1
        'PSUseApprovedVerbs'                           # stubs named after executables
        'PSUseSingularNouns'                           # stubs named after real commands
        'PSUseShouldProcessForStateChangingFunctions'  # stubs of New-/Set- commands
    )
}
