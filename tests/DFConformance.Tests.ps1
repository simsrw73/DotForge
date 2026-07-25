BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../build/DFConformance.ps1"
}

Describe 'Expand-DFConformanceToken' {
    It 'expands ${SCRATCH} to the scratch dir via literal replace' {
        Expand-DFConformanceToken -Value '${SCRATCH}/bat.conf' -Scratch 'C:\tmp\s' |
            Should -Be 'C:\tmp\s/bat.conf'
    }
    It 'delegates ${XDG_CONFIG_HOME} to Expand-DFXdgPath' {
        $Env:XDG_CONFIG_HOME = 'C:\cfg'
        Expand-DFConformanceToken -Value '${XDG_CONFIG_HOME}/glow' -Scratch 'C:\tmp\s' |
            Should -Be 'C:\cfg\glow'
    }
    It 'passes a token-less literal through unchanged' {
        Expand-DFConformanceToken -Value '--theme=ansi' -Scratch 'C:\tmp\s' |
            Should -Be '--theme=ansi'
    }
}

Describe 'Read-DFConformanceFragment' {
    It 'strips // comments and parses JSON' {
        $p = Join-Path $TestDrive 'f.jsonc'
        @'
{
  // a comment
  "tool": "bat",
  "claims": []
}
'@ | Set-Content $p
        (Read-DFConformanceFragment -Path $p).tool | Should -Be 'bat'
    }
}

Describe 'Test-DFConformanceDescriptor' {
    It 'accepts a valid env-then-spawn descriptor' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:BAT_CONFIG_PATH'; probe = [pscustomobject]@{
                kind = 'env-then-spawn'; setEnv = [pscustomobject]@{ BAT_CONFIG_PATH = '${SCRATCH}/bat.conf' };
                spawn = @('bat','--config-file'); expect = [pscustomobject]@{ contains = '${SCRATCH}' } } }
        ) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Not -Throw
    }
    It 'rejects a fragment with no tool field (StrictMode-safe)' {
        $frag = [pscustomobject]@{ claims = @() }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*'tool' field*"
    }
    It 'rejects an unknown probe kind' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:X'; probe = [pscustomobject]@{ kind = 'wat' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*kind*'
    }
    It 'rejects a spawn kind missing expect (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-flag:-s'; probe = [pscustomobject]@{
                kind = 'flag-then-spawn'; spawn = @('bat','-s') } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*exactly one*expect*rule*"
    }
    It 'rejects a spawn kind claim with no spawn key (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:X'; probe = [pscustomobject]@{
                kind = 'env-then-spawn'; expect = [pscustomobject]@{ contains = 'x' } } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*'spawn'*"
    }
    It 'rejects a manual claim with no retest (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-flag:--config'; probe = [pscustomobject]@{ kind = 'manual' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*needs a 'retest' string*"
    }
    It 'rejects a code claim with no ref (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-config-read:x'; probe = [pscustomobject]@{ kind = 'code' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*'ref'*"
    }
    It 'rejects a claim id that violates the grammar' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'BAT/Honors-Env'; probe = [pscustomobject]@{
                kind = 'manual'; retest = 'x' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*id*'
    }
}
