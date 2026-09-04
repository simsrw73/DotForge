BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
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

    It 'returns empty hashtable when ToolsPath does not exist' {
        $db = Import-DFToolDb -ToolsPath 'C:\nonexistent\tools'
        $db | Should -BeOfType [hashtable]
        $db.Count | Should -Be 0
    }
}
