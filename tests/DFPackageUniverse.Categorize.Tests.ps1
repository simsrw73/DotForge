BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"       # ConvertFrom-DFDbNull
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Categorize.ps1"
}

Describe 'DFPackageUniverse.Categorize' {
    Context 'Resolve-DFPackageUniverseRepo' {
        It 'resolves a GitHub homepage' {
            $r = Resolve-DFPackageUniverseRepo -Homepage 'https://github.com/sharkdp/bat'
            $r.Host | Should -Be 'github.com'; $r.Owner | Should -Be 'sharkdp'; $r.Repo | Should -Be 'bat'
            $r.Url | Should -Be 'https://github.com/sharkdp/bat'
        }
        It 'resolves a GitLab homepage and strips .git' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://gitlab.com/Owner/Repo.git').Url | Should -Be 'https://gitlab.com/owner/repo'
        }
        It 'resolves a Codeberg homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://codeberg.org/a/b/').Url | Should -Be 'https://codeberg.org/a/b'
        }
        It 'prefers choco ProjectSourceUrl in extra over a non-repo homepage' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://gitlab.com/x/y' }
            (Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' -Extra $extra).Url | Should -Be 'https://gitlab.com/x/y'
        }
        It 'returns null for a non-repo homepage with no repo in extra' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' | Should -BeNullOrEmpty
        }
        It 'does not throw under strict on null inputs' {
            { Resolve-DFPackageUniverseRepo -Homepage $null -Extra $null } | Should -Not -Throw
        }
        It 'returns null for a forge subdomain that is not a repo path' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://docs.github.com/en/get-started' | Should -BeNullOrEmpty
        }
        It 'returns null for a gist subdomain' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://gist.github.com/user/abc123' | Should -BeNullOrEmpty
        }
        It 'resolves a Bitbucket homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://bitbucket.org/team/proj').Url | Should -Be 'https://bitbucket.org/team/proj'
        }
        It 'resolves a git.sr.ht homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://git.sr.ht/~user/repo').Url | Should -Be 'https://git.sr.ht/~user/repo'
        }
        It 'resolves a mixed-case host' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://GitHub.com/sharkdp/bat').Url | Should -Be 'https://github.com/sharkdp/bat'
        }
        It 'recovers the repo from a scoop autoupdate blob with an embedded github release url' {
            $extra = ConvertTo-Json -Compress -Depth 8 @{ autoupdate = @{ architecture = @{ '64bit' = @{ url = 'https://github.com/acme/tool/releases/download/v$version/tool.zip' } } } }
            (Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' -Extra $extra).Url | Should -Be 'https://github.com/acme/tool'
        }
    }

    Context 'Get-DFPackageUniverseDurableKey' {
        BeforeAll {
            function Mem($s, $p, $homepage = $null, $extra = $null) {
                [pscustomobject]@{ source = $s; package_id = $p; name = $p; homepage = $homepage; extra = $extra }
            }
        }
        It 'keys on the repo (name-suffixed) when a member resolves a repo' {
            $m = @( (Mem 'choco' 'bat' 'https://github.com/sharkdp/bat') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'bat' | Should -Be 'repo:https://github.com/sharkdp/bat|bat'
        }
        It 'gives two tools sharing one repo but different names distinct keys' {
            $a = @( (Mem 'winget' 'OpenDsc.Lcm' 'https://github.com/opendsc/opendsc') )
            $b = @( (Mem 'winget' 'OpenDsc.Server' 'https://github.com/opendsc/opendsc') )
            (Get-DFPackageUniverseDurableKey -Members $a -Name 'OpenDsc Lcm') |
                Should -Not -Be (Get-DFPackageUniverseDurableKey -Members $b -Name 'OpenDsc Server')
        }
        It 'falls back to a path-bearing homepage when no repo' {
            $m = @( (Mem 'winget' 'X.Y' 'https://vendor.example/tool') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'tool' | Should -Be 'home:vendor.example/tool'
        }
        It 'falls back to the anchor source|package_id for a repo-less, homepage-less singleton' {
            $m = @( (Mem 'scoop' 'main/thing') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'thing' | Should -Be 'pkg:scoop|main/thing'
        }
        It 'picks the winget anchor over choco/scoop deterministically' {
            $m = @( (Mem 'scoop' 'main/x'), (Mem 'winget' 'A.X'), (Mem 'choco' 'x') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'x' | Should -Be 'pkg:winget|A.X'
        }
    }

    Context 'Get-DFPackageUniverseApiKey' {
        It 'reads a key from a .env, ignoring comments and blanks' {
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ("env-" + [guid]::NewGuid().ToString('N'))
            try {
                Set-Content -Path $f -Value @('# comment', '', 'OPENAI_API_KEY=sk-abc123', 'OTHER=x')
                Get-DFPackageUniverseApiKey -EnvPath $f -Name 'OPENAI_API_KEY' | Should -Be 'sk-abc123'
                Get-DFPackageUniverseApiKey -EnvPath $f -Name 'MISSING' | Should -BeNullOrEmpty
            } finally { Remove-Item -Path $f -ErrorAction Ignore }
        }
    }
    Context 'Get-DFPackageUniverseFetch' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1" }
        It 'fetches once, then serves from cache without re-calling Http' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $script:calls = 0
                $http = { param($Url) $script:calls++; [pscustomobject]@{ Content = 'README!'; ContentType = 'text/markdown'; Status = 'ok' } }
                try {
                    (Get-DFPackageUniverseFetch -Url 'https://x/readme' -Connection $conn -Http $http).Content | Should -Be 'README!'
                    (Get-DFPackageUniverseFetch -Url 'https://x/readme' -Connection $conn -Http $http).Content | Should -Be 'README!'
                } finally { $conn.Close() }
                $script:calls | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'caches a failed fetch so it is not retried' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch2-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $script:calls2 = 0
                $http = { param($Url) $script:calls2++; throw '404' }
                try {
                    (Get-DFPackageUniverseFetch -Url 'https://dead/x' -Connection $conn -Http $http).Content | Should -BeNullOrEmpty
                    Get-DFPackageUniverseFetch -Url 'https://dead/x' -Connection $conn -Http $http | Out-Null
                } finally { $conn.Close() }
                $script:calls2 | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'vocabulary' {
        BeforeAll {
            . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1"
            $script:dom = Join-Path ([System.IO.Path]::GetTempPath()) ("dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            @'
{ // coarse top-level domains
  "schemaVersion": 1,
  "domain": ["dev", "system", "network", "text", "media", "security", "data", "productivity"]
}
'@ | Set-Content -Path $script:dom -Encoding utf8
            $script:tax = Join-Path ([System.IO.Path]::GetTempPath()) ("tax-" + [guid]::NewGuid().ToString('N') + ".json")
            (@{ taxonomy = @{ function = @('search', 'editor'); worksWith = @('text', 'json') } } | ConvertTo-Json -Depth 5) | Set-Content -Path $script:tax -Encoding utf8
        }
        AfterAll { Remove-Item $script:dom, $script:tax -ErrorAction Ignore }
        It 'loads the three axes' {
            $v = Import-DFPackageUniverseVocab -DomainsPath $script:dom -TaxonomyPath $script:tax
            $v.Domain | Should -Contain 'network'; $v.Function | Should -Contain 'search'; $v.WorksWith | Should -Contain 'json'
        }
        It 'validates membership' {
            $v = Import-DFPackageUniverseVocab -DomainsPath $script:dom -TaxonomyPath $script:tax
            Test-DFPackageUniverseVocabValue -Value 'search' -Vocab $v.Function | Should -BeTrue
            Test-DFPackageUniverseVocabValue -Value 'nope' -Vocab $v.Function | Should -BeFalse
        }
    }
}
