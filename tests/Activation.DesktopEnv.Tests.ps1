BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# An active tool's status says which of its desktop variables desktop apps lack
# (docs/superpowers/specs/2026-10-26-desktop-variables-design.md, Status note).
Describe 'Activation: desktop variables note' -Skip:(-not $IsWindows) {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        [Environment]::SetEnvironmentVariable('DESK_A', $null, 'Process')
        @{ name = 'deska'; executable = 'Pester'; type = 'module'
           xdg = @{ method = 'env'; vars = @{ DESK_A = '${XDG_CONFIG_HOME}/deska' }; native = @{ DESK_A = @() } }
           desktop = @('DESK_A') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'deska.json')
        @{ name = 'plainz'; executable = 'Pester'; type = 'module' } | ConvertTo-Json | Set-Content (Join-Path $script:UserTools 'plainz.json')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('DESK_A', $null, 'Process')
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'an active tool''s status says which desktop variables desktop apps lack' {
        Register-DFTool -Name deska 3>$null
        (Get-DFToolStatus deska).State | Should -Be 'Active'
        (Get-DFToolStatus deska).Detail | Should -Match "DESK_A isn't set for desktop apps; Set-DFDesktopEnv deska sets it"
    }
    It 'a requested tool that isn''t installed gets the note too' {
        @{ name = 'deskm'; executable = 'no-such-deskm.exe'
           xdg = @{ method = 'env'; vars = @{ DESK_A = '${XDG_CONFIG_HOME}/deska' }; native = @{ DESK_A = @() } }
           desktop = @('DESK_A') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'deskm.json')
        Register-DFTool -Name deskm 3>$null 6>$null
        (Get-DFToolStatus deskm).State | Should -Be 'Missing'
        (Get-DFToolStatus deskm).Detail | Should -Match "DESK_A isn't set for desktop apps"
    }
    It 'no note once the value is set' {
        Set-DFDesktopEnvValue -Name DESK_A -Value (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'deska'))
        Register-DFTool -Name deska 3>$null
        "$((Get-DFToolStatus deska).Detail)" | Should -Not -Match 'desktop apps'
    }
    It 'a record without desktop reads no registry' {
        Mock Get-DFDesktopEnvValue { }
        Register-DFTool -Name plainz 3>$null
        Should -Invoke Get-DFDesktopEnvValue -Times 0 -Exactly
    }
}
