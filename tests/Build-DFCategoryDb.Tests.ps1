BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
}

Describe 'Build-DFCategoryDb' {
    BeforeEach {
        $script:CategoriesDir = Join-Path $TestDrive 'categories'
        # $TestDrive is shared across every It in this Describe (Pester v5 does
        # not mint a fresh TestDrive per It), so fragment files added by one
        # test (e.g. the duplicate-key and invalid-doc tests below) would
        # otherwise leak into later tests. Start each test from a clean dir.
        if (Test-Path $script:CategoriesDir) { Remove-Item $script:CategoriesDir -Recurse -Force }
        New-Item -ItemType Directory -Path $script:CategoriesDir -Force | Out-Null
        $script:OutPath = Join-Path $TestDrive 'out.json'

        @'
{
  // comment should be stripped
  "function": ["search", "editor"],
  "worksWith": ["text"]
}
'@ | Set-Content (Join-Path $script:CategoriesDir 'taxonomy.jsonc')

        @'
{ "ripgrep": { "function": ["search"], "worksWith": ["text"], "interface": "cli" } }
'@ | Set-Content (Join-Path $script:CategoriesDir 'a-fragment.jsonc')

        @'
{ "micro": { "function": ["editor"], "interface": "cli" } }
'@ | Set-Content (Join-Path $script:CategoriesDir 'b-fragment.jsonc')
    }

    It 'merges fragments, strips comments, and emits a schema-valid document' {
        & "$PSScriptRoot/../build/Build-DFCategoryDb.ps1" -CategoriesDir $script:CategoriesDir -OutPath $script:OutPath
        $doc = Get-Content $script:OutPath -Raw | ConvertFrom-Json
        $doc.tools.ripgrep.function | Should -Contain 'search'
        $doc.tools.micro.function | Should -Contain 'editor'
        $errs = $null
        Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs) | Should -BeTrue
    }

    It 'stamps updated to today (UTC, yyyy-MM-dd)' {
        & "$PSScriptRoot/../build/Build-DFCategoryDb.ps1" -CategoriesDir $script:CategoriesDir -OutPath $script:OutPath
        $doc = Get-Content $script:OutPath -Raw | ConvertFrom-Json
        $doc.updated | Should -Be ([datetime]::UtcNow.ToString('yyyy-MM-dd'))
    }

    It 'throws on a duplicate tool key across fragment files' {
        @'
{ "ripgrep": { "function": ["search"], "interface": "cli" } }
'@ | Set-Content (Join-Path $script:CategoriesDir 'c-fragment.jsonc')
        { & "$PSScriptRoot/../build/Build-DFCategoryDb.ps1" -CategoriesDir $script:CategoriesDir -OutPath $script:OutPath } |
            Should -Throw '*ripgrep*'
    }

    It 'throws with the validator''s messages when the merged document is invalid' {
        @'
{ "broken": { "function": ["not-a-real-function"], "interface": "cli" } }
'@ | Set-Content (Join-Path $script:CategoriesDir 'd-fragment.jsonc')
        { & "$PSScriptRoot/../build/Build-DFCategoryDb.ps1" -CategoriesDir $script:CategoriesDir -OutPath $script:OutPath } |
            Should -Throw '*not-a-real-function*'
    }

    It 'sorts tool keys alphabetically for a deterministic diff' {
        & "$PSScriptRoot/../build/Build-DFCategoryDb.ps1" -CategoriesDir $script:CategoriesDir -OutPath $script:OutPath
        $raw = Get-Content $script:OutPath -Raw
        $raw.IndexOf('"micro"') | Should -BeLessThan $raw.IndexOf('"ripgrep"')
    }
}

Describe 'the shipped data/tool-categories.json' {
    It 'validates against the schema' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-categories.json" -Raw | ConvertFrom-Json
        $errs = $null
        Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs) | Should -BeTrue -Because ($errs -join '; ')
    }

    It 'contains every tool curated in Tools/*.json' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-categories.json" -Raw | ConvertFrom-Json
        $curatedNames = Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object BaseName
        foreach ($name in $curatedNames) {
            $doc.tools.PSObject.Properties.Name | Should -Contain $name
        }
    }
}

Describe 'the shipped data/tool-categories.json extras' {
    It 'includes the extras fragment tools alongside the curated 32' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-categories.json" -Raw | ConvertFrom-Json
        $doc.tools.PSObject.Properties.Name | Should -Contain 'starship'
        $doc.tools.PSObject.Properties.Name | Should -Contain 'rga'
        ($doc.tools.PSObject.Properties.Name).Count | Should -BeGreaterOrEqual 70
    }

    It 'no extras entry has an ids field' {
        $doc = Get-Content "$PSScriptRoot/../data/tool-categories.json" -Raw | ConvertFrom-Json
        $extrasNames = (Get-Content "$PSScriptRoot/../build/categories/extras.jsonc" -Raw |
            ForEach-Object { $_ -replace '(?m)^(?<code>(?:[^"]|"[^"]*")*?)//', '$1' } | ConvertFrom-Json).PSObject.Properties.Name
        foreach ($name in $extrasNames) {
            $doc.tools.$name.PSObject.Properties.Name | Should -Not -Contain 'ids'
        }
    }
}
