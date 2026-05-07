BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Update-DFCompletions.ps1"
}

Describe 'Update-DFCompletions' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedCache  = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:TmpTools    = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{ "name": "dyntool", "executable": "dyntool.exe",
  "completions": { "type": "dynamic", "command": "dyntool completions powershell" } }
'@ | Set-Content (Join-Path $script:TmpTools 'dyntool.json')

        @'
{ "name": "statictool", "executable": "statictool.exe",
  "completions": { "type": "static", "flags": ["--verbose"] } }
'@ | Set-Content (Join-Path $script:TmpTools 'statictool.json')
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
        $script:DFToolDb = $null
    }

    It 'deletes the cache file for a dynamic-completion tool' {
        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'dyntool.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# old completions' | Set-Content $cacheFile

        Mock Get-Command { $null }
        Update-DFCompletions -ToolsPath $script:TmpTools
        Test-Path $cacheFile | Should -BeFalse
    }

    It 'does not touch cache files for static-completion tools' {
        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'statictool.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# static cache' | Set-Content $cacheFile

        Mock Get-Command { $null }
        Update-DFCompletions -ToolsPath $script:TmpTools
        Test-Path $cacheFile | Should -BeTrue
    }

    It 'filters to named tools when -Name is specified' {
        @'
{ "name": "tool2", "executable": "tool2.exe",
  "completions": { "type": "dynamic", "command": "tool2 completions ps" } }
'@ | Set-Content (Join-Path $script:TmpTools 'tool2.json')

        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# dyntool' | Set-Content (Join-Path $cacheDir 'dyntool.ps1')
        '# tool2'   | Set-Content (Join-Path $cacheDir 'tool2.ps1')

        Mock Get-Command { $null }
        Update-DFCompletions -Name 'dyntool' -ToolsPath $script:TmpTools

        Test-Path (Join-Path $cacheDir 'dyntool.ps1') | Should -BeFalse
        Test-Path (Join-Path $cacheDir 'tool2.ps1')   | Should -BeTrue
    }

    It 'does not throw when no cache files exist' {
        Mock Get-Command { $null }
        { Update-DFCompletions -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'does not throw when tools directory is empty' {
        $emptyTools = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Force -Path $emptyTools | Out-Null
        { Update-DFCompletions -ToolsPath $emptyTools } | Should -Not -Throw
    }
}
