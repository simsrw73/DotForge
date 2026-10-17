BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Pager = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['pager']
    function script:Get-PagerEnv([string]$Name) {
        $tool = Get-DFTestToolRecord $Name
        Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool
    }
}

# The exact command each pager runs as PAGER, so a mapping change is a deliberate edit.
Describe 'pager behaviors' {
    BeforeEach { Set-DFTestXdg; Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore; Set-DFTestConfig $null; Mock ConvertTo-DFToolExePathToken { $Tool.name } }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'less' { (Get-PagerEnv 'less')['PAGER'] | Should -Be 'less -F -R -X --mouse' }
    It 'moor' { (Get-PagerEnv 'moor')['PAGER'] | Should -Be 'moor -quit-if-one-screen -no-clear-on-exit -mousemode scroll' }
    It 'sets BAT_PAGER the same: <_>' -ForEach @('less', 'moor') {
        $built = Get-PagerEnv $_
        $built['BAT_PAGER'] | Should -Be $built['PAGER']
    }
    It 'falls back to more' {
        $script:Pager.fallback.env.PAGER | Should -Be 'more'
        $script:Pager.fallback.env.BAT_PAGER | Should -Be 'more'
    }
    It 'reserves PAGER and BAT_PAGER' { $script:Pager.reserved.env | Should -Be @('PAGER', 'BAT_PAGER') }
    It 'moor''s MOOR keeps only its style' { (Get-DFTestToolRecord 'moor').theme.env.MOOR | Should -Be '-style {theme}' }
    It 'less PAGER uses the native-build token' {
        Mock ConvertTo-DFToolExePathToken { 'C:/tools/less.exe' } -ParameterFilter { $Tool.name -eq 'less' }
        (Get-PagerEnv 'less')['PAGER'] | Should -BeLike 'C:/tools/less.exe *'
    }
}

Describe 'pager fallback in Get-DFRole' {
    BeforeEach { Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'shows more as the fallback when no pager is a candidate' {
        Mock Test-DFToolAvailable { $false }
        $role = Get-DFRole -Name pager
        $role.Winner | Should -BeNullOrEmpty
        $role.Fallback.PAGER | Should -Be 'more'
        $role.Fallback.BAT_PAGER | Should -Be 'more'
    }
}
