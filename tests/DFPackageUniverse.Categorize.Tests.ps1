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

    Context 'Get-DFPackageUniverseClassifierInput' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1" }
        It 'uses the repo README when available and records signal_source=readme' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("in-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $http = { param($Url) [pscustomobject]@{ Content = "# bat`nA cat clone with wings"; ContentType = 'text/markdown'; Status = 'ok' } }
                $m = @( [pscustomobject]@{ source='choco'; package_id='bat'; name='bat'; homepage='https://github.com/sharkdp/bat'; extra=$null } )
                try {
                    $in = Get-DFPackageUniverseClassifierInput -Members $m -Name 'bat' -Publisher 'sharkdp' -Description 'd' -Tags $null -Connection $conn -Http $http
                    $in.SignalSource | Should -Be 'readme'
                    $in.DocExcerpt | Should -Match 'cat clone'
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'falls back to metadata-only when no repo/doc and records signal_source=metadata' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("in2-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $http = { param($Url) throw 'no network' }
                $m = @( [pscustomobject]@{ source='winget'; package_id='A.X'; name='x'; homepage=$null; extra=$null } )
                try {
                    $in = Get-DFPackageUniverseClassifierInput -Members $m -Name 'x' -Publisher 'A' -Description 'thin' -Tags $null -Connection $conn -Http $http
                    $in.SignalSource | Should -Be 'metadata'
                } finally { $conn.Close() }
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

    Context 'ConvertTo-DFPackageUniverseClassification' {
        BeforeAll {
            . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1"
            $script:vocab = [pscustomobject]@{ Domain = @('dev','text'); Function = @('search','editor'); WorksWith = @('text','json') }
        }
        It 'keeps in-vocab values and drops out-of-vocab ones' {
            $raw = [pscustomobject]@{ domain='text'; function=@('search','bogus'); worksWith=@('text'); interface='cli'; alternativeTo=@('grep'); confidence=0.9; nothing_fits=$false; suggested_terms=@() }
            $c = ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab
            $c.Domain | Should -Be 'text'
            $c.Function | Should -Be @('search')        # 'bogus' dropped
            $c.AlternativeTo | Should -Be @('grep')
            $c.NothingFits | Should -BeFalse
        }
        It 'forces NothingFits when the model output has no in-vocab facet at all' {
            $raw = [pscustomobject]@{ domain='nope'; function=@('nope'); worksWith=@(); interface='cli'; confidence=0.2; nothing_fits=$false; suggested_terms=@('newthing') }
            $c = ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab
            $c.NothingFits | Should -BeTrue
            $c.SuggestedTerms | Should -Contain 'newthing'
        }
        It 'honors an explicit nothing_fits from the model' {
            $raw = [pscustomobject]@{ domain='dev'; function=@('search'); worksWith=@('text'); interface='cli'; confidence=0.3; nothing_fits=$true; suggested_terms=@() }
            (ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab).NothingFits | Should -BeTrue
        }
        It 'does not throw and forces NothingFits when the model omits domain/function/worksWith/interface' {
            $raw = [pscustomobject]@{ confidence = 0.4; nothing_fits = $false }   # central fields ABSENT
            $c = $null
            { $script:c = ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab } | Should -Not -Throw
            $script:c.NothingFits | Should -BeTrue
            @($script:c.Function).Count | Should -Be 0
            @($script:c.WorksWith).Count | Should -Be 0
            $script:c.Domain | Should -BeNullOrEmpty
        }
    }

    Context 'New-DFPackageUniverseClassifySeam' {
        It 'builds a request with the vocab-constrained schema and parses the response' {
            $vocab = [pscustomobject]@{ Domain=@('text'); Function=@('search'); WorksWith=@('text') }
            $captured = $null
            $rest = {
                param($Uri, $Headers, $Body)
                $script:captured = [pscustomobject]@{ Uri=$Uri; Headers=$Headers; Body=$Body }
                # Mimic OpenAI chat-completions shape with a JSON string in message content.
                [pscustomobject]@{ choices=@([pscustomobject]@{ message=[pscustomobject]@{ content='{"domain":"text","function":["search"],"worksWith":["text"],"interface":"cli","alternativeTo":["grep"],"confidence":0.9,"nothing_fits":false,"suggested_terms":[]}' } }); usage=[pscustomobject]@{ total_tokens=321 } }
            }
            $seam = New-DFPackageUniverseClassifySeam -ApiKey 'sk-test' -Model 'gpt-test' -Rest $rest
            $in = [pscustomobject]@{ Name='bat'; Publisher='sharkdp'; Description='cat clone'; Tags=$null; DocExcerpt='# bat'; SignalSource='readme' }
            $out = & $seam $in $vocab
            $out.Raw.domain | Should -Be 'text'
            $out.Usage.total_tokens | Should -Be 321
            $script:captured.Headers['Authorization'] | Should -Be 'Bearer sk-test'
            $script:captured.Uri | Should -Match 'openai\.com'
            ($script:captured.Body | ConvertFrom-Json).model | Should -Be 'gpt-test'
            # Proves the classifier input actually reached the request body --
            # regression guard for the $Input-is-reserved bug where the tool's
            # Name/Description silently came through empty.
            $script:captured.Body | Should -Match 'bat'          # the tool name reached the request
            $script:captured.Body | Should -Match 'cat clone'    # the description reached the request
        }
    }

    Context 'Invoke-DFPackageUniverseCategorizeRun' {
        BeforeAll {
            Import-Module PSSQLite
            . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"
            . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1"

            function New-CatRunDb {
                $db = Join-Path ([System.IO.Path]::GetTempPath()) ("run-" + [guid]::NewGuid().ToString('N') + ".db")
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, cluster_id INTEGER, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
'@
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $db
            }
            # NOTE: the task brief's helper used -Pid/-Home parameter names, which
            # shadow the PowerShell automatic variables $PID/$HOME. Renamed to
            # -PackageId/-HomepageUrl per repo convention (CLAUDE.md: never name a
            # local variable $home, among others).
            function Add-Tool {
                param($Db, $Id, $Name, $Src, $PackageId, $HomepageUrl)
                Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (@i,@n,1)" -SqlParameters @{ i = $Id; n = $Name }
                Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (@i,@s,@p,@h)" -SqlParameters @{ i = $Id; s = $Src; p = $PackageId; h = $HomepageUrl }
            }

            # NOTE: the brief's classify/escalate seams used `param($Input, $Vocab)`.
            # $Input/$input is a reserved PowerShell automatic variable (the pipeline
            # enumerator) -- declaring a parameter with that name does NOT bind the
            # positional argument passed via `&`; property access on it either throws
            # PropertyNotFoundException or silently evaluates empty depending on
            # whether the scriptblock was built via .GetNewClosure() inside an
            # enclosing function. Confirmed by isolated repro: both a 'bad' and a
            # 'good' tool came back 'deferred' because `$Input.Name` threw for every
            # call. Renamed the seam's parameter to $ToolInput throughout (CLAUDE.md's
            # do-not-shadow list already forbids $input for exactly this reason).
            $script:vocab = [pscustomobject]@{ Domain = @('text', 'dev'); Function = @('search'); WorksWith = @('text') }
            $script:goodClassify = { param($ToolInput, $Vocab) [pscustomobject]@{ Raw = [pscustomobject]@{ domain = 'text'; function = @('search'); worksWith = @('text'); interface = 'cli'; alternativeTo = @(); confidence = 0.9; nothing_fits = $false; suggested_terms = @() }; Model = 'm'; Usage = [pscustomobject]@{ total_tokens = 10 } } }
            $script:http = { param($Url) [pscustomobject]@{ Content = '# readme'; ContentType = 'text/markdown'; Status = 'ok' } }
            # Brief used -Pid, but $PID is a read-only automatic variable in PowerShell --
            # binding to it via `&` throws SessionStateUnauthorizedAccessException.
            $script:log = { param($Level, $Src, $PackageId, $Msg) }
        }

        It 'classifies unprocessed tools and is idempotent on a second run (resume)' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'bat' -Src 'choco' -PackageId 'bat' -HomepageUrl 'https://github.com/sharkdp/bat'
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $r1 = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $script:vocab -Http $script:http -Classify $script:goodClassify -BudgetCalls 100 -Log $script:log
                    $r1.Classified | Should -Be 1
                    $script:secondCalls = 0
                    # Reference the shared $script:goodClassify seam directly -- $using: is only
                    # valid inside Invoke-Command/ForEach-Object -Parallel/Start-Job, not here.
                    $countingClassify = { param($ToolInput, $Vocab) $script:secondCalls++; & $script:goodClassify $ToolInput $Vocab }
                    $r2 = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $script:vocab -Http $script:http -Classify $countingClassify -BudgetCalls 100 -Log $script:log
                    $r2.Classified | Should -Be 0    # already cached -> resume skips it
                } finally { $conn.Close() }
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE status='done'").n | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'stops at the budget, leaving the rest unprocessed for a later run' {
            $db = New-CatRunDb
            try {
                1..3 | ForEach-Object { Add-Tool -Db $db -Id $_ -Name "t$_" -Src 'scoop' -PackageId "main/t$_" -HomepageUrl $null }
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $script:vocab -Http $script:http -Classify $script:goodClassify -BudgetCalls 2 -Log $script:log
                    $r.Classified | Should -Be 2; $r.Remaining | Should -BeGreaterThan 0
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'marks a tool deferred (not done) when classify throws, without aborting the batch' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'bad' -Src 'scoop' -PackageId 'main/bad' -HomepageUrl $null
                Add-Tool -Db $db -Id 2 -Name 'good' -Src 'scoop' -PackageId 'main/good' -HomepageUrl $null
                $mixed = { param($ToolInput, $Vocab) if ($ToolInput.Name -eq 'bad') { throw 'boom' }; & $script:goodClassify $ToolInput $Vocab }
                $conn = New-SQLiteConnection -DataSource $db
                try { $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $script:vocab -Http $script:http -Classify $mixed -BudgetCalls 100 -Log $script:log } finally { $conn.Close() }
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT status FROM tool_classifications WHERE cache_key='pkg:scoop|main/bad'").status | Should -Be 'deferred'
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT status FROM tool_classifications WHERE cache_key='pkg:scoop|main/good'").status | Should -Be 'done'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'escalates a low-confidence result to the Escalate seam' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'x' -Src 'scoop' -PackageId 'main/x' -HomepageUrl $null
                $lowConf = { param($ToolInput, $Vocab) [pscustomobject]@{ Raw = [pscustomobject]@{ domain = 'text'; function = @('search'); worksWith = @('text'); interface = 'cli'; alternativeTo = @(); confidence = 0.2; nothing_fits = $false; suggested_terms = @() }; Model = 'small'; Usage = [pscustomobject]@{ total_tokens = 5 } } }
                $script:escalated = 0
                $esc = { param($ToolInput, $Vocab) $script:escalated++; [pscustomobject]@{ Raw = [pscustomobject]@{ domain = 'dev'; function = @('search'); worksWith = @('text'); interface = 'cli'; alternativeTo = @(); confidence = 0.95; nothing_fits = $false; suggested_terms = @() }; Model = 'strong'; Usage = [pscustomobject]@{ total_tokens = 8 } } }
                $conn = New-SQLiteConnection -DataSource $db
                try { $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $script:vocab -Http $script:http -Classify $lowConf -Escalate $esc -BudgetCalls 100 -Log $script:log } finally { $conn.Close() }
                $script:escalated | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT model FROM tool_classifications WHERE cache_key='pkg:scoop|main/x'").model | Should -Be 'strong'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Build-DFPackageUniverseCategories.ps1' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"; . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1" }
        It 'runs end-to-end against a prepared DB with injected seams and returns a summary' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-" + [guid]::NewGuid().ToString('N') + ".db")
            $js = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_categories (tool_id INTEGER, category TEXT, PRIMARY KEY(tool_id,category));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
'@
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (1,'bat',1)"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (1,'choco','bat','https://github.com/sharkdp/bat')"
                '{ "schemaVersion":1, "classifications":[] }' | Set-Content -Path $js
                $http = { param($Url) [pscustomobject]@{ Content='# bat'; ContentType='text/markdown'; Status='ok' } }
                # NOTE: the brief's seam used `param($Input,$Vocab)`; $Input/$input is a
                # reserved PowerShell automatic variable (see the note in the
                # Invoke-DFPackageUniverseCategorizeRun Context above). Renamed to
                # $ClassifierInput to match the real seam signature (Task 8).
                $classify = { param($ClassifierInput,$Vocab) [pscustomobject]@{ Raw=[pscustomobject]@{ domain='text'; function=@('file-viewing'); worksWith=@('text'); interface='cli'; alternativeTo=@('cat'); confidence=0.9; nothing_fits=$false; suggested_terms=@() }; Model='m'; Usage=[pscustomobject]@{total_tokens=10} } }
                $summary = & "$PSScriptRoot/../build/Build-DFPackageUniverseCategories.ps1" -DatabasePath $db -ClassificationsPath $js -Http $http -Classify $classify -BudgetCalls 100 6>$null
                $summary.Classified | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT domain FROM tools WHERE tool_id=1").domain | Should -Be 'text'
                (Get-Content -Raw $js) | Should -Match 'sharkdp/bat'
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }
        It 'throws when tool_packages is missing (Phase C not run)' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("noc-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query "CREATE TABLE tools (tool_id INTEGER PRIMARY KEY)"
                { & "$PSScriptRoot/../build/Build-DFPackageUniverseCategories.ps1" -DatabasePath $db -Http {} -Classify {} 6>$null } | Should -Throw '*tool_packages*'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
}
