BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'eza/lsd share role: listing (real tool records)' {
    BeforeEach { Reset-DFTestSession;
        # These tests fake "installed" with Mock Get-Command / Get-Module; route the PATH and module probes through them.
        Mock Test-DFExecutableOnPath { [bool](Get-Command $Name -ErrorAction Ignore) }
        Mock Test-DFModuleOnPath { [bool](Get-Module -ListAvailable -Name $Name -ErrorAction Ignore) }
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        Set-DFTestConfig $null
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        Mock Get-Command {
            param($Name)
            if ($Name -in 'eza.exe', 'lsd.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        Mock Write-DFConflictNotice { }
        # Stand-ins so a wrapper's `& eza ...` / `& lsd ...` resolves to a capturable
        # function (Function resolves before Application), whether or not the real
        # binaries are installed. A .GetNewClosure() wrapper's ScriptBlock.ToString()
        # shows only the unbound template, so calling it is the only reliable probe.
        function global:eza { $global:LastCommandCalled = 'eza' }
        function global:lsd { $global:LastCommandCalled = 'lsd' }
    }
    AfterEach {
        Set-DFTestConfig $null; Remove-Variable LastCommandCalled -Scope Global -ErrorAction Ignore
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        # eza's real picker block also defines Select-File and its ff alias.
        Remove-DFTestGlobal -Function ls, ll, la, tree, Select-File, eza, lsd -Alias ff
    }

    It 'declares listing on both tools, with the listing aliases inside the role block' {
        foreach ($name in 'eza', 'lsd') {
            $j = Get-Content (Join-Path $script:RealTools "$name.json") -Raw | ConvertFrom-Json
            $j.roles.listing.aliases.PSObject.Properties.Name | Should -Be @('ls', 'll', 'la', 'tree')
            @($j.aliases.PSObject.Properties).Count | Should -Be 0
            $j.PSObject.Properties['role'] | Should -BeNullOrEmpty
        }
    }

    It 'gives the listing aliases to <Winner> when Defaults.listing = <Winner>' -ForEach @(@{ Winner = 'eza' }, @{ Winner = 'lsd' }) {
        Set-DFTestConfig @{ Defaults = @{ listing = $Winner } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        foreach ($a in 'ls', 'll', 'la', 'tree') { & $a; $global:LastCommandCalled | Should -Be $Winner -Because $a }
    }

    It 'gives the listing aliases to eza by priority when Defaults is absent' {
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        & 'ls'; $global:LastCommandCalled | Should -Be 'eza'
    }
}

Describe 'oh-my-posh/starship share role: prompt (real tool records and sidecars)' {
    BeforeAll { . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1" }
    BeforeEach { Reset-DFTestSession;
        # These tests fake "installed" with Mock Get-Command / Get-Module; route the PATH and module probes through them.
        Mock Test-DFExecutableOnPath { [bool](Get-Command $Name -ErrorAction Ignore) }
        Mock Test-DFModuleOnPath { [bool](Get-Module -ListAvailable -Name $Name -ErrorAction Ignore) }
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        $global:DFRoleEnvState = $null
        Set-DFTestConfig $null
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        $script:SavedPoshTheme = $Env:POSH_THEME
        Remove-Item Env:POSH_THEME -ErrorAction Ignore
        # One oh-my-posh config for the sidecar to discover.
        $ompDir = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh'
        New-Item -ItemType Directory -Force $ompDir | Out-Null
        '{}' | Set-Content (Join-Path $ompDir 'test.omp.json')

        $global:PromptInits = @()
        Mock Get-Command {
            param($Name)
            if ($Name -in 'oh-my-posh.exe', 'starship.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        Mock Get-Module { }   # no posh-git, so the oh-my-posh hook skips its import
        Mock Write-DFConflictNotice { }
        Mock Get-DFCachedCommandOutput { '$global:PromptInits += "starship"' } -ParameterFilter { $Name -eq 'starship-init' }
        # oh-my-posh's init output is piped to Invoke-Expression; emit a line that records the call.
        function global:oh-my-posh { '$global:PromptInits += "oh-my-posh"' }
    }
    AfterEach {
        Set-DFTestConfig $null; Remove-Variable PromptInits -Scope Global -ErrorAction Ignore
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        if ($null -eq $script:SavedPoshTheme) { Remove-Item Env:POSH_THEME -ErrorAction Ignore } else { $Env:POSH_THEME = $script:SavedPoshTheme }
        Remove-Item Env:POSH_THEMES_PATH, Env:STARSHIP_CONFIG, Env:STARSHIP_CACHE -ErrorAction Ignore
        Remove-DFTestGlobal -Function oh-my-posh, Select-PoshTheme -Alias fpot
    }

    It 'initializes only oh-my-posh by priority, defines fpot, and warns once' {
        Register-DFTool -Name 'oh-my-posh', 'starship' -ToolsPath $script:RealTools -WarningVariable w -WarningAction SilentlyContinue
        $global:PromptInits | Should -Be @('oh-my-posh')
        (Get-Alias fpot -ErrorAction Ignore).Definition | Should -Be 'Select-PoshTheme'
        "$w" | Should -Match 'prompt role; using oh-my-posh'
    }

    It 'initializes only starship when Defaults.prompt = starship, and leaves fpot undefined' {
        Set-DFTestConfig @{ Defaults = @{ prompt = 'starship' } }
        Register-DFTool -Name 'oh-my-posh', 'starship' -ToolsPath $script:RealTools -WarningVariable w -WarningAction SilentlyContinue
        $global:PromptInits | Should -Be @('starship')
        Get-Alias fpot -ErrorAction Ignore | Should -BeNullOrEmpty
        "$w" | Should -Not -Match 'prompt role'
    }
}

Describe 'ps-dotenv/mise/direnv share role: project-env (real tool records and sidecars)' {
    BeforeAll {

        $fakeDir = Join-Path $TestDrive 'fake-dotenv\Dotenv'
        New-Item -ItemType Directory -Force $fakeDir | Out-Null
        $script:FakeDotenv = Join-Path $fakeDir 'Dotenv.psm1'
        @'
$Dotenv = [pscustomobject]@{ Enabled = $false; SafeMode = $false; Async = $true }
function Enable-Dotenv { $Dotenv.Enabled = $true }
function Approve-DotenvDir { param([Parameter(Mandatory)][string]$Path) }
function Update-Dotenv { $global:ProjectEnvInits += 'ps-dotenv' }
Export-ModuleMember -Function * -Variable Dotenv
'@ | Set-Content $script:FakeDotenv
    }
    BeforeEach { Reset-DFTestSession;
        # These tests fake "installed" with Mock Get-Command / Get-Module; route the PATH and module probes through them.
        Mock Test-DFExecutableOnPath { [bool](Get-Command $Name -ErrorAction Ignore) }
        Mock Test-DFModuleOnPath { [bool](Get-Module -ListAvailable -Name $Name -ErrorAction Ignore) }
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        $global:DFRoleEnvState = $null
        Set-DFTestConfig $null; Remove-Variable DFDotenvLocationHook -Scope Global -ErrorAction Ignore
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        $script:SavedPath = $Env:Path
        $script:SavedLca = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
        $global:ProjectEnvInits = @()
        Mock Get-Command {
            param($Name)
            if ($Name -in 'direnv.exe', 'mise.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        Mock Get-Module { [pscustomobject]@{ Name = 'Dotenv'; Path = $script:FakeDotenv } } -ParameterFilter { $ListAvailable }
        Mock Write-DFConflictNotice { }
        Mock Get-DFCachedCommandOutput { '$global:ProjectEnvInits += "direnv"' } -ParameterFilter { $Name -eq 'direnv-hook' }
        Mock Get-DFCachedCommandOutput { '2.38.0' } -ParameterFilter { $Name -eq 'direnv-version' }
        function global:mise { '$global:ProjectEnvInits += "mise"' }
    }
    AfterEach {
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:SavedLca
        $Env:Path = $script:SavedPath
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        Remove-Module Dotenv -Force -ErrorAction Ignore
        Set-DFTestConfig $null; Remove-Variable DFDotenvLocationHook, ProjectEnvInits, Dotenv, DFRoleEnvState -Scope Global -ErrorAction Ignore
        Remove-Item Env:DIRENV_BASH -ErrorAction Ignore
        Remove-DFTestGlobal -Function mise
    }

    It 'activates only ps-dotenv by priority, warns once, and keeps mise''s shims on PATH' {
        Register-DFTool -Name 'ps-dotenv', 'mise', 'direnv' -ToolsPath $script:RealTools -WarningVariable w -WarningAction SilentlyContinue
        $global:ProjectEnvInits | Should -Be @('ps-dotenv')
        @($w | Where-Object { "$_" -match 'can each fill the project-env role' }).Count | Should -Be 1
        "$w" | Should -Match 'project-env role; using ps-dotenv'
        "$w" | Should -Match "'project-env' = 'mise'" -Because 'the notice suggests the runner-up by priority'
        ($Env:Path -split ';') | Should -Contain (Join-Path $Env:XDG_DATA_HOME 'mise\shims')
    }

    It 'activates only mise when Defaults.project-env = mise' {
        Set-DFTestConfig @{ Defaults = @{ 'project-env' = 'mise' } }
        Register-DFTool -Name 'ps-dotenv', 'mise', 'direnv' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $global:ProjectEnvInits | Should -Be @('mise')
    }
}

Describe 'moor/ov/less share role: pager (real tool records)' {
    BeforeEach { Reset-DFTestSession;
        # These tests fake "installed" with Mock Get-Command / Get-Module; route the PATH and module probes through them.
        Mock Test-DFExecutableOnPath { [bool](Get-Command $Name -ErrorAction Ignore) }
        Mock Test-DFModuleOnPath { [bool](Get-Module -ListAvailable -Name $Name -ErrorAction Ignore) }
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        $global:DFRoleEnvState = $null
        Set-DFTestConfig $null
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        $script:SavedPager = $Env:PAGER
        $script:SavedMoor = $Env:MOOR
        Remove-Item Env:PAGER, Env:MOOR -ErrorAction Ignore
        Mock Get-Command {
            param($Name)
            switch ($Name) {
                'less.exe' { [pscustomobject]@{ Source = 'C:\Program Files\Git\usr\bin\less.exe'; Path = 'C:\Program Files\Git\usr\bin\less.exe' }
                             [pscustomobject]@{ Source = 'C:\scoop\shims\less.exe'; Path = 'C:\scoop\shims\less.exe' } }
                { $_ -in 'moor.exe', 'ov.exe', 'bat.exe' } { [pscustomobject]@{ Source = "C:\fake\$Name"; Path = "C:\fake\$Name" } }
            }
        }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        if ($null -eq $script:SavedPager) { Remove-Item Env:PAGER -ErrorAction Ignore } else { $Env:PAGER = $script:SavedPager }
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Set-DFTestConfig $null; Remove-Variable DFRoleEnvState -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function cat -Alias cat
    }

    It 'makes moor the pager by priority' {
        Register-DFTool -Name moor, ov, less, bat -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:PAGER | Should -Be 'moor'
    }

    It 'uses ov with quit-if-one-screen when Defaults.pager = ov' {
        Set-DFTestConfig @{ Defaults = @{ pager = 'ov' } }
        Register-DFTool -Name moor, ov, less, bat -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:PAGER | Should -Be 'ov --quit-if-one-screen'
    }

    It 'points PAGER at the native less, skipping Git''s MSYS build, when Defaults.pager = less' {
        Set-DFTestConfig @{ Defaults = @{ pager = 'less' } }
        Register-DFTool -Name moor, ov, less, bat -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:PAGER | Should -Be 'C:/scoop/shims/less.exe'
    }

    It 'no longer counts bat as a pager' {
        $j = Get-Content (Join-Path $script:RealTools 'bat.json') -Raw | ConvertFrom-Json
        $j.PSObject.Properties['roles'] | Should -BeNullOrEmpty
    }
}
