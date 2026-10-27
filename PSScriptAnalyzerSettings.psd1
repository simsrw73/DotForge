# PSScriptAnalyzer settings for everything but tests/ (which has its own file).
# build/Invoke-DFLint.ps1 reads it, and so does the VS Code PowerShell extension.
# Every default rule runs. Exclude a rule only for a reason that holds everywhere;
# a single deliberate exception gets [Diagnostics.CodeAnalysis.SuppressMessage]
# with a justification, next to the code. Plan: docs/STATIC-ANALYSIS-PLAN.md.
@{
    ExcludeRules = @(
        # A BOM matters only to Windows PowerShell 5.1, which reads BOM-less files
        # as ANSI. DotForge requires PowerShell 7, which reads UTF-8 either way.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
