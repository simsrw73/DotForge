#Requires -Version 7.2
# Every ```powershell block in the user docs parses, and every block not marked
# fragment/interactive/network/system runs, as written, in a fresh pwsh with a throwaway
# home folder: exit code 0, nothing on stderr, and output matching the ```text
# block that follows it. The modes and output rules are documented at the top of
# build/DFDocExamples.ps1. Set $Env:DF_DOCS_NETWORK = '1' to run network blocks too.

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'build' 'DFDocExamples.ps1')
    $docs = @(
        Join-Path $repo 'README.md'
        Join-Path $repo 'examples' 'README.md'
        Get-ChildItem (Join-Path $repo 'docs' 'guide') -Filter '*.md' -ErrorAction Ignore | ForEach-Object FullName
    ) | Where-Object { Test-Path $_ }
    $script:blocks = foreach ($d in $docs) {
        foreach ($b in Get-DFDocCodeBlock -Path $d) {
            @{
                Rel = [IO.Path]::GetRelativePath($repo, $b.File) -replace '\\', '/'
                Line = $b.Line; Code = $b.Code; Mode = $b.Mode; Requires = $b.Requires
                Expected = $b.Expected; OutputVaries = $b.OutputVaries
            }
        }
    }
    $script:runnable = @($script:blocks | Where-Object {
        $_.Mode -eq 'run' -or ($_.Mode -eq 'network' -and $Env:DF_DOCS_NETWORK -eq '1') -or
        ($_.Mode -eq 'requires' -and -not @($_.Requires | Where-Object { -not (Get-Command $_ -CommandType Application -ErrorAction Ignore) }))
    })

    # examples/*.ps1 are whole profiles. A file with a '# docs-test: parse-only'
    # line (interactive walkthroughs) is only parsed; the rest also run.
    $script:profiles = foreach ($f in Get-ChildItem (Join-Path $repo 'examples') -Filter '*.ps1') {
        $text = Get-Content $f.FullName -Raw
        @{ Name = $f.Name; Code = $text; ParseOnly = $text -match '(?m)^#\s*docs-test:\s*parse-only' }
    }
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'build' 'DFDocExamples.ps1')
    $script:sandbox = Join-Path $TestDrive 'docs-sandbox'
    $script:modules = New-DFDocModuleCopy -RepoRoot $repo -Destination (Join-Path $TestDrive 'modules')
    $script:toolVars = Get-DFDocToolVariable -RepoRoot $repo
}

Describe 'Documentation code blocks parse' {
    It '<Rel>:<Line> (<Mode>)' -ForEach $script:blocks {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Example profiles' {
    It '<Name> parses' -ForEach $script:profiles {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It '<Name> runs as a profile' -ForEach @($script:profiles | Where-Object { -not $_.ParseOnly }) {
        # Profiles may bootstrap missing tools; force -WhatIf so nothing is installed.
        $prelude = "`$PSDefaultParameterValues['Install-DFTool:WhatIf'] = `$true`n"
        $r = Invoke-DFDocExample -Code ($prelude + $Code) -ModulesRoot $script:modules -SandboxRoot $script:sandbox -RemoveVariable $script:toolVars
        $r.TimedOut | Should -BeFalse
        $r.StdErr.Trim() | Should -BeNullOrEmpty -Because "stdout was:`n$($r.StdOut)"
        $r.ExitCode | Should -Be 0
    }
}

Describe 'Documentation code blocks run' {
    It '<Rel>:<Line>' -ForEach $script:runnable {
        $r = Invoke-DFDocExample -Code $Code -ModulesRoot $script:modules -SandboxRoot $script:sandbox -RemoveVariable $script:toolVars
        $r.TimedOut | Should -BeFalse -Because 'the example must finish (is it waiting for input? mark it <!-- interactive -->)'
        $r.StdErr.Trim() | Should -BeNullOrEmpty -Because "stdout was:`n$($r.StdOut)"
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.StdOut)"
        if ($null -ne $Expected -and -not $OutputVaries) {
            Compare-DFDocOutput -Expected $Expected -Actual $r.StdOut | Should -BeNullOrEmpty
        }
    }
}
