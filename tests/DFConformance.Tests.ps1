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
    It 'rejects a fragment with a tool but no claims key at all (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat' }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw "*no 'claims' array*"
    }
    It 'rejects a claim with no id key at all (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ probe = [pscustomobject]@{ kind = 'manual'; retest = 'x' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*violates the id grammar*'
    }
    It 'rejects a present probe object with no kind key at all (StrictMode-safe)' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:X'; probe = [pscustomobject]@{
                spawn = @('bat') } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*unknown probe kind*'
    }
}

Describe 'Get-DFToolVersion' {
    It 'returns the first semver-looking token from --version output' {
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='bat 0.24.0 (a1b2c3)'; StdErr=''; Absent=$false } }
        Get-DFToolVersion -Exe 'bat' -SpawnTool $spawn | Should -Be '0.24.0'
    }
    It 'returns $null when the tool is absent' {
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        Get-DFToolVersion -Exe 'nope' -SpawnTool $spawn | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFConformanceProbe' {
    BeforeEach { $script:scratch = Join-Path $TestDrive ([guid]::NewGuid().Guid)
                 New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null }

    It 'env-then-spawn: PASS when combined output contains the expected substring' {
        $claim = [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ BAT_CONFIG_PATH='${SCRATCH}/bat.conf' };
            writeFile=[pscustomobject]@{ '${SCRATCH}/bat.conf'='--theme="ansi"' };
            spawn=@('bat','--config-file'); expect=[pscustomobject]@{ contains='${SCRATCH}' } } }
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut="$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'pass'
    }
    It 'env-then-spawn: FAIL when output lacks the expected substring' {
        $claim = [pscustomobject]@{ id='glow/honors-env:GLOW_CONFIG_DIR'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ GLOW_CONFIG_DIR='${SCRATCH}' };
            spawn=@('glow','--help'); expect=[pscustomobject]@{ contains='${SCRATCH}' } } }
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='config default C:\Users\me\AppData\glow'; StdErr=''; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'fail'
    }
    It 'manual: passes the descriptor verdict and retest through' {
        $claim = [pscustomobject]@{ id='glow/honors-flag:--config'; probe=[pscustomobject]@{
            kind='manual'; retest='run glow config; confirm file path' } }
        $spawn = { throw 'manual must not spawn' }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'manual'
        $r.retest  | Should -Match 'glow config'
    }
    It 'writeFile writes the sentinel into the scratch dir before spawning' {
        $claim = [pscustomobject]@{ id='bat/honors-config-read'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ BAT_CONFIG_PATH='${SCRATCH}/bat.conf' };
            writeFile=[pscustomobject]@{ '${SCRATCH}/bat.conf'='--not-a-real-flag' };
            spawn=@('bat','x'); expect=[pscustomobject]@{ contains='error' } } }
        $script:seen = $null
        $spawn = { param($e,$a,$env,$cwd)
            $script:seen = Get-Content (Join-Path $script:scratch 'bat.conf') -Raw
            @{ ExitCode=1; StdOut=''; StdErr='error: unexpected argument'; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'pass'
        $script:seen | Should -Be '--not-a-real-flag'
    }
    It 'returns unknown when the seam reports the tool absent' {
        $claim = [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ BAT_CONFIG_PATH='${SCRATCH}/bat.conf' };
            spawn=@('bat','--config-file'); expect=[pscustomobject]@{ contains='${SCRATCH}' } } }
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'unknown'
    }
    It 'handles a single-element spawn array without a StrictMode index error' {
        $claim = [pscustomobject]@{ id='bat/honors-config-read'; probe=[pscustomobject]@{
            kind='env-then-spawn'; spawn=@('bat'); expect=[pscustomobject]@{ contains='ok' } } }
        $script:gotArgv = $null
        $spawn = { param($e,$a,$env,$cwd) $script:gotArgv = $a; @{ ExitCode=0; StdOut='ok'; StdErr=''; Absent=$false } }
        # A direct call: if the slice throws under StrictMode, the It errors and fails.
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'pass'
        @($script:gotArgv).Count | Should -Be 0
    }
}

Describe 'Test-DFConformanceExpect' {
    It 'match: true when the regex matches, false when it does not' {
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ match='fo+' }) -Text 'foo bar' -Scratch 'x' | Should -BeTrue
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ match='zzz' }) -Text 'foo bar' -Scratch 'x' | Should -BeFalse
    }
    It 'notMatch: false when the regex matches, true when it does not' {
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ notMatch='fo+' }) -Text 'foo bar' -Scratch 'x' | Should -BeFalse
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ notMatch='zzz' }) -Text 'foo bar' -Scratch 'x' | Should -BeTrue
    }
    It 'contains: literal substring present/absent' {
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ contains='bar' }) -Text 'foo bar' -Scratch 'x' | Should -BeTrue
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ contains='baz' }) -Text 'foo bar' -Scratch 'x' | Should -BeFalse
    }
    It 'notContains: literal substring present/absent' {
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ notContains='bar' }) -Text 'foo bar' -Scratch 'x' | Should -BeFalse
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ notContains='baz' }) -Text 'foo bar' -Scratch 'x' | Should -BeTrue
    }
    It 'expands ${SCRATCH} in the expected value before comparing' {
        Test-DFConformanceExpect -Expect ([pscustomobject]@{ contains='${SCRATCH}' }) `
            -Text 'path is C:\tmp\scr\x' -Scratch 'C:\tmp\scr' | Should -BeTrue
    }
}

Describe 'code probe: bat.theme' {
    BeforeEach { $script:scratch = Join-Path $TestDrive ([guid]::NewGuid().Guid)
                 New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null }

    It 'PASS when the two theme configs yield different rendered output' {
        # The probe passes a different BAT_CONFIG_PATH per theme (bat.ansi.conf vs
        # bat.Dracula.conf); a real bat renders differently, so mirror the path into StdOut.
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut="rendered:$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        $out = & "$PSScriptRoot/../build/conformance/probes/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn
        $out.verdict | Should -Be 'pass'
    }
    It 'falls back to manual when the two renders are identical' {
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='same'; StdErr=''; Absent=$false } }
        $out = & "$PSScriptRoot/../build/conformance/probes/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn
        $out.verdict | Should -Be 'manual'
        $out.retest  | Should -Not -BeNullOrEmpty
    }
    It 'reports unknown when bat is absent' {
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        (& "$PSScriptRoot/../build/conformance/probes/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn).verdict |
            Should -Be 'unknown'
    }
}

Describe 'Merge-DFConformanceRecord' {
    It 'overwrites automated claims with fresh results' {
        $existing = [pscustomobject]@{ versionTested='0.23.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='fail'; kind='env-then-spawn'; evidence='old' }) }
        $fresh = @( @{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='new'; retest=$null } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Claims | Where-Object id -eq 'bat/honors-env:BAT_CONFIG_PATH').verdict | Should -Be 'pass'
    }
    It 'preserves a manual verdict when versionTested is unchanged' {
        $existing = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code';
                evidence='confirmed visually 2026-07-24'; retest='...' }) }
        $fresh = @( @{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='generic'; retest='...' } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Claims | Where-Object id -eq 'bat/honors-config-content:theme').evidence |
            Should -Be 'confirmed visually 2026-07-24'
    }
    It 'flags a manual verdict for re-confirmation when the version moved' {
        $existing = [pscustomobject]@{ versionTested='0.23.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code';
                evidence='confirmed 0.23.0'; retest='...' }) }
        $fresh = @( @{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='generic'; retest='...' } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Notes -join ' ') | Should -Match 'reconfirm'
    }
    It 'handles a null Existing (no prior ledger) without error' {
        $fresh = @( @{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='x'; retest=$null } )
        $m = Merge-DFConformanceRecord -Existing $null -FreshClaims $fresh -Version '0.24.0'
        @($m.Claims).Count | Should -Be 1
        @($m.Notes).Count  | Should -Be 0
    }
}

Describe 'Test-DFConformanceLedgerSchema' {
    It 'accepts a well-formed ledger' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Not -Throw
    }
    It 'rejects a record with no versionTested key at all (StrictMode-safe)' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ claims=@(
            [pscustomobject]@{ id='bat/honors-env:X'; verdict='pass'; kind='env-then-spawn'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Throw '*missing versionTested*'
    }
    It 'rejects a manual claim with no retest key at all (StrictMode-safe)' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Throw '*needs a retest string*'
    }
    It 'rejects a verdict outside the enum' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:X'; verdict='maybe'; kind='env-then-spawn'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Throw '*invalid verdict*'
    }
}

Describe 'Get-DFConformanceAdapterLink' {
    It 'finds "adapter for CLAIM-ID" comments in Tools/*.ps1' {
        $tools = Join-Path $TestDrive 'Tools'; New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Set-Content (Join-Path $tools 'glow.ps1') "# adapter for glow/honors-env:GLOW_CONFIG_DIR`n`$x = 1"
        $links = @(Get-DFConformanceAdapterLink -ToolsPath $tools)
        $links[0].Claim | Should -Be 'glow/honors-env:GLOW_CONFIG_DIR'
        $links[0].File  | Should -Match 'glow\.ps1'
    }
    It 'returns an empty collection when no adapter comments exist' {
        $tools = Join-Path $TestDrive 'ToolsEmpty'; New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Set-Content (Join-Path $tools 'plain.ps1') "`$x = 1"
        @(Get-DFConformanceAdapterLink -ToolsPath $tools).Count | Should -Be 0
    }
}

Describe 'Write-DFConformanceReport' {
    BeforeEach { $script:rpt = Join-Path $TestDrive ([guid]::NewGuid().Guid + '.md') }

    It 'writes a fail section for each failing claim' {
        $led = @{ glow = @{ versionTested='2.1.2'; claims=@(
            @{ id='glow/honors-env:GLOW_CONFIG_DIR'; verdict='fail'; kind='env-then-spawn'; evidence='no scratch path in --help' }) } }
        Write-DFConformanceReport -Ledger $led -AdapterLinks @() -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'glow/honors-env:GLOW_CONFIG_DIR'
    }
    It 'writes a no-failures stub when everything passes' {
        $led = @{ bat = @{ versionTested='0.24.0'; claims=@(
            @{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='x' }) } }
        Write-DFConformanceReport -Ledger $led -AdapterLinks @() -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'no open conformance failures'
    }
    It 'flags a dead adapter when its claim now passes' {
        $led = @{ glow = @{ versionTested='2.2.0'; claims=@(
            @{ id='glow/honors-env:GLOW_CONFIG_DIR'; verdict='pass'; kind='env-then-spawn'; evidence='fixed upstream' }) } }
        $links = @( @{ Claim='glow/honors-env:GLOW_CONFIG_DIR'; File='Tools/glow.ps1'; Line=1 } )
        Write-DFConformanceReport -Ledger $led -AdapterLinks $links -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'dead code'
    }
    It 'warns about an orphan adapter referencing an unknown claim' {
        $led = @{ glow = @{ versionTested='2.1.2'; claims=@(
            @{ id='glow/honors-flag:-s'; verdict='pass'; kind='flag-then-spawn'; evidence='x' }) } }
        $links = @( @{ Claim='glow/honors-env:TYPO'; File='Tools/glow.ps1'; Line=1 } )
        Write-DFConformanceReport -Ledger $led -AdapterLinks $links -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'Orphan'
    }
}
