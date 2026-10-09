BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Import-DFToolDb' {
    BeforeEach {
        $script:DFToolDb = $null  # reset cache between tests

        # Build a temp tools directory with controlled JSON content
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        $validJson = @'
{ "name": "mytool", "executable": "mytool.exe" }
'@
        $validJson | Set-Content (Join-Path $script:TmpTools 'mytool.json')
    }

    It 'returns a hashtable keyed by tool name' {
        $db = Import-DFToolDb -ToolsPath $script:TmpTools
        $db | Should -BeOfType [hashtable]
        $db.ContainsKey('mytool') | Should -BeTrue
    }

    It 'always does a fresh read when -ToolsPath is given explicitly, even without -Force' {
        # An explicit -ToolsPath must never trust the shared cache -- a caller
        # who names their own directory (tests, a future sub-registry) always
        # sees that directory's current contents.
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools
        $db2.ContainsKey('extra') | Should -BeTrue
    }

    It 'caches the default-location result across calls with no -ToolsPath' {
        # Seed the shared cache with a sentinel and call with NO -ToolsPath at
        # all -- if the default-location branch is really cache-backed, the
        # sentinel comes back untouched (no directory is ever scanned).
        $script:DFToolDb = @{ sentinel = $true }
        $db = Import-DFToolDb
        $db.ContainsKey('sentinel') | Should -BeTrue
    }

    It 'never overwrites the shared cache when -ToolsPath is given explicitly' {
        $script:DFToolDb = @{ sentinel = $true }
        Import-DFToolDb -ToolsPath $script:TmpTools | Out-Null
        $script:DFToolDb.ContainsKey('sentinel') | Should -BeTrue
    }

    It 'reloads when -Force is specified' {
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools -Force
        $db2.ContainsKey('extra') | Should -BeTrue
    }

    It 'emits a warning and skips files that fail schema validation' {
        '{ "missingName": true }' |
            Set-Content (Join-Path $script:TmpTools 'bad.json')
        $db = Import-DFToolDb -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $db.ContainsKey('mytool') | Should -BeTrue
        $warns | Should -Not -BeNullOrEmpty
    }

    Context '-Name (read only the requested records)' {
        BeforeEach {
            '{ "name": "other", "executable": "other.exe" }' | Set-Content (Join-Path $script:TmpTools 'other.json')
            '{ "name": "broken" }' | Set-Content (Join-Path $script:TmpTools 'broken.json')
        }
        It 'returns only the named tools and never opens the other files' {
            # Reading either of these would warn (unparseable / schema error), so a
            # clean warning stream proves they were never opened. No mocking needed.
            'not json {' | Set-Content (Join-Path $script:TmpTools 'other.json')
            $db = Import-DFToolDb -ToolsPath $script:TmpTools -Name 'mytool' -WarningVariable w 3>$null
            @($db.Keys) | Should -Be @('mytool')
            $w | Should -BeNullOrEmpty
        }
        It 'matches names case-insensitively' {
            (Import-DFToolDb -ToolsPath $script:TmpTools -Name 'MYTOOL').Contains('mytool') | Should -BeTrue
        }
        It 'warns and skips a named tool whose file is missing or invalid' {
            $db = Import-DFToolDb -ToolsPath $script:TmpTools -Name 'mytool', 'nope', 'broken' -WarningVariable w 3>$null
            @($db.Keys) | Should -Be @('mytool')
            "$w" | Should -Match 'nope'
            "$w" | Should -Match 'broken'
        }
    }

    Context 'Get-DFToolNames' {
        It 'lists tool names from file names without reading any file' {
            $dir = Join-Path $TestDrive 'names-only'   # fresh: $TestDrive outlives each test
            New-Item -ItemType Directory $dir -Force | Out-Null
            'x' | Set-Content (Join-Path $dir 'mytool.json')
            'x' | Set-Content (Join-Path $dir 'other.json')
            Mock Get-Content { throw 'must not read' }
            Get-DFToolNames -ToolsPath $dir | Sort-Object | Should -Be @('mytool', 'other')
        }
        It 'matches every shipped record''s name to its file name, so file names can stand in for names' {
            $mismatch = Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' |
                Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).name -cne $_.BaseName } | ForEach-Object Name
            @($mismatch) | Should -BeNullOrEmpty
        }
    }

    It 'returns empty hashtable when ToolsPath does not exist' {
        $db = Import-DFToolDb -ToolsPath 'C:\nonexistent\tools'
        $db | Should -BeOfType [hashtable]
        $db.Count | Should -Be 0
    }
}
