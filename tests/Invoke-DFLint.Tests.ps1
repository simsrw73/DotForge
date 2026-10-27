#Requires -Version 7.2
# build/Invoke-DFLint.ps1: PSScriptAnalyzer over the tracked scripts, informational only.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Lint = Join-Path $script:Repo 'build' 'Invoke-DFLint.ps1'
}

Describe 'PSScriptAnalyzer settings' {
    It 'tests/ excludes every rule the repo settings exclude' {
        $repoRules = (Import-PowerShellDataFile (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1')).ExcludeRules
        $testRules = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')).ExcludeRules
        foreach ($rule in $repoRules) { $testRules | Should -Contain $rule }
    }
}

Describe 'Invoke-DFLint.ps1' {
    It 'analyzes only the one file it is given, and counts it in its area' {
        # One -Path once splatted as characters, so git listed nothing.
        $summary = @(& $script:Lint -Path (Join-Path $script:Repo 'Private' 'Start-DFModulePrewarm.ps1'))
        $total = $summary[-1]
        $total.Rule | Should -Be 'Total'
        $total.Files | Should -Be 1
        $total.Tests | Should -Be 0
        $total.Shipped | Should -BeGreaterThan 0
    }
    It 'keeps only the rules -Rule names, and -Detailed gives each finding' {
        $findings = @(& $script:Lint -Path (Join-Path $script:Repo 'Private' 'Start-DFModulePrewarm.ps1') -Rule 'AvoidUsingEmpty*' -Detailed)
        $findings.Count | Should -BeGreaterThan 0
        $findings.Rule | Sort-Object -Unique | Should -Be 'AvoidUsingEmptyCatchBlock'
        $findings[0].File | Should -Be 'Private/Start-DFModulePrewarm.ps1'
        $findings[0].Area | Should -Be 'Shipped'
    }
}
