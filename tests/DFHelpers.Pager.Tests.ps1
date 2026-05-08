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
            # Use -WarningAction SilentlyContinue: Pester pipes the scriptblock literal
            # as pipeline input, which legitimately triggers the dual-input warning.
            $result = Invoke-DFWithPager { 'from-block' } -WarningAction SilentlyContinue
            $result | Should -Be 'from-block'
        }

        It 'returns nothing for empty scriptblock' {
            $result = Invoke-DFWithPager { } -WarningAction SilentlyContinue
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

        It 'forwards collected lines to Invoke-DFPagerExe' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            'hello', 'world' | Invoke-DFWithPager
            Should -Invoke Invoke-DFPagerExe -ParameterFilter { $Lines -contains 'hello' }
        }

        It 'does not invoke pager for empty input' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            Invoke-DFWithPager { } -WarningAction SilentlyContinue
            Should -Invoke Invoke-DFPagerExe -Times 0
        }
    }
}

Describe 'Invoke-DFPagerExe' {
    BeforeAll {
        # Use List<string> to avoid PS scalar-coercion when a single arg is splatted.
        # Args starting with - are treated as PS named params when splatted to a function,
        # which is not how real external pagers work. Tests use equivalent positional args.
        $Global:DFTestPagerArgs  = [System.Collections.Generic.List[string]]::new()
        $Global:DFTestPagerInput = [System.Collections.Generic.List[string]]::new()
        function global:dftest_pager {
            # Index-based loop avoids PS string char-enumeration for a single scalar arg.
            $all = @($args)
            for ($idx = 0; $idx -lt $all.Count; $idx++) {
                $Global:DFTestPagerArgs.Add([string]$all[$idx])
            }
            foreach ($i in $input) { $Global:DFTestPagerInput.Add($i) }
        }
    }
    AfterAll {
        Remove-Item function:global:dftest_pager -ErrorAction Ignore
        Remove-Variable -Name DFTestPagerArgs, DFTestPagerInput -Scope Global -ErrorAction Ignore
    }
    AfterEach {
        $Global:DFTestPagerArgs.Clear()
        $Global:DFTestPagerInput.Clear()
    }

    It 'pipes all lines to the pager executable' {
        Invoke-DFPagerExe -Lines @('hello', 'world') -Pager 'dftest_pager'
        $Global:DFTestPagerInput | Should -Contain 'hello'
        $Global:DFTestPagerInput | Should -Contain 'world'
    }

    It 'passes a single arg from the pager string to the executable' {
        Invoke-DFPagerExe -Lines @('line') -Pager 'dftest_pager arg1'
        ($Global:DFTestPagerArgs -join ',') | Should -Be 'arg1'
    }

    It 'passes multiple args from the pager string to the executable' {
        Invoke-DFPagerExe -Lines @('line') -Pager 'dftest_pager paging=always color=always'
        ($Global:DFTestPagerArgs -join ',') | Should -Be 'paging=always,color=always'
    }

    It 'emits a warning when pager string contains a quoted argument' {
        # Pager arg begins with " (not -) so it is passed as a positional string to dftest_pager
        Invoke-DFPagerExe -Lines @('line') -Pager 'dftest_pager "--theme=Dark"' -WarningVariable w
        $w | Should -Not -BeNullOrEmpty
    }
}
