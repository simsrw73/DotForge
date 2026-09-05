BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
}

Describe 'New-DFToolPickerFunction' {
    AfterEach {
        Remove-Item 'function:global:Select-TestThing' -ErrorAction Ignore
        Remove-Alias ftt -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Select-TestPathThing' -ErrorAction Ignore
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
}
