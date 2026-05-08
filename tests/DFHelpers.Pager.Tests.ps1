BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFPagerExe.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
}

Describe 'Invoke-DFWithPager' {
    BeforeEach {
        $script:SavedPager = $Env:Pager
        $Env:Pager = $null
    }
    AfterEach { $Env:Pager = $script:SavedPager }

    Context 'no pager set' {
        It 'passes pipeline input through to stdout' {
            $result = 'hello', 'world' | Invoke-DFWithPager
            $result | Should -Be @('hello', 'world')
        }

        It 'runs scriptblock and outputs result' {
            $result = Invoke-DFWithPager { 'from-block' }
            $result | Should -Be 'from-block'
        }

        It 'returns nothing for empty scriptblock' {
            $result = Invoke-DFWithPager { }
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'pager set' {
        It 'invokes Invoke-DFPagerExe when $Env:Pager is set' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            'hello' | Invoke-DFWithPager
            Should -Invoke Invoke-DFPagerExe -Times 1
        }

        It 'passes the pager string to Invoke-DFPagerExe' {
            $Env:Pager = 'less -R'
            Mock Invoke-DFPagerExe { }
            'hello' | Invoke-DFWithPager
            Should -Invoke Invoke-DFPagerExe -ParameterFilter { $Pager -eq 'less -R' }
        }

        It 'does not invoke pager for empty input' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            Invoke-DFWithPager { }
            Should -Invoke Invoke-DFPagerExe -Times 0
        }
    }
}
