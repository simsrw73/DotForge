#Requires -Version 7.2
<#
.SYNOPSIS
    Runs PSScriptAnalyzer over DotForge's tracked scripts and summarizes the findings. Informational: never fails.
.DESCRIPTION
    Analyzes every tracked .ps1, .psm1 and .psd1 file (git ls-files, so ignored
    folders are never walked), except the generated Bundle/. Files under tests/
    use tests/PSScriptAnalyzerSettings.psd1; everything else uses the repo's
    PSScriptAnalyzerSettings.psd1. Each finding is counted in one area:
    Shipped (what the module loads), Build (build/, examples/, Publish-*) or
    Tests. Prints one row per rule, most findings first, with a Total row. The
    script exits 0 whatever it finds; docs/STATIC-ANALYSIS-PLAN.md says in
    which order to bring the counts down.
.PARAMETER Path
    Files or folders to analyze, relative to the repo root or absolute. Default: the whole repo.
.PARAMETER Rule
    Only these rules (without the PS prefix, wildcards allowed): -Rule AvoidUsingEmptyCatchBlock.
.PARAMETER Detailed
    Emit each finding (area, rule, file, line, message) instead of the summary.
.PARAMETER MarkdownPath
    Also append the summary to this file as Markdown. CI passes $Env:GITHUB_STEP_SUMMARY.
.EXAMPLE
    pwsh -NoProfile -File build/Invoke-DFLint.ps1

    The summary for the whole repo, one row per rule.
.EXAMPLE
    pwsh -NoProfile -Command "./build/Invoke-DFLint.ps1 -Path Private -Rule AvoidUsingEmptyCatchBlock -Detailed"

    Every empty catch block in Private/, with file and line, to work through one rule.
.OUTPUTS
    One object per rule (Rule, Severity, Shipped, Build, Tests, Files), or with -Detailed one per finding.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string[]]$Rule,
    [switch]$Detailed,
    [string]$MarkdownPath
)

$repo = Split-Path $PSScriptRoot -Parent
$version = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')).PSScriptAnalyzer
Import-Module PSScriptAnalyzer -RequiredVersion $version -ErrorAction Stop

$settingsByArea = @{
    Shipped = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
    Build   = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
    Tests   = Join-Path $repo 'tests' 'PSScriptAnalyzerSettings.psd1'
}

function Get-LintArea([string]$Relative) {
    if ($Relative -match '^tests/') { return 'Tests' }
    if ($Relative -match '^(build|examples)/|^Publish-') { return 'Build' }
    'Shipped'
}

function Get-LintFile {
    # Pathspecs relative to the repo root, so -Path works from any folder.
    # Always an array: splatting a lone string passes its characters, one pathspec each.
    $pathspecs = @(if ($Path) {
        foreach ($p in $Path) { [IO.Path]::GetRelativePath($repo, [IO.Path]::GetFullPath($p, (Get-Location).Path)) }
    } else { '.' })
    @(git -C $repo ls-files -- @pathspecs) | Where-Object { $_ -match '\.ps[dm]?1$' -and $_ -notmatch '^Bundle/' }
}

function Invoke-LintFile([string]$Relative) {
    $area = Get-LintArea $Relative
    foreach ($record in Invoke-ScriptAnalyzer -Path (Join-Path $repo $Relative) -Settings $settingsByArea[$area]) {
        $name = $record.RuleName -replace '^PS'
        if ($Rule -and -not @($Rule | Where-Object { $name -like $_ }).Count) { continue }
        [pscustomobject]@{
            Area     = $area
            Rule     = $name
            Severity = [string]$record.Severity
            File     = $Relative
            Line     = $record.Line
            Message  = $record.Message
        }
    }
}

function Get-LintSummary([object[]]$Findings) {
    $rows = foreach ($group in $Findings | Group-Object Rule) {
        [pscustomobject]@{
            Rule     = $group.Name
            Severity = $group.Group[0].Severity
            Shipped  = @($group.Group | Where-Object Area -eq 'Shipped').Count
            Build    = @($group.Group | Where-Object Area -eq 'Build').Count
            Tests    = @($group.Group | Where-Object Area -eq 'Tests').Count
            Files    = @($group.Group.File | Sort-Object -Unique).Count
        }
    }
    $rows = @($rows | Sort-Object { -($_.Shipped + $_.Build + $_.Tests) }, Rule)
    $rows + [pscustomobject]@{
        Rule     = 'Total'
        Severity = ''
        Shipped  = @($Findings | Where-Object Area -eq 'Shipped').Count
        Build    = @($Findings | Where-Object Area -eq 'Build').Count
        Tests    = @($Findings | Where-Object Area -eq 'Tests').Count
        Files    = @($Findings.File | Sort-Object -Unique).Count
    }
}

function ConvertTo-LintMarkdown([object[]]$Summary, [object[]]$Findings, [int]$FileCount) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## PSScriptAnalyzer (informational)')
    $lines.Add('')
    $lines.Add("$FileCount files analyzed. Order of work: docs/STATIC-ANALYSIS-PLAN.md.")
    $lines.Add('')
    $lines.Add('| Rule | Severity | Shipped | Build | Tests | Files |')
    $lines.Add('|---|---|---:|---:|---:|---:|')
    foreach ($row in $Summary) {
        $lines.Add("| $($row.Rule) | $($row.Severity) | $($row.Shipped) | $($row.Build) | $($row.Tests) | $($row.Files) |")
    }
    $lines.Add('')
    $lines.Add('Files with the most findings:')
    $lines.Add('')
    foreach ($group in $Findings | Group-Object File | Sort-Object Count -Descending | Select-Object -First 10) {
        $lines.Add("- ``$($group.Name)``: $($group.Count)")
    }
    $lines -join "`n"
}

$files = @(Get-LintFile)
$findings = @(foreach ($relative in $files) { Invoke-LintFile $relative })

if ($Detailed) {
    $findings | Sort-Object Area, Rule, File, Line
} else {
    $summary = Get-LintSummary $findings
    $summary
}
if ($MarkdownPath) {
    Add-Content -Path $MarkdownPath -Value (ConvertTo-LintMarkdown (Get-LintSummary $findings) $findings $files.Count)
}
