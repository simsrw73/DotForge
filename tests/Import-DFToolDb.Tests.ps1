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

    It 'returns cached result on second call without -Force' {
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        # Modify the tools dir — second call should NOT pick this up
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools
        $db2.ContainsKey('extra') | Should -BeFalse
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
