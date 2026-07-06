BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolIdentityGuideSchema.ps1"
}

Describe 'Build-DFToolIdentities' {
    BeforeEach {
        $script:ToolsDir = Join-Path $TestDrive 'Tools'
        $script:IdentitiesDir = Join-Path $TestDrive 'identities'
        # $TestDrive is shared across every It in this Describe (Pester v5 does
        # not mint a fresh TestDrive per It), so fragment/tool files added by
        # one test would otherwise leak into later tests. Start each test from
        # clean dirs (matches the pattern in tests/Build-DFCategoryDb.Tests.ps1).
        if (Test-Path $script:ToolsDir) { Remove-Item $script:ToolsDir -Recurse -Force }
        if (Test-Path $script:IdentitiesDir) { Remove-Item $script:IdentitiesDir -Recurse -Force }
        New-Item -ItemType Directory -Path $script:ToolsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:IdentitiesDir -Force | Out-Null
        $script:OutPath = Join-Path $TestDrive 'out.json'

        @{ name = 'ripgrep'; executable = 'rg.exe'; packages = @{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:ToolsDir 'ripgrep.json')
        @{ name = 'nopkgs'; executable = 'nopkgs.exe' } |   # no packages block at all — must be skipped, not error
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:ToolsDir 'nopkgs.json')

        # A canned resolver: always reports the repo tier for ripgrep, curated for anything else.
        $script:CannedResolver = {
            param($ToolName, $Packages, $Fresh)
            if ($ToolName -eq 'ripgrep') { [pscustomobject]@{ LinkedVia = 'repo'; Repo = 'https://github.com/BurntSushi/ripgrep' } }
            else { [pscustomobject]@{ LinkedVia = 'curated'; Repo = $null } }
        }
    }

    It 'ingests Tools/*.json packages blocks, skipping tools with no packages block' {
        & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver
        $doc = Get-Content $script:OutPath -Raw | ConvertFrom-Json
        $doc.tools.PSObject.Properties.Name | Should -Contain 'ripgrep'
        $doc.tools.PSObject.Properties.Name | Should -Not -Contain 'nopkgs'
    }

    It 'records the resolver''s linkedVia and repo verbatim' {
        & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver
        $doc = Get-Content $script:OutPath -Raw | ConvertFrom-Json
        $doc.tools.ripgrep.linkedVia | Should -Be 'repo'
        $doc.tools.ripgrep.repo | Should -Be 'https://github.com/BurntSushi/ripgrep'
    }

    It 'merges hand-authored fragments alongside the Tools/*.json seed' {
        @{ zed = @{ packages = @{ winget = 'Zed.Zed' }; linkedVia = 'curated' } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:IdentitiesDir 'extras.jsonc')
        & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver
        $doc = Get-Content $script:OutPath -Raw | ConvertFrom-Json
        $doc.tools.PSObject.Properties.Name | Should -Contain 'zed'
        $doc.tools.zed.linkedVia | Should -Be 'curated'
    }

    It 'strips // comments from fragment files' {
        @'
{
  // a comment
  "zed": { "packages": { "winget": "Zed.Zed" }, "linkedVia": "curated" }
}
'@ | Set-Content (Join-Path $script:IdentitiesDir 'commented.jsonc')
        { & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver } |
            Should -Not -Throw
    }

    It 'throws on a duplicate tool key between a fragment and Tools/*.json' {
        @{ ripgrep = @{ packages = @{ npm = 'ripgrep' }; linkedVia = 'curated' } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:IdentitiesDir 'dup.jsonc')
        { & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver } |
            Should -Throw '*ripgrep*'
    }

    It 'throws when a (source, packageId) pair is claimed by two different tool keys' {
        @{ ripgrep2 = @{ packages = @{ scoop = 'ripgrep' }; linkedVia = 'curated' } } |   # collides with ripgrep's scoop:ripgrep
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:IdentitiesDir 'collide.jsonc')
        { & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver } |
            Should -Throw '*scoop:ripgrep*'
    }

    It 'throws with the validator''s messages when the generated document is invalid' {
        $badResolver = { param($ToolName, $Packages, $Fresh) [pscustomobject]@{ LinkedVia = 'guessed'; Repo = $null } }
        { & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $badResolver } |
            Should -Throw '*linkedVia*'
    }

    It 'sorts tool keys alphabetically for a deterministic diff' {
        @{ aaa = @{ packages = @{ winget = 'Aaa.Aaa' }; linkedVia = 'curated' } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:IdentitiesDir 'aaa.jsonc')
        & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver
        $raw = Get-Content $script:OutPath -Raw
        $raw.IndexOf('"aaa"') | Should -BeLessThan $raw.IndexOf('"ripgrep"')
    }

    It 'works with an empty (or absent) identities directory' {
        Remove-Item $script:IdentitiesDir -Recurse -Force
        { & "$PSScriptRoot/../build/Build-DFToolIdentities.ps1" -ToolsPath $script:ToolsDir -IdentitiesDir $script:IdentitiesDir -OutPath $script:OutPath -ResolveLinkage $script:CannedResolver } |
            Should -Not -Throw
    }
}

Describe 'the shipped data/tool-identities.json' {
    It 'validates against the schema' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-identities.json" -Raw | ConvertFrom-Json
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $doc -Errors ([ref]$errs) | Should -BeTrue -Because ($errs -join '; ')
    }

    It 'contains all 32 tools that have a packages block in Tools/*.json' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-identities.json" -Raw | ConvertFrom-Json
        $curatedNames = Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $t = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($t.packages -and @($t.packages.PSObject.Properties).Count -gt 0) { $t.name }
        } | Where-Object { $_ }
        foreach ($name in $curatedNames) {
            $doc.tools.PSObject.Properties.Name | Should -Contain $name
        }
    }
}
