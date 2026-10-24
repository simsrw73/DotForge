BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'broot tool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'broot') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
        Mock Invoke-DFBoundedProcess { [pscustomobject]@{ Lines = @(); ExitCode = 0 } }
        # Start unset: a developer may have BROOT_CONFIG_DIR in their own environment.
        $script:SavedConfigDir = $Env:BROOT_CONFIG_DIR
        $Env:BROOT_CONFIG_DIR = $null
        $script:ConfigDir = Join-Path $Env:XDG_CONFIG_HOME 'broot'
    }
    AfterEach { $Env:BROOT_CONFIG_DIR = $script:SavedConfigDir; Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'points BROOT_CONFIG_DIR at its XDG folder and seeds conf.hjson and verbs.hjson' {
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        $Env:BROOT_CONFIG_DIR | Should -Be $script:ConfigDir
        Get-Content (Join-Path $script:ConfigDir 'conf.hjson') -Raw | Should -Be (Get-Content (Join-Path $script:Tools 'broot' 'conf.hjson') -Raw)
        Test-Path (Join-Path $script:ConfigDir 'verbs.hjson') | Should -BeTrue
    }
    It 'binds :cd to ctrl-enter as well as alt-enter, which Windows Terminal takes for fullscreen' {
        $verbs = Get-Content (Join-Path $script:Tools 'broot' 'verbs.hjson') -Raw
        $verbs | Should -Match '(?s)\{\s*key:\s*ctrl-enter\s+cmd:\s*":cd"\s*\}'
    }
    It 'seeds a conf.hjson that imports no skin, so the theme passed by br decides' {
        $conf = Get-Content (Join-Path $script:Tools 'broot' 'conf.hjson') -Raw
        $conf | Should -Match 'verbs\.hjson'
        $conf | Should -Not -Match '(?m)^\s*file:\s*skins/'
    }
    It 'resolves its theme to the bundled catppuccin skin, following Theme' {
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolTheme -Tool $script:DFSessionToolDb['broot']).Value | Should -Be (ConvertTo-DFPath (Join-Path $script:Tools 'broot' 'catppuccin-mocha'))
        Reset-DFTestSession
        Start-DFSession -Config @{ Tools = @('broot'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        (Get-DFToolTheme -Tool $script:DFSessionToolDb['broot']).Value | Should -Be (ConvertTo-DFPath (Join-Path $script:Tools 'broot' 'catppuccin-latte'))
    }
    It 'knows the BrootTheme setting' {
        $script:DFConfigKeys.Keys | Should -Contain 'BrootTheme'
    }
}

Describe 'ConvertFrom-DFShellCdLine' {
    It 'reads a POSIX-quoted cd line, as broot writes it' {
        ConvertFrom-DFShellCdLine -Text "cd 'C:\a b'`n" | Should -Be 'C:\a b'
        ConvertFrom-DFShellCdLine -Text "cd 'C:\x\it'`"'`"'s'`n" | Should -Be "C:\x\it's"
        ConvertFrom-DFShellCdLine -Text "cd 'C:\w[1]'" | Should -Be 'C:\w[1]'
    }
    It 'reads nothing from anything else' {
        foreach ($text in "cd 'x'; Remove-Item y", "cd 'a'`ncd 'b'", '', "Start-Process calc", "cd 'unterminated", "cd x", "cd 'a' 'b'", "cd 'a'`"`$(calc)`"") {
            ConvertFrom-DFShellCdLine -Text $text | Should -BeNullOrEmpty -Because "'$text' is not one plain cd"
        }
    }
}

Describe 'Invoke-DFCdFileCommand' {
    BeforeEach {
        Mock Enter-DFDirectory { $true }
        Mock Invoke-Expression { }
        Mock Write-Host { }
        $script:FileSeen = $null
    }
    It 'runs the navigator with the cd file in its arguments, then moves to the folder it wrote' {
        $run = { param($Executable, $Arguments) $script:FileSeen = $Arguments[1]; Set-Content -LiteralPath $Arguments[1] "cd 'C:\a b'"; 0 }
        Invoke-DFCdFileCommand -Executable 'nav.exe' -Arguments @('--outcmd', '{file}', '-x') -Format ShellCd -Run $run | Should -BeTrue
        Should -Invoke Enter-DFDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\a b' }
        Test-Path -LiteralPath $script:FileSeen | Should -BeFalse -Because 'the cd file is removed'
    }
    It 'runs nothing a hostile cd file holds, and moves nowhere' {
        $run = { param($Executable, $Arguments) Set-Content -LiteralPath $Arguments[1] "cd 'C:\x'; Remove-Item C:\y"; 0 }
        Invoke-DFCdFileCommand -Executable 'nav.exe' -Arguments @('--outcmd', '{file}') -Format ShellCd -Run $run | Should -BeFalse
        Should -Invoke Enter-DFDirectory -Times 0
        Should -Invoke Invoke-Expression -Times 0
    }
    It 'reads a plain path file with -Format Path' {
        $run = { param($Executable, $Arguments) Set-Content -LiteralPath $Arguments[0] 'C:\plain'; 0 }
        Invoke-DFCdFileCommand -Executable 'nav.exe' -Arguments @('{file}') -Format Path -Run $run | Should -BeTrue
        Should -Invoke Enter-DFDirectory -Times 1 -ParameterFilter { $Path -eq 'C:\plain' }
    }
    It 'says so when the navigator fails, and moves nowhere' {
        $run = { param($Executable, $Arguments) 3 }
        Invoke-DFCdFileCommand -Executable 'nav.exe' -Arguments @('{file}') -Format Path -Run $run | Should -BeFalse
        Should -Invoke Write-Host -Times 1 -ParameterFilter { "$Object" -like '*nav.exe exited with code 3*' }
        Should -Invoke Enter-DFDirectory -Times 0
    }
    It 'moves nowhere when the navigator wrote nothing (quit without a cd)' {
        $run = { param($Executable, $Arguments) 0 }
        Invoke-DFCdFileCommand -Executable 'nav.exe' -Arguments @('{file}') -Format ShellCd -Run $run | Should -BeFalse
        Should -Invoke Enter-DFDirectory -Times 0
        Should -Invoke Write-Host -Times 0
    }
}

Describe 'broot companion: br and Alt+C' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:SavedConfigDir = $Env:BROOT_CONFIG_DIR
        $Env:BROOT_CONFIG_DIR = Join-Path $TestDrive 'brcfg'
        # $TestDrive lasts the whole Describe: start each test without broot's install state.
        Remove-Item -LiteralPath $Env:BROOT_CONFIG_DIR -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory $Env:BROOT_CONFIG_DIR -Force | Out-Null
        Set-Content (Join-Path $Env:BROOT_CONFIG_DIR 'conf.hjson') 'imports: []'
        Mock Set-DFRoleKeyHandler { }
        $DFCurrentTool = [pscustomobject]@{ name = 'broot' }
        . (Join-Path $script:Tools 'broot.ps1')
    }
    AfterEach {
        $Env:BROOT_CONFIG_DIR = $script:SavedConfigDir
        Remove-DFTestGlobal -Function br
        Restore-DFTestXdg; Set-DFTestConfig $null
    }
    It 'defines br, which is not a PowerShell built-in' {
        (Get-Command br -CommandType Function).Name | Should -Be 'br'
        @([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2().Commands['br']).Count | Should -Be 0
    }
    It 'gives broot the cd file, the config and the theme''s skin, then your arguments' {
        Mock Get-DFSessionThemeValue { Join-Path $script:Tools 'broot' 'catppuccin-latte' } -ParameterFilter { $Name -eq 'broot' }
        $argv = @(Get-DFBrootArgument -Extra @('--only-folders', 'C:\x'))
        $argv[0..1] | Should -Be @('--outcmd', '{file}')
        $argv[2] | Should -Be '--conf'
        $argv[3] | Should -Be ((Join-Path $Env:BROOT_CONFIG_DIR 'conf.hjson') + ';' + (Join-Path $script:Tools 'broot' 'catppuccin-latte' 'skin.hjson'))
        $argv[4..5] | Should -Be @('--only-folders', 'C:\x')
    }
    It 'passes broot''s short flags through untouched (-d is not -Debug, -p is not ambiguous)' {
        $command = Get-Command br -CommandType Function
        $command.CmdletBinding | Should -BeFalse
        $command.Parameters.Keys | Should -Not -Contain 'Debug'
    }
    It 'sets broot''s install state before a run when it is missing, so broot never edits your profiles' {
        Mock Invoke-DFBoundedProcess { New-Item -ItemType File -Force (Join-Path $Env:BROOT_CONFIG_DIR 'launcher' 'installed-v5') | Out-Null; [pscustomobject]@{ Lines = @(); ExitCode = 0 } }
        Confirm-DFBrootInstallState -Executable 'broot.exe' | Should -BeTrue
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -ParameterFilter { ($ArgumentList -join ' ') -eq '--set-install-state installed' }
        Confirm-DFBrootInstallState -Executable 'broot.exe' | Should -BeTrue
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -Exactly -Because 'the state file is there now'
    }
    It 'refuses to run broot when its install state can''t be set' {
        Mock Invoke-DFBoundedProcess { [pscustomobject]@{ Lines = @(); ExitCode = 1 } }
        Mock Write-Host { }
        Confirm-DFBrootInstallState -Executable 'broot.exe' | Should -BeFalse
        Should -Invoke Write-Host -Times 1 -ParameterFilter { "$Object" -like '*broot --set-install-state installed*' }
    }
    It 'passes no --conf when there is no theme skin' {
        Mock Get-DFSessionThemeValue { $null } -ParameterFilter { $Name -eq 'broot' }
        @(Get-DFBrootArgument -Extra @()) | Should -Be @('--outcmd', '{file}')
    }
    It 'binds Alt+c from its directory-jump hook' {
        Initialize-DFRoleDirectoryJump -Tool ([pscustomobject]@{ name = 'broot' }) -Role 'directory-jump'
        Should -Invoke Set-DFRoleKeyHandler -Times 1 -ParameterFilter { $Role -eq 'directory-jump' -and $Chord -eq 'Alt+c' -and $Tool -eq 'broot' }
    }
    It 'joins directory-jump below fzf and skim' {
        (Import-DFToolDb -ToolsPath $script:Tools -Name broot).broot.roles.'directory-jump'.priority | Should -Be 3
    }
}

Describe 'broot setup' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'broot') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
        $script:SavedConfigDir = $Env:BROOT_CONFIG_DIR
        $Env:BROOT_CONFIG_DIR = $null
        $script:Exit = 0
        Mock Invoke-DFBoundedProcess { [pscustomobject]@{ Lines = @(); ExitCode = $script:Exit } }
    }
    AfterEach { $Env:BROOT_CONFIG_DIR = $script:SavedConfigDir; Remove-DFTestGlobal -Function br; Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'tells broot its br is handled, once, with a note, and BROOT_CONFIG_DIR already set' {
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '--set-install-state installed' -and $TimeoutSeconds -eq 30 -and $Env:BROOT_CONFIG_DIR -eq (Join-Path $Env:XDG_CONFIG_HOME 'broot')
        }
        "$((Get-DFToolSetupState).broot.notes)" | Should -Match 'DotForge provides br'
        Reset-DFTestSession
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        Should -Invoke Invoke-DFBoundedProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '--set-install-state installed' }
    }
    It 'still completes when broot fails, with a note to run it yourself' {
        $script:Exit = 1
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['broot'] | Should -Not -BeNullOrEmpty
        "$((Get-DFToolSetupState).broot.notes)" | Should -Match 'broot --set-install-state installed'
    }
}
