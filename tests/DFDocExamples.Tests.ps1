#Requires -Version 7.2
# Unit tests for build/DFDocExamples.ps1, the logic behind the documentation checks.

BeforeAll {
    . "$PSScriptRoot/../build/DFDocExamples.ps1"
}

Describe 'Get-DFDocCodeBlock' {
    BeforeAll {
        $script:md = Join-Path $TestDrive 'page.md'
        Set-Content -Path $script:md -Value @'
# Page

```powershell
Get-Date
```

```text
any
```

<!-- interactive -->

```powershell
fco
```

<!-- system -->
```powershell
coreutils-manager disable cat
```

```powershell
'a'
```

<!-- output: varies -->
```text
a
```

```bash
ls
```
'@
        $script:blocks = @(Get-DFDocCodeBlock -Path $script:md)
    }

    It 'returns only powershell blocks' {
        $script:blocks.Count | Should -Be 4
    }
    It 'reads the mode from the marker on the line before the fence, blank lines allowed' {
        $script:blocks.Mode | Should -Be @('run', 'interactive', 'system', 'run')
    }
    It 'pairs a directly following text block as expected output' {
        $script:blocks[0].Expected | Should -Be 'any'
        $script:blocks[0].OutputVaries | Should -BeFalse
        $script:blocks[1].Expected | Should -BeNullOrEmpty
    }
    It 'marks output preceded by an output-varies marker as not compared' {
        $script:blocks[3].Expected | Should -Be 'a'
        $script:blocks[3].OutputVaries | Should -BeTrue
    }
    It 'reads a requires marker as the programs the block needs' {
        $page = Join-Path $TestDrive 'requires.md'
        Set-Content -Path $page -Value @'
<!-- requires: eza, lsd -->
```powershell
ls
```

```powershell
'plain'
```
'@
        $found = @(Get-DFDocCodeBlock -Path $page)
        $found[0].Mode | Should -Be 'requires'
        $found[0].Requires | Should -Be @('eza', 'lsd')
        $found[1].Mode | Should -Be 'run'
        $found[1].Requires | Should -BeNullOrEmpty
    }
    It 'records the 1-based line of the opening fence' {
        $script:blocks[0].Line | Should -Be 3
    }
}

Describe 'Compare-DFDocOutput' {
    It 'matches identical text, ignoring CRLF, ANSI and trailing whitespace' {
        Compare-DFDocOutput -Expected "a`nb" -Actual "`e[1ma`e[0m  `r`nb`r`n" | Should -BeNullOrEmpty
    }
    It 'treats a whole "..." line as any number of lines' {
        Compare-DFDocOutput -Expected "a`n...`nd" -Actual "a`nb`nc`nd" | Should -BeNullOrEmpty
        Compare-DFDocOutput -Expected "a`n...`nd" -Actual "a`nd" | Should -BeNullOrEmpty
    }
    It 'treats "..." inside a line as any text on that line' {
        Compare-DFDocOutput -Expected 'Path: ...\bin' -Actual 'Path: C:\Users\x\bin' | Should -BeNullOrEmpty
    }
    It 'is case-sensitive and reports a difference' {
        Compare-DFDocOutput -Expected 'Ready' -Actual 'ready' | Should -Match 'Output differs'
    }
    It 'does not let an inline "..." span lines' {
        Compare-DFDocOutput -Expected 'a...z' -Actual "a`nz" | Should -Match 'Output differs'
    }
}

Describe 'Get-DFDocHeadingSlug' {
    It 'produces GitHub-style anchors, numbering duplicates and skipping code fences' {
        $md = Join-Path $TestDrive 'slugs.md'
        Set-Content -Path $md -Value @'
# Getting started
## The `$DFConfig` table
## Notes
```text
# not a heading
```
## Notes
<a id="custom-anchor"></a>
'@
        Get-DFDocHeadingSlug -Path $md | Should -Be @('getting-started', 'the-dfconfig-table', 'notes', 'notes-1', 'custom-anchor')
    }
}

Describe 'Get-DFDocLink' {
    It 'returns relative links and images, not URLs or code spans' {
        $md = Join-Path $TestDrive 'links.md'
        Set-Content -Path $md -Value @'
See [setup](guide/setup.md#install), [web](https://example.com), and `[x](not-a-link.md)`.
<img src="assets/logo.png" alt="logo">
[here](#local)
'@
        $links = @(Get-DFDocLink -Path $md)
        $links.Target | Should -Be @('guide/setup.md#install', 'assets/logo.png', '#local')
        $links[0].Anchor | Should -Be 'install'
        $links[2].TargetPath | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFDocExample' {
    It 'runs in a throwaway home with no XDG or tool variables and a private git config' {
        $repo = Split-Path $PSScriptRoot -Parent
        $modules = New-DFDocModuleCopy -RepoRoot $repo -Destination (Join-Path $TestDrive 'modules')
        $Env:DF_DOC_PROBE = 'leak'
        $code = '"home=$HOME"; "xdg=$Env:XDG_CONFIG_HOME"; "git=$Env:GIT_CONFIG_GLOBAL"; "probe=$Env:DF_DOC_PROBE"; (Get-Module -ListAvailable DotForge).ModuleBase'
        $r = Invoke-DFDocExample -Code $code -ModulesRoot $modules -SandboxRoot (Join-Path $TestDrive 'box') -RemoveVariable 'DF_DOC_PROBE'
        Remove-Item Env:DF_DOC_PROBE
        $r.ExitCode | Should -Be 0
        $out = $r.StdOut -split "`r?`n"
        $out[0] | Should -BeLike "home=$TestDrive*"
        $out[1] | Should -Be 'xdg='
        $out[2] | Should -BeLike "git=$TestDrive*"
        $out[3] | Should -Be 'probe='
        ($out | Where-Object { $_ -like '*DotForge*' } | Select-Object -First 1) | Should -BeLike "$TestDrive*"
    }
    It 'captures non-ASCII output intact, whatever the console code page' {
        # The test runner's console may be code page 437, which has no em dash.
        $r = Invoke-DFDocExample -Code ('"a ' + [char]0x2014 + ' b"') -ModulesRoot $TestDrive -SandboxRoot (Join-Path $TestDrive 'box2')
        ($r.StdOut -split "`r?`n")[0] | Should -Be ('a ' + [char]0x2014 + ' b')
    }
}
