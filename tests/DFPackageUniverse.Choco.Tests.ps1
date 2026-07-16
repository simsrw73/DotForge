BeforeAll {
    Import-Module PSSQLite
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Choco.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Db.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Choco.ps1"

    function New-FakeChocoODataEntry {
        param($Id, [switch]$Typed, [string]$Author = 'BurntSushi')
        # Mimics a raw feed entry: Authors is NOT under .properties -- OData
        # feed customization (FC_KeepInContent=false) puts it on the Atom
        # <author><name> element; see DFPackageUniverse.Choco.ps1 header.
        $wrap = { param($v) if ($Typed) { [pscustomobject]@{ '#text' = $v } } else { $v } }
        [pscustomobject]@{
            properties = [pscustomobject]@{
                Id          = $Id
                Version     = '14.1.1'
                Description = 'Recursively search directories for a regex pattern'
                ProjectUrl  = 'https://github.com/BurntSushi/ripgrep'
                Tags        = (& $wrap 'search grep cli')
                LicenseUrl  = (& $wrap 'https://github.com/BurntSushi/ripgrep/blob/master/LICENSE-MIT')
            }
            author = [pscustomobject]@{ name = $Author }
            title  = $Id
        }
    }

    # A fake fetch seam matching the production contract: param($Url) ->
    # @{ Entries; NextUrl }. Pages are returned by call order; NextUrl is a
    # non-null sentinel for every page except the last, mirroring the server's
    # <link rel="next"> continuation (its absence = end of walk).
    function New-FakeChocoFetch {
        param([object[]]$Pages)
        $counter = @{ Index = 0 }
        {
            param($Url)
            $i = $counter.Index
            $counter.Index++
            $entries = if ($i -lt $Pages.Count) { $Pages[$i] } else { @() }
            $next = if (($i + 1) -lt $Pages.Count) { "https://fake/next/page$($i + 1)" } else { $null }
            [pscustomobject]@{ Entries = @($entries); NextUrl = $next }
        }.GetNewClosure()
    }
}

Describe 'DFPackageUniverse.Choco' {
    Context 'ConvertTo-DFPackageUniverseChocoRow' {
        It 'maps id/name/description/version/homepage plus tags/license from properties' {
            $row = ConvertTo-DFPackageUniverseChocoRow -Entry (New-FakeChocoODataEntry -Id 'ripgrep')

            $row.source | Should -Be 'choco'
            $row.package_id | Should -Be 'ripgrep'
            $row.name | Should -Be 'ripgrep'
            $row.version | Should -Be '14.1.1'
            $row.description | Should -Be 'Recursively search directories for a regex pattern'
            $row.homepage | Should -Be 'https://github.com/BurntSushi/ripgrep'
            $row.license | Should -Be 'https://github.com/BurntSushi/ripgrep/blob/master/LICENSE-MIT'
            (ConvertFrom-Json $row.tags) | Should -Be @('search', 'grep', 'cli')
        }

        It 'reads publisher from the Atom author element, not entry.properties.Authors' {
            $row = ConvertTo-DFPackageUniverseChocoRow -Entry (New-FakeChocoODataEntry -Id 'ripgrep' -Author 'BurntSushi')
            $row.publisher | Should -Be 'BurntSushi'

            $entry = New-FakeChocoODataEntry -Id 'ripgrep'
            $entry.properties.PSObject.Properties.Match('Authors').Count | Should -Be 0
        }

        It 'handles m:typed (#text-wrapped) OData elements the same as plain strings' {
            $row = ConvertTo-DFPackageUniverseChocoRow -Entry (New-FakeChocoODataEntry -Id 'ripgrep' -Typed)
            $row.license | Should -Be 'https://github.com/BurntSushi/ripgrep/blob/master/LICENSE-MIT'
            (ConvertFrom-Json $row.tags) | Should -Be @('search', 'grep', 'cli')
        }

        It 'returns $null when the entry has no resolvable id' {
            $entry = [pscustomobject]@{ properties = [pscustomobject]@{ Version = '1.0' }; author = [pscustomobject]@{ name = '' } }
            ConvertTo-DFPackageUniverseChocoRow -Entry $entry | Should -BeNullOrEmpty
        }

        It 'does not throw under strict mode on an entry missing properties/author entirely' {
            # Strict mode is the point: absent members are normal in this feed,
            # so every read goes through Get-DFXmlMember. A bare $entry.properties
            # would throw here rather than return $null.
            Set-StrictMode -Version Latest
            { ConvertTo-DFPackageUniverseChocoRow -Entry ([pscustomobject]@{ title = 'lonely' }) } | Should -Not -Throw
            (ConvertTo-DFPackageUniverseChocoRow -Entry ([pscustomobject]@{ title = 'lonely' })).package_id | Should -Be 'lonely'
        }
    }

    Context 'Build-DFPackageUniverseChocoRequestUrl' {
        It 'asks for IsLatestVersion only -- no date filter, no $skip, no $top' {
            # THE regression test for the 2026-07-15 redesign. A Published or
            # LastUpdated clause creeping back in would still produce correct
            # data, just ~16x more slowly (~4,480 requests instead of ~281),
            # because this server applies filters AFTER pagination. That is
            # invisible to every other test, so it is asserted here explicitly.
            $url = [uri]::UnescapeDataString((Build-DFPackageUniverseChocoRequestUrl))

            $url | Should -Match '\$filter=IsLatestVersion'
            $url | Should -Not -Match 'Published'
            $url | Should -Not -Match 'LastUpdated'
            $url | Should -Not -Match '\$skip'
            $url | Should -Not -Match '\$top'
        }
    }

    Context 'ConvertFrom-DFPackageUniverseChocoFeedXml (the production fetch parser)' {
        # Every other test injects a fake fetch seam, so this parser -- the one
        # that actually runs against the live server -- had NO coverage at all
        # until 2026-07-15, when it turned out to throw on the last page of
        # every walk. Strict mode here on purpose: the script runs strict, and
        # StrictMode is dynamically scoped, so a default Pester run would not
        # reproduce production.
        BeforeEach { Set-StrictMode -Version Latest }

        It 'reads entries and the next-link from a mid-walk page' {
            $xml = [xml]@'
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="self" href="https://community.chocolatey.org/api/v2/Packages" />
  <link rel="next" href="http://community.chocolatey.org/api/v2/Packages?$skiptoken='11','adobeair'" />
  <entry><title>0ad</title></entry>
  <entry><title>AdobeAIR</title></entry>
</feed>
'@
            $page = ConvertFrom-DFPackageUniverseChocoFeedXml -Xml $xml
            $page.Entries.Count | Should -Be 2
            $page.NextUrl | Should -Match 'skiptoken'
            # http -> https: the server hands back an http next-link.
            $page.NextUrl | Should -BeLike 'https://*'
        }

        It 'returns NextUrl = $null on the LAST page (no next link) instead of throwing' {
            # THE regression test. `($xml.feed.link | Where-Object {...}).href`
            # throws here under strict -- and the walk would misread its own
            # correct termination as a failed page, retry 3x, and report
            # Complete=$false, skipping the prune.
            $xml = [xml]@'
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="self" href="https://community.chocolatey.org/api/v2/Packages" />
  <entry><title>zzz-last-package</title></entry>
</feed>
'@
            $page = ConvertFrom-DFPackageUniverseChocoFeedXml -Xml $xml
            $page.Entries.Count | Should -Be 1
            $page.NextUrl | Should -BeNullOrEmpty
        }

        It 'returns zero entries for an empty feed instead of throwing' {
            $xml = [xml]@'
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="self" href="https://community.chocolatey.org/api/v2/Packages" />
</feed>
'@
            $page = ConvertFrom-DFPackageUniverseChocoFeedXml -Xml $xml
            $page.Entries.Count | Should -Be 0
            $page.NextUrl | Should -BeNullOrEmpty
        }

        # NB: no angle brackets in this name -- Pester 5 treats <...> in a test
        # name as a -ForEach template placeholder and tries to expand it, so
        # 'no <link> elements' fails with "The variable '$link' cannot be
        # retrieved" under strict mode. The code is fine; the name was not.
        It 'handles a feed with no link elements at all' {
            $xml = [xml]'<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>a</title></entry></feed>'
            $page = ConvertFrom-DFPackageUniverseChocoFeedXml -Xml $xml
            $page.Entries.Count | Should -Be 1
            $page.NextUrl | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-DFPackageUniverseChocoPageWithRetry' {
        BeforeEach {
            $script:logged = @()
            $script:slept = @()
            $script:log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }
            $script:sleep = { param($Milliseconds) $script:slept += $Milliseconds }
        }

        It 'returns the page and its NextUrl on first success without sleeping' {
            $fetch = { param($Url) [pscustomobject]@{ Entries = @('a', 'b'); NextUrl = 'https://fake/next' } }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.Ok | Should -BeTrue
            $result.Entries.Count | Should -Be 2
            $result.NextUrl | Should -Be 'https://fake/next'
            $budget.Used | Should -Be 1
            $script:slept.Count | Should -Be 0
        }

        It 'treats an empty feed as zero entries, not one (the @($null) null-guard)' {
            # @($xml.feed.entry) yields @($null) -- Count 1 -- on a page with no
            # entries. That artifact is why the 2026-07-15 run logged empty pages
            # as "1 entries, 0 new", an arithmetic impossibility that exposed the
            # bug. Nulls must be filtered out, not counted.
            $fetch = { param($Url) [pscustomobject]@{ Entries = @($null); NextUrl = $null } }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.Ok | Should -BeTrue
            $result.Entries.Count | Should -Be 0
        }

        It 'retries with 1s/2s/4s backoff then succeeds for a transient error' {
            $script:attempts = 0
            $fetch = {
                param($Url)
                $script:attempts++
                if ($script:attempts -le 2) { throw 'transient network error' }
                [pscustomobject]@{ Entries = @('a'); NextUrl = $null }
            }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.Ok | Should -BeTrue
            $script:slept | Should -Be @(1000, 2000)
            $script:logged.Count | Should -Be 0
        }

        It 'gives up and logs an error after 3 retries of a transient failure' {
            $fetch = { param($Url) throw 'always fails' }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.Ok | Should -BeFalse
            $result.CapHit | Should -BeFalse
            $script:slept | Should -Be @(1000, 2000, 4000)
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'error'
        }

        It 'recognizes a 406 (item-cap) immediately, without retrying or sleeping' {
            $fetch = { param($Url) throw [System.Exception]::new('406 Not Acceptable: Traversing more than 10000 items is no longer supported.') }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.Ok | Should -BeFalse
            $result.CapHit | Should -BeTrue
            $script:slept.Count | Should -Be 0
            $budget.Used | Should -Be 1
            $script:logged.Count | Should -Be 0
        }

        It 'recognizes a 429 (rate limit) immediately, aborts the run, and never retries' {
            $fetch = { param($Url) throw [System.Exception]::new('Response status code does not indicate success: 429 (Too Many Requests).') }
            $budget = @{ Used = 0; Max = 100; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.RateLimited | Should -BeTrue
            $result.Ok | Should -BeFalse
            $script:slept.Count | Should -Be 0
            $budget.Used | Should -Be 1
            $budget.Aborted | Should -BeTrue
            $budget.AbortReason | Should -Match '429'
            @($script:logged | Where-Object { $_[0] -eq 'error' }).Count | Should -Be 1
        }

        It 'stops immediately once the request budget is exhausted' {
            $fetch = { param($Url) [pscustomobject]@{ Entries = @('a'); NextUrl = $null } }
            $budget = @{ Used = 5; Max = 5; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
            $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $fetch -Url 'https://fake/p1' -Log $script:log -Sleep $script:sleep -RequestBudget $budget
            $result.BudgetExhausted | Should -BeTrue
            $budget.Used | Should -Be 5
            $budget.Aborted | Should -BeTrue
        }
    }

    Context 'Get-DFPackageUniverseChocoRows (the walk)' {
        BeforeEach {
            $script:logged = @()
            $script:log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }
            $script:sleep = { param($Milliseconds) }
        }

        It 'follows next-links across all pages until there is no next link' {
            $fetch = New-FakeChocoFetch -Pages @(
                @((New-FakeChocoODataEntry 'a'), (New-FakeChocoODataEntry 'b'), (New-FakeChocoODataEntry 'c')),
                @((New-FakeChocoODataEntry 'd')),
                @((New-FakeChocoODataEntry 'e'), (New-FakeChocoODataEntry 'f'))
            )
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1

            $result.Rows.Count | Should -Be 6
            $result.Rows.package_id | Should -Be @('a', 'b', 'c', 'd', 'e', 'f')
            # 3 pages, then the third has no next link -> stop. No wasted request.
            $result.RequestsUsed | Should -Be 3
            $result.PageCount | Should -Be 3
            $result.Complete | Should -BeTrue
        }

        It 'stops after a single page with no next link' {
            $fetch = New-FakeChocoFetch -Pages @(@((New-FakeChocoODataEntry 'a')))
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1
            $result.Rows.Count | Should -Be 1
            $result.RequestsUsed | Should -Be 1
            $result.Complete | Should -BeTrue
        }

        It 'deduplicates a package_id redelivered across pages (defensive safety net)' {
            # Dedup must NOT be the termination signal -- treating "no new ids"
            # as end-of-walk is what produced the 125-row crawl. Here page 2 is
            # entirely redelivered yet the walk continues to page 3.
            $fetch = New-FakeChocoFetch -Pages @(
                @((New-FakeChocoODataEntry 'a'), (New-FakeChocoODataEntry 'b')),
                @((New-FakeChocoODataEntry 'a'), (New-FakeChocoODataEntry 'b')),
                @((New-FakeChocoODataEntry 'c'))
            )
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1

            $result.Rows.Count | Should -Be 3
            $result.Rows.package_id | Should -Be @('a', 'b', 'c')
            $result.PageCount | Should -Be 3
            $result.Complete | Should -BeTrue
        }

        It 'flushes each page to WriteRows as it arrives, not once at the end' {
            # An interrupted run must not lose what it already fetched: the
            # 2026-07-15 run lost ~430 requests' worth of rows to end-of-walk
            # batching. Page 3 throws here; pages 1-2 must already be written.
            $script:written = @()
            $writeRows = { param($PageRows) $script:written += , @($PageRows.package_id) }
            $script:calls = 0
            $fetch = {
                param($Url)
                $script:calls++
                if ($script:calls -ge 3) { throw 'network died mid-walk' }
                [pscustomobject]@{
                    Entries = @((New-FakeChocoODataEntry "pkg$($script:calls)"))
                    NextUrl = 'https://fake/next'
                }
            }
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -WriteRows $writeRows -DelayMinMs 0 -DelayMaxMs 1

            $script:written.Count | Should -Be 2
            $script:written[0] | Should -Be @('pkg1')
            $script:written[1] | Should -Be @('pkg2')
            $result.Complete | Should -BeFalse
        }

        It 'treats an unexpected 406 as a hard error, not a signal to partition' {
            # Under skiptoken paging the cap should be unreachable. If it ever
            # fires, the server changed and the design's central assumption
            # needs re-testing -- so it must be loud, and must block the prune.
            $fetch = { param($Url) throw [System.Exception]::new('406 Not Acceptable') }
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1

            $result.Rows.Count | Should -Be 0
            $result.Complete | Should -BeFalse
            $result.ErrorCount | Should -Be 1
            $errors = @($script:logged | Where-Object { $_[0] -eq 'error' })
            $errors.Count | Should -Be 1
            $errors[0][2] | Should -Match '406'
        }

        It 'logs a warning and skips an entry that fails conversion, without aborting the page' {
            Mock ConvertTo-DFPackageUniverseChocoRow {
                param($Entry)
                if ($Entry.title -eq 'broken') { throw 'boom' }
                [pscustomobject]@{ source = 'choco'; package_id = $Entry.title }
            }
            $fetch = New-FakeChocoFetch -Pages @(@((New-FakeChocoODataEntry 'broken'), (New-FakeChocoODataEntry 'fd')))
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1

            $result.Rows.Count | Should -Be 1
            $result.Rows[0].package_id | Should -Be 'fd'
            @($script:logged | Where-Object { $_[0] -eq 'warning' }).Count | Should -Be 1
            $result.Complete | Should -BeTrue
        }

        It 'does not throw when DelayMin equals DelayMax (Get-Random guard)' {
            $fetch = New-FakeChocoFetch -Pages @(
                @((New-FakeChocoODataEntry 'a')),
                @((New-FakeChocoODataEntry 'b'))
            )
            { Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep { param($ms) } -Log $script:log -DelayMinMs 500 -DelayMaxMs 500 } | Should -Not -Throw
        }

        It 'reports Complete=$false when a 429 aborts the walk' {
            $fetch = { param($Url) throw [System.Exception]::new('Response status code does not indicate success: 429 (Too Many Requests).') }
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1
            $result.Complete | Should -BeFalse
            $result.AbortReason | Should -Match '429'
        }

        It 'reports Complete=$false when the request budget is exhausted' {
            # Every page has a next link, so only the budget stops it.
            $fetch = { param($Url) [pscustomobject]@{ Entries = @((New-FakeChocoODataEntry 'a')); NextUrl = 'https://fake/next' } }
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -MaxRequests 3 -DelayMinMs 0 -DelayMaxMs 1
            $result.Complete | Should -BeFalse
            $result.RequestsUsed | Should -Be 3
            $result.AbortReason | Should -Match 'budget'
        }

        It 'reports Complete=$false when a page fails after its retries' {
            $fetch = { param($Url) throw 'always fails' }
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1
            $result.Complete | Should -BeFalse
            $result.ErrorCount | Should -Be 1
        }

        It 'exposes SeenIds for the caller''s prune gate' {
            $fetch = New-FakeChocoFetch -Pages @(@((New-FakeChocoODataEntry 'a'), (New-FakeChocoODataEntry 'b')))
            $result = Get-DFPackageUniverseChocoRows -FetchPage $fetch -Sleep $script:sleep -Log $script:log -DelayMinMs 0 -DelayMaxMs 1
            $result.SeenIds.Contains('a') | Should -BeTrue
            $result.SeenIds.Contains('b') | Should -BeTrue
            $result.SeenIds.Contains('nope') | Should -BeFalse
        }
    }
}
