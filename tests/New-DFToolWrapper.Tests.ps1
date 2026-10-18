BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-WrappedTool([object[]]$WrapperArgs, [hashtable]$Theme, [hashtable]$Settings) {
        $raw = [ordered]@{ name = 'wrapped'; executable = 'dfwrapped.exe'; wrapper = [pscustomobject]@{ args = $WrapperArgs } }
        if ($Theme) { $raw.theme = [pscustomobject]$Theme }
        if ($Settings) { $raw.settings = [pscustomobject]$Settings }
        ConvertTo-DFToolRecord ([pscustomobject]$raw)
    }
}

Describe 'New-DFToolWrapper' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        # The "executable": a global function named like the exe; the wrapper calls it by that name.
        Set-Item function:global:dfwrapped.exe -Value {
            $piped = @($input)
            "args=$($args -join '|')"
            if ($piped) { "input=$($piped -join '|')" }
        }
    }
    AfterEach { Remove-DFTestGlobal -Function 'dfwrapped.exe', 'dfwrapped'; Restore-DFTestXdg }

    It 'defines a global function named after the executable, passing declared then user args' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a', '--b'))
        dfwrapped --mine | Should -Be 'args=--a|--b|--mine'
    }
    It 'skips a group when you pass one of its unlessArg flags yourself, or while its unlessFile exists' {
        $mine = Join-Path $TestDrive 'mine.conf'
        Remove-Item $mine -ErrorAction Ignore
        $group = [pscustomobject]@{ unlessArg = @('--theme', '-t'); unlessFile = $mine; args = @('--theme', 'dark') }
        New-DFToolWrapper -Tool (New-WrappedTool @($group, '--always'))
        dfwrapped x | Should -Be 'args=--theme|dark|--always|x'
        dfwrapped --theme nord | Should -Be 'args=--always|--theme|nord'
        dfwrapped --theme=nord | Should -Be 'args=--always|--theme=nord'
        dfwrapped -t nord | Should -Be 'args=--always|-t|nord'
        Set-Content $mine 'x'
        dfwrapped x | Should -Be 'args=--always|x'
    }
    It 'passes an ifFile group only while the file exists, reading {file}' {
        $cfg = Join-Path $TestDrive 'w.conf'
        New-DFToolWrapper -Tool (New-WrappedTool @([pscustomobject]@{ ifFile = $cfg; args = @('--config', '{file}') }))
        dfwrapped | Should -Be 'args='
        Set-Content $cfg 'x'
        dfwrapped | Should -Be "args=--config|$cfg"
    }
    It 'expands ${XDG_*} and {settings.<name>} in ifFile' {
        $tool = New-WrappedTool @([pscustomobject]@{ ifFile = '{settings.cfg}'; args = @('-c', '{file}') }) -Settings @{ cfg = '${XDG_CONFIG_HOME}/w.conf' }
        New-Item -ItemType File -Path (Join-Path $Env:XDG_CONFIG_HOME 'w.conf') -Force | Out-Null
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be "args=-c|$(Join-Path $Env:XDG_CONFIG_HOME 'w.conf')"
    }
    It 'omits an ifFile group whose whole template names a missing setting' {
        $tool = New-WrappedTool @('--a', [pscustomobject]@{ ifFile = '{settings.cfg}'; args = @('-c', '{file}') })
        { New-DFToolWrapper -Tool $tool } | Should -Not -Throw
        dfwrapped | Should -Be 'args=--a'
    }
    It 'omits an ifFile group whose template uses a missing setting inside a longer path' {
        $tool = New-WrappedTool @('--a', [pscustomobject]@{ ifFile = '{settings.cfg}/x.conf'; args = @('-c', '{file}') }) -Settings @{ other = 'y' }
        Expand-DFToolToken -Tool $tool -Text '{settings.cfg}/x.conf' | Should -BeNullOrEmpty
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be 'args=--a'
    }
    It 'expands a literal ~ in ifFile under $HOME' {
        $tool = New-WrappedTool @([pscustomobject]@{ ifFile = '~/x.conf'; args = @('-c', '{file}') })
        Expand-DFToolToken -Tool $tool -Text '~/x.conf' | Should -Be (Join-Path $HOME 'x.conf')
    }
    It 'reads {theme} from the session on every call' {
        $tool = New-WrappedTool @('-s', '{theme}') -Theme @{ key = 'WrappedTheme'; default = 'nord' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = 'nord' } }
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be 'args=-s|nord'
        $script:DFSessionThemes.wrapped = [pscustomobject]@{ Value = 'dracula' }
        dfwrapped | Should -Be 'args=-s|dracula'
    }
    It 'reads {theme} in ifFile on every call, passing the group only while that file exists' {
        $one = Join-Path $TestDrive 'flavor-one'; $two = Join-Path $TestDrive 'flavor-two'
        New-Item -ItemType Directory -Force $one, $two | Out-Null
        Set-Content (Join-Path $one 'c.yaml') 'x'
        $tool = New-WrappedTool @([pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('-c', '{file}') }) -Theme @{ key = 'WrappedTheme' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = $one } }
        New-DFToolWrapper -Tool $tool 3>$null -WarningVariable w
        "$w" | Should -BeNullOrEmpty
        dfwrapped | Should -Be "args=-c|$(Join-Path $one 'c.yaml')"
        $script:DFSessionThemes.wrapped = [pscustomobject]@{ Value = $two }
        dfwrapped | Should -Be 'args='
    }
    It 'omits a {theme} ifFile group while the session has no theme value' {
        $tool = New-WrappedTool @('--a', [pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('-c', '{file}') }) -Theme @{ key = 'WrappedTheme' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = $null } }
        New-DFToolWrapper -Tool $tool 3>$null
        dfwrapped | Should -Be 'args=--a'
    }
    It 'keeps a theme value with spaces as one argument' {
        $tool = New-WrappedTool @('-s', '{theme}') -Theme @{ key = 'WrappedTheme' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = 'Catppuccin Mocha' } }
        Set-Item function:global:dfwrapped.exe -Value { "count=$($args.Count) last=$($args[-1])" }
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be 'count=2 last=Catppuccin Mocha'
    }
    It 'passes piped input through without the missing file''s group' {
        New-DFToolWrapper -Tool (New-WrappedTool @([pscustomobject]@{ ifFile = (Join-Path $TestDrive 'none'); args = @('--config', '{file}') }))
        'one', 'two' | dfwrapped | Should -Be @('args=', 'input=one|two')
    }
    It 'hands the call to -Invoke with the declared and user arguments' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a')) -Invoke { param($exe, $declared, $userArgs, $invocation) "$exe;$($declared -join ',');$($userArgs -join ',')" }
        dfwrapped --x | Should -Be 'dfwrapped.exe;--a;--x'
    }
    It 'gives the wrapper complete help' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a'))
        $help = Get-Help dfwrapped -Full
        $help.Synopsis | Should -Match 'Runs dfwrapped.exe'
        ($help.description | Out-String) | Should -Match '--a'
        @($help.examples.example).Count | Should -BeGreaterThan 0
        ($help.returnValues | Out-String) | Should -Match 'String'
    }
}

Describe 'wrapper during registration' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'wraptools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "wrapped", "executable": "dfwrapped.exe", "theme": { "key": "WrappedTheme", "default": "nord" }, "wrapper": { "args": ["-s", "{theme}"] } }' |
            Set-Content (Join-Path $script:Tools 'wrapped.json')
        Set-Item function:global:dfwrapped.exe -Value { "args=$($args -join '|')" }
    }
    AfterEach { Remove-DFTestGlobal -Function 'dfwrapped.exe', 'dfwrapped'; Restore-DFTestXdg }

    It 'builds the wrapper with the session theme' {
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        dfwrapped | Should -Be 'args=-s|nord'
    }
    It 'follows Set-DFToolTheme' {
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        Set-DFToolTheme wrapped dracula | Out-Null
        dfwrapped | Should -Be 'args=-s|dracula'
    }
    It 'leaves a custom wrapper to the companion' {
        '{ "name": "wrapped", "executable": "dfwrapped.exe", "wrapper": { "custom": true, "args": ["--a"] } }' | Set-Content (Join-Path $script:Tools 'wrapped.json')
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        Test-Path function:global:dfwrapped | Should -BeFalse
    }
}

Describe 'declared wrappers' {
    It '<_> does not shadow a PowerShell builtin' -AllowNullOrEmptyForEach -ForEach @(Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $json = Get-Content $_ -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties['wrapper']) { [System.IO.Path]::GetFileNameWithoutExtension($json.executable) } }) {
        $builtin = pwsh -NoProfile -NoLogo -c "Get-Command -Name '$_' -CommandType Cmdlet, Alias, Function -ErrorAction Ignore | ForEach-Object Name"
        $builtin | Should -BeNullOrEmpty
    }
    It '<_> companion builds its custom wrapper' -AllowNullOrEmptyForEach -ForEach @(Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $json = Get-Content $_ -Raw | ConvertFrom-Json
            $wrapper = $json.PSObject.Properties['wrapper']?.Value
            if ($wrapper -and $wrapper.PSObject.Properties['custom']?.Value) { $json.name } }) {
        Get-Content "$PSScriptRoot/../Tools/$_.ps1" -Raw | Should -Match 'New-DFToolWrapper'
    }
}
