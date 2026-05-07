BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"

    # Build a controlled tools directory
    $script:TmpTools = Join-Path $TestDrive 'tools'
    New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

    @'
{ "name": "alpha", "executable": "alpha.exe", "description": "First tool",
  "tags": ["viewer", "pager"] }
'@ | Set-Content (Join-Path $script:TmpTools 'alpha.json')

    @'
{ "name": "beta", "executable": "beta.exe", "description": "Second viewer",
  "tags": ["viewer"] }
'@ | Set-Content (Join-Path $script:TmpTools 'beta.json')

    @'
{ "name": "gamma", "executable": "gamma.exe", "description": "Search utility",
  "tags": ["search"] }
'@ | Set-Content (Join-Path $script:TmpTools 'gamma.json')
}

Describe 'Get-DFTool' {
    BeforeEach { $script:DFToolDb = $null }

    It 'returns all tools when called with no parameters' {
        $results = Get-DFTool -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 3
    }

    It 'returns one tool by exact name' {
        $result = Get-DFTool -Name 'alpha' -ToolsPath $script:TmpTools
        $result.name | Should -Be 'alpha'
    }

    It 'returns null for an unknown name' {
        $result = Get-DFTool -Name 'unknown' -ToolsPath $script:TmpTools
        $result | Should -BeNullOrEmpty
    }

    It 'returns all tools with a matching tag' {
        $results = Get-DFTool -Tag 'viewer' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 2
        @($results).name | Should -Contain 'alpha'
        @($results).name | Should -Contain 'beta'
    }

    It 'returns nothing when no tools match the tag' {
        $results = Get-DFTool -Tag 'nonexistent' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 0
    }
}

Describe 'Find-DFTool' {
    BeforeEach { $script:DFToolDb = $null }

    It 'finds tools by name pattern' {
        $results = Find-DFTool -Pattern 'alph' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'alpha'
    }

    It 'finds tools by description pattern' {
        $results = Find-DFTool -Pattern 'viewer' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'beta'
    }

    It 'finds tools by tag pattern' {
        $results = Find-DFTool -Pattern 'search' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'gamma'
    }

    It 'returns empty when pattern matches nothing' {
        $results = Find-DFTool -Pattern 'zzznomatch' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 0
    }
}
