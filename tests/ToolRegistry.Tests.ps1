#Requires -Version 7.2
# data/tool-registry.json holds every shipped tool record, already validated and
# normalized, so startup doesn't re-check 45 JSON files. If this fails, a tool
# record changed without regenerating it: run
#   ./build/Build-DFToolRegistry.ps1
# and commit the result.

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Repo = Split-Path $PSScriptRoot -Parent
}

Describe 'data/tool-registry.json' {
    It 'matches what build/Build-DFToolRegistry.ps1 generates' {
        $fresh = Join-Path $TestDrive 'tool-registry.json'
        pwsh -NoProfile -NonInteractive -File (Join-Path $script:Repo 'build' 'Build-DFToolRegistry.ps1') -OutputPath $fresh | Out-Null
        Test-Path $fresh | Should -BeTrue
        Test-Path (Join-Path $script:Repo 'data' 'tool-registry.json') | Should -BeTrue
        (Get-Content $fresh -Raw) -replace '\r', '' | Should -Be ((Get-Content (Join-Path $script:Repo 'data' 'tool-registry.json') -Raw) -replace '\r', '')
    }
    It 'gives each tool the same record as reading its JSON the slow way' {
        foreach ($f in Get-ChildItem (Join-Path $script:Repo 'Tools') -Filter '*.json') {
            $slow = ConvertTo-DFToolRecord (Get-Content $f.FullName -Raw | ConvertFrom-Json)
            $fast = Read-DFToolRecordFile -Path $f.FullName
            ($fast | ConvertTo-Json -Depth 20 -Compress) | Should -Be ($slow | ConvertTo-Json -Depth 20 -Compress) -Because $f.Name
        }
    }
}

Describe 'Read-DFToolRecordFile and the registry' {
    BeforeEach { $script:DFToolRegistry = $null }
    It 'uses the registry for an unchanged shipped record, without validating it' {
        Mock Test-DFToolSchema { $true }
        $r = Read-DFToolRecordFile -Path (Join-Path $script:Repo 'Tools' 'bat.json')
        $r.name | Should -Be 'bat'
        Should -Invoke Test-DFToolSchema -Times 0
    }
    It 'reads and validates a record whose JSON differs from the registry (an edit not yet rebuilt)' {
        $p = Join-Path $TestDrive 'bat.json'
        (Get-Content (Join-Path $script:Repo 'Tools' 'bat.json') -Raw) -replace '"description": "[^"]*"', '"description": "edited"' | Set-Content $p
        $r = Read-DFToolRecordFile -Path $p
        $r.description | Should -Be 'edited'
    }
    It 'matches regardless of line endings' {
        $p = Join-Path $TestDrive 'crlf' 'bat.json'
        New-Item -ItemType Directory (Split-Path $p) -Force | Out-Null
        [IO.File]::WriteAllText($p, ((Get-Content (Join-Path $script:Repo 'Tools' 'bat.json') -Raw) -replace '\r?\n', "`r`n"))
        Mock Test-DFToolSchema { $true }
        $null = Read-DFToolRecordFile -Path $p
        Should -Invoke Test-DFToolSchema -Times 0
    }
}
