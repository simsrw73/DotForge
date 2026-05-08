BeforeAll {
    function Invoke-DFWithPager {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)][string]$InputObject,
            [scriptblock]$Command
        )
        process { $InputObject }
        end { if ($Command) { & $Command } }
    }
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Private/Get-DFHelpTopicList.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Help.ps1"
}

Describe 'Invoke-DFHelp' {
    BeforeEach {
        $script:SavedNoColor = $Env:NO_COLOR
        $Env:NO_COLOR = $null
    }
    AfterEach { $Env:NO_COLOR = $script:SavedNoColor }

    It 'calls Get-Help with the supplied name' {
        Mock Get-Help { 'help text' | Out-String }
        Mock Invoke-DFWithPager { }
        Invoke-DFHelp 'Get-Process'
        Should -Invoke Get-Help -ParameterFilter { $Name -eq 'Get-Process' }
    }

    It 'emits no ANSI codes when $Env:NO_COLOR is set' {
        $Env:NO_COLOR = '1'
        Mock Get-Help { "SYNOPSIS`nsome text" | Out-String }
        $result = Invoke-DFHelp 'Get-Process'
        ($result -join '') | Should -Not -Match "`e\["
    }

    It 'colorizes SYNOPSIS header when $Env:NO_COLOR is not set and VT is supported' {
        Mock Get-Help { "SYNOPSIS`nsome text" | Out-String }
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'Get-Process'
        ($result -join '') | Should -Match "`e\["
    }
}

Describe 'Select-DFVerb' {
    It 'outputs the verb name from the selected line' {
        Mock Invoke-DFFzf { 'Lifecycle            Start' }
        $result = Select-DFVerb
        $result | Should -Be 'Start'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFVerb | Should -BeNullOrEmpty
    }
}

Describe 'Select-DFModule' {
    It 'outputs the module name from the selected line' {
        Mock Invoke-DFFzf { 'PSReadLine                               2.3.4      Cmdlets for great...' }
        $result = Select-DFModule
        $result | Should -Be 'PSReadLine'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFModule | Should -BeNullOrEmpty
    }
}

Describe 'Select-DFCommand' {
    It 'outputs the command name from the selected line' {
        Mock Invoke-DFFzf { 'Get-Process                                        Cmdlet          Microsoft.PowerShell.Management' }
        $result = Select-DFCommand
        $result | Should -Be 'Get-Process'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFCommand | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFHelp regex' {
    BeforeEach {
        $script:SavedNoColor = $Env:NO_COLOR
        $Env:NO_COLOR = $null
    }
    AfterEach { $Env:NO_COLOR = $script:SavedNoColor }

    It 'colorizes any all-caps header, not just hardcoded ones' {
        Mock Get-Help { "CUSTOMHEADER`nsome content" | Out-String }
        Mock Invoke-DFWithPager { process { $InputObject } }
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'anything'
        ($result -join '') | Should -Match "`e\[.*CUSTOMHEADER"
    }

    It 'does not colorize indented content lines' {
        Mock Get-Help { "SYNOPSIS`n    indented content line" | Out-String }
        Mock Invoke-DFWithPager { process { $InputObject } }
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'anything'
        ($result -join '') | Should -Not -Match "`e\[.*indented"
    }
}

Describe 'Select-DFHelpTopic' {
    BeforeEach {
        $script:SavedXdg = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdg }

    It 'calls Invoke-DFHelp with the selected topic name' {
        Mock Get-DFHelpTopicList { @("Get-Process`tCmdlet", "about_Parsing`tHelpFile") }
        Mock Invoke-DFFzf { "Get-Process`tCmdlet" }
        Mock Invoke-DFHelp { }
        fh
        Should -Invoke Invoke-DFHelp -ParameterFilter { $Name -eq 'Get-Process' }
    }

    It 'does not call Invoke-DFHelp when user cancels' {
        Mock Get-DFHelpTopicList { @("Get-Process`tCmdlet") }
        Mock Invoke-DFFzf { $null }
        Mock Invoke-DFHelp { }
        fh
        Should -Invoke Invoke-DFHelp -Times 0
    }

    It '-Category filters to matching topics only' {
        Mock Get-DFHelpTopicList {
            @("Get-Process`tCmdlet", "about_Parsing`tHelpFile", "Get-Item`tCmdlet")
        }
        Mock Invoke-DFFzf { $null }
        fh -Category HelpFile
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $InputItems.Count -eq 1 -and $InputItems[0] -like 'about_Parsing*'
        }
    }

    It '-Force is passed through to Get-DFHelpTopicList' {
        Mock Get-DFHelpTopicList { @() }
        Mock Invoke-DFFzf { $null }
        fh -Force
        Should -Invoke Get-DFHelpTopicList -ParameterFilter { $Force }
    }
}
