BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:New-InstallTools {
        $dir = Join-Path $TestDrive "it-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $dir | Out-Null
        @{
            scoop = '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'
            npm   = '{ "name": "npm", "executable": "npm.cmd", "roles": { "js-package-manager": { "priority": 30 } }, "packages": { "scoop": "nodejs" }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"], "batch": true } }'
            pnpm  = '{ "name": "pnpm", "executable": "pnpm.cmd", "roles": { "js-package-manager": { "priority": 20 } }, "packages": { "scoop": "pnpm" }, "installs": { "from": "npm", "command": ["pnpm","add","-g","{id}"], "batch": true } }'
            glow  = '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow" } }'
            ish   = '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }'
        }.GetEnumerator() | ForEach-Object { Set-Content (Join-Path $dir "$($_.Key).json") $_.Value }
        $dir
    }
}

Describe 'Install-DFTool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Tools = New-InstallTools
        $script:Installed = @('scoop.cmd')
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Test-DFToolAvailable { $Executable -in $script:Installed }
        Mock Invoke-DFInstallCommand {
            $script:Calls.Add($Argv -join ' ')
            # An install makes its tools "installed".
            $exe = @{ glow = 'glow.exe'; '@microsoft/inshellisense' = 'is.cmd'; nodejs = 'npm.cmd'; pnpm = 'pnpm.cmd' }
            if ($Argv[1] -in 'install', 'i', 'add') { $script:Installed += @($Argv | Select-Object -Skip 2 | ForEach-Object { $exe[$_] } | Where-Object { $_ }) }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock Update-DFPathFromRegistry { }
        Mock Test-DFElevated { $false }
        Mock Write-DFConflictNotice { }
        Mock Test-DFInteractiveHost { $false }
        Mock Read-DFInstallChoice { $Default }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It '-Missing installs the session''s missing tools and activates them' {
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        $r = Install-DFTool -Missing -UseDefaults -ToolsPath $script:Tools 6>$null
        $script:Calls | Should -Be @('scoop install glow')
        ($r | Where-Object Tool -eq glow).Result | Should -Be 'Installed'
        (Get-DFToolStatus -Name glow).State | Should -Be 'Active'
    }
    It '-WhatIf prints the plan without PowerShell''s per-property What-if noise' {
        $out = Install-DFTool -Name glow -WhatIf -ToolsPath $script:Tools *>&1 | Out-String
        $out | Should -Not -Match 'Retrieve the value'
        $out | Should -Match 'scoop: glow'
    }
    It '-WhatIf installs nothing' {
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        $null = Install-DFTool -Missing -WhatIf -ToolsPath $script:Tools 6>$null
        $script:Calls | Should -BeNullOrEmpty
    }
    It 'a non-interactive host without -UseDefaults reports a gap and its dependents, and asks nothing' {
        $r = Install-DFTool -Name ish -ToolsPath $script:Tools 3>$null 6>$null
        Should -Invoke Read-DFInstallChoice -Times 0
        $script:Calls | Should -BeNullOrEmpty
        ($r | Where-Object Tool -eq ish).Result | Should -Be 'Gap'
        ($r | Where-Object Tool -eq ish).Detail | Should -Match 'npm, pnpm'
    }
    It '-UseDefaults fills a gap with the role''s top member and installs it first' {
        $null = Install-DFTool -Name ish -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -Be @('scoop install nodejs', 'npm i -g @microsoft/inshellisense')
    }
    It 'interactive mode asks for each open choice, showing the default, and uses the answer' {
        Mock Test-DFInteractiveHost { $true }
        # Pick pnpm for the manager question; say yes to the plan.
        Mock Read-DFInstallChoice { if ($Options -contains 'pnpm') { 'pnpm' } else { 'y' } }
        $null = Install-DFTool -Name ish -ToolsPath $script:Tools 3>$null 6>$null
        Should -Invoke Read-DFInstallChoice -Times 1 -ParameterFilter { $Default -eq 'npm' -and $Options -contains 'pnpm' }
        Should -Invoke Read-DFInstallChoice -Times 1 -ParameterFilter { $Options -contains 'y' }
        $script:Calls | Should -Be @('scoop install pnpm', 'pnpm add -g @microsoft/inshellisense')
    }
    It 'warns that a tool installed by name but not in Tools loads only this session' {
        Start-DFSession -Config @{ Tools = @() } -ToolsPath $script:Tools 3>$null
        $null = Install-DFTool -Name glow -UseDefaults -ToolsPath $script:Tools -WarningVariable w 3>$null 6>$null
        "$w" | Should -Match 'glow.*add it to Tools'
    }
    It 'does not reinstall what a previous partial run already installed' {
        $script:Installed += 'glow.exe'
        $null = Install-DFTool -Name glow -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -BeNullOrEmpty
    }
    It '-Via installs from the named source for this call' {
        $null = Install-DFTool -Name glow -Via scoop -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -Be @('scoop install glow')
    }
}

Describe 'Start-DFSession install hints' {
    BeforeEach { Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null; $script:Tools = New-InstallTools; Mock Write-DFConflictNotice { } }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }
    It 'reads no manager record when nothing is missing' {
        Mock Test-DFToolAvailable { $true }
        Mock New-DFInstallPlan { }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        Should -Invoke New-DFInstallPlan -Times 0
    }
    It 'builds the hint only when the status is read, not at startup' {
        Mock Test-DFToolAvailable { $Executable -eq 'scoop.cmd' }
        Mock New-DFInstallPlan { }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        Should -Invoke New-DFInstallPlan -Times 0
    }
    It 'still reports status when building the hint fails' {
        Mock Test-DFToolAvailable { $Executable -eq 'scoop.cmd' }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        Mock New-DFInstallPlan { throw 'broken manager record' }
        (Get-DFToolStatus -Name glow 3>$null).State | Should -Be 'Missing'
    }
    It 'says how a missing tool would be installed' {
        Mock Test-DFToolAvailable { $Executable -eq 'scoop.cmd' }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolStatus -Name glow).Detail | Should -Match 'Install-DFTool -Missing will install it via scoop'
    }
}
