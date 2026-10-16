BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Set-DFRoleFallback' {
    BeforeEach {
        Reset-DFTestSession
        $script:SavedPager = $Env:DF_T_FB_PAGER
        Remove-Item Env:DF_T_FB_PAGER -ErrorAction Ignore
        $file = Join-Path $TestDrive 'roles-fb.json'
        '{ "tpager": { "kind": "single", "hook": "Initialize-DFRoleTpager", "reserved": { "env": ["DF_T_FB_PAGER"] },
           "fallback": { "env": { "DF_T_FB_PAGER": "more" } } } }' | Set-Content $file
        $script:Roles = Get-DFRoleDb -Path $file
        $script:Member = ConvertTo-DFToolRecord ('{ "name": "tp", "executable": "tp.exe", "roles": { "tpager": {} } }' | ConvertFrom-Json)
    }
    AfterEach { if ($null -eq $script:SavedPager) { Remove-Item Env:DF_T_FB_PAGER -ErrorAction Ignore } else { $Env:DF_T_FB_PAGER = $script:SavedPager } }

    It 'sets the fallback when the role has no winner' {
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @() | Should -Be @('tpager')
        $Env:DF_T_FB_PAGER | Should -Be 'more'
    }
    It 'does nothing when the role has a winner' {
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{ tpager = [pscustomobject]@{ Winner = 'tp' } } -SessionTools @($script:Member) |
            Should -BeNullOrEmpty
        $Env:DF_T_FB_PAGER | Should -BeNullOrEmpty
    }
    It 'does not apply the fallback while a member is active in the session' {
        Mock Test-DFToolActive { $true } -ParameterFilter { $Name -eq 'tp' }
        Mock Test-DFToolActive { $false }
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @($script:Member) | Should -BeNullOrEmpty
        $Env:DF_T_FB_PAGER | Should -BeNullOrEmpty
    }
    It 'keeps a PAGER set outside DotForge' {
        $Env:DF_T_FB_PAGER = 'mine'
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @() | Out-Null
        $Env:DF_T_FB_PAGER | Should -Be 'mine'
    }
}
