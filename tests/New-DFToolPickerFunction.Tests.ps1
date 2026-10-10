BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'New-DFToolPickerFunction' {
    AfterEach {
        Remove-DFTestGlobal -Function 'Select-TestThing'
        Remove-Alias ftt -Force -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'Select-TestPathThing'
        Remove-DFTestGlobal -Function 'Invoke-TestPickerList'
        Remove-DFTestGlobal -Function 'Invoke-DFPicker'
        Remove-Variable -Name 'DFTestCapturedList', 'DFTestListArguments' -Scope Global -ErrorAction Ignore
    }

    It 'installs a global function and alias for a simple picker' {
        $tool = @'
{
  "name": "t",
  "picker": {
    "alias": "ftt",
    "function": "Select-TestThing",
    "list": "echo one",
    "header": "pick one",
    "action": "output"
  }
}
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        (Get-Command Select-TestThing -CommandType Function -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        (Get-Alias ftt).Definition | Should -Be 'Select-TestThing'
    }

    It 'does not create an alias when picker.alias is absent' {
        $tool = @'
{ "name": "t", "picker": { "function": "Select-TestThing", "list": "echo one" } }
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        (Get-Command Select-TestThing -CommandType Function -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
    }

    It 'does nothing when Tool has no picker' {
        $tool = '{ "name": "nopicker" }' | ConvertFrom-Json
        { New-DFToolPickerFunction -Tool $tool } | Should -Not -Throw
    }

    It 'does nothing when picker is explicitly null' {
        $tool = '{ "name": "nullpicker", "picker": null }' | ConvertFrom-Json
        { New-DFToolPickerFunction -Tool $tool } | Should -Not -Throw
    }

    It 'does nothing when picker lacks function or list' {
        $tool = '{ "name": "t", "picker": { "alias": "ftt" } }' | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        (Get-Alias ftt -ErrorAction Ignore) | Should -BeNullOrEmpty
    }

    It 'generates a -Path-accepting function when list_accepts_path is true' {
        $tool = @'
{
  "name": "t",
  "picker": {
    "function": "Select-TestPathThing",
    "list": "eza --icons -1",
    "list_accepts_path": true,
    "action": "output"
  }
}
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        $cmd = Get-Command Select-TestPathThing -CommandType Function -ErrorAction Ignore
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.ContainsKey('Path') | Should -BeTrue
    }

    It 'passes the path as the only argument to a single-word list command' {
        function global:Invoke-TestPickerList { $global:DFTestListArguments = @($args) }
        # The generated picker is a global function, so a global stand-in (not a Mock) is what it calls.
        Set-Item function:global:Invoke-DFPicker -Value {
            param([scriptblock]$List)
            $global:DFTestCapturedList = $List
        }
        $tool = '{ "name": "t", "picker": { "function": "Select-TestPathThing", "list": "Invoke-TestPickerList", "list_accepts_path": true } }' | ConvertFrom-Json

        New-DFToolPickerFunction -Tool $tool
        Select-TestPathThing -Path 'C:\test-path'
        & $global:DFTestCapturedList

        $global:DFTestListArguments | Should -Be @('C:\test-path')
    }

    It 'preserves quoted arguments before appending the path to a list command' {
        function global:Invoke-TestPickerList { $global:DFTestListArguments = @($args) }
        # The generated picker is a global function, so a global stand-in (not a Mock) is what it calls.
        Set-Item function:global:Invoke-DFPicker -Value {
            param([scriptblock]$List)
            $global:DFTestCapturedList = $List
        }
        $tool = '{ "name": "t", "picker": { "function": "Select-TestPathThing", "list": "Invoke-TestPickerList --ignore-glob \"a b\"", "list_accepts_path": true } }' | ConvertFrom-Json

        New-DFToolPickerFunction -Tool $tool
        Select-TestPathThing -Path 'C:\test-path'
        & $global:DFTestCapturedList

        $global:DFTestListArguments | Should -Be @('--ignore-glob', 'a b', 'C:\test-path')
    }

    It 'uses . as the default path for a path-accepting list command' {
        function global:Invoke-TestPickerList { $global:DFTestListArguments = @($args) }
        # The generated picker is a global function, so a global stand-in (not a Mock) is what it calls.
        Set-Item function:global:Invoke-DFPicker -Value {
            param([scriptblock]$List)
            $global:DFTestCapturedList = $List
        }
        $tool = '{ "name": "t", "picker": { "function": "Select-TestPathThing", "list": "Invoke-TestPickerList", "list_accepts_path": true } }' | ConvertFrom-Json

        New-DFToolPickerFunction -Tool $tool
        Select-TestPathThing
        & $global:DFTestCapturedList

        $global:DFTestListArguments | Should -Be @('.')
    }
}
