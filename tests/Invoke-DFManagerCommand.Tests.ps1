BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Mgr = [pscustomobject]@{ name = 'm' }
}

Describe 'Invoke-DFManagerCommand' {
    It 'reports success for an in-process .ps1 shim even when an earlier command left a failure code' {
        $bin = Join-Path $TestDrive "shim-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $bin | Out-Null
        'param() "ok"' | Set-Content (Join-Path $bin 'dffakemgr.ps1')
        $saved = $Env:Path
        try {
            $Env:Path = "$bin;$Env:Path"
            $global:LASTEXITCODE = 1
            (Invoke-DFManagerCommand -Operation install -Manager ([pscustomobject]@{ name = 'dffakemgr' }) -Argv 'dffakemgr', 'install', 'x').ExitCode | Should -Be 0
        } finally { $Env:Path = $saved }
    }
    It 'captures what an in-process shim writes to the host (scoop''s "Installed apps:"), instead of printing it' {
        $bin = Join-Path $TestDrive "hostshim-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $bin | Out-Null
        'param() Write-Host "Installed apps:"; Write-Warning "bucket out of date"; "row"' | Set-Content (Join-Path $bin 'dfhostmgr.ps1')
        $saved = $Env:Path
        try {
            $Env:Path = "$bin;$Env:Path"
            $r = Invoke-DFManagerCommand -Operation list -Manager ([pscustomobject]@{ name = 'dfhostmgr' }) -Argv 'dfhostmgr', 'list' 3>$null
            $r.Output | Should -BeLike '*Installed apps:*row*'
        } finally { $Env:Path = $saved }
    }
    It 'keeps stderr out of list and outdated output (pip''s upgrade notice), but not out of install output' {
        $bin = Join-Path $TestDrive "errshim-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $bin | Out-Null
        # A native program, like pip: its stderr arrives as error records.
        "@echo [notice] A new release of pip is available 1>&2`r`n@echo []" | Set-Content (Join-Path $bin 'dferrmgr.cmd')
        $saved = $Env:Path
        try {
            $Env:Path = "$bin;$Env:Path"
            $listed = Invoke-DFManagerCommand -Operation list -Manager ([pscustomobject]@{ name = 'dferrmgr' }) -Argv 'dferrmgr', 'list'
            $listed.Output.Trim() | Should -Be '[]'
            $installed = Invoke-DFManagerCommand -Operation install -Manager ([pscustomobject]@{ name = 'dferrmgr' }) -Argv 'dferrmgr', 'install'
            $installed.Output | Should -BeLike '*A new release of pip*'
        } finally { $Env:Path = $saved }
    }
    It 'reports a declined administrator prompt' {
        Mock Start-Process { throw [System.ComponentModel.Win32Exception]::new(1223) }
        $r = Invoke-DFManagerCommand -Operation remove -Manager $script:Mgr -Argv 'm', 'uninstall', 'x' -Elevation ([pscustomobject]@{ Method = 'RunAs' })
        $r.ExitCode | Should -Be 1223
        $r.Output | Should -BeLike 'the administrator prompt was declined or failed: *'
    }
    It 'calls a function operation with its arguments' {
        function script:Update-DFFake { param($Name) "updated $Name" }
        $r = Invoke-DFManagerCommand -Operation update -Manager $script:Mgr -Function Update-DFFake -Arguments @{ Name = 'a' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike 'updated a*'
    }
    It 'runs through the elevator for the Elevator method' {
        function global:dffake-elevator { $global:DFElevated = @($args) }
        try {
            $null = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'm', 'install', 'x' `
                -Elevation ([pscustomobject]@{ Method = 'Elevator'; Executable = 'dffake-elevator' })
            $global:DFElevated | Should -Be @('m', 'install', 'x')
        } finally { Remove-DFTestGlobal -Function dffake-elevator; Remove-Variable DFElevated -Scope Global -ErrorAction Ignore }
    }
    It 'uses Start-Process -Verb RunAs for the RunAs method and reports only the exit code' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $r = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'm', 'install', 'a b' `
            -Elevation ([pscustomobject]@{ Method = 'RunAs' })
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*separate administrator window*'
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $Verb -eq 'RunAs' -and $Wait -and $FilePath -eq 'm' -and $ArgumentList -contains '"a b"' }
    }
    It 'refuses a step that needs admin when elevation is Unavailable' {
        Mock Start-Process { }
        $r = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'm' `
            -Elevation ([pscustomobject]@{ Method = 'Unavailable'; Detail = 'no one to answer the admin prompt' })
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Be 'm needs administrator rights: no one to answer the admin prompt'
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'Invoke-DFManagerCommand -Environment' {
    BeforeAll {
        function script:Probe { [CmdletBinding()] param($Name) [Environment]::GetEnvironmentVariable($Name) }
        function script:Boom { [CmdletBinding()] param($Name) throw 'no' }
        function script:SetsIt { [CmdletBinding()] param($Name) Set-Item "Env:\$Name" 'from-manager' }
    }
    BeforeEach {
        $script:SavedState = $global:DFEnvState
        $global:DFEnvState = $null
        $script:Var = "DF_TEST_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $script:Wanted = [ordered]@{ $script:Var = 'C:\x' }
        $script:Run = { param($Function = 'Probe') Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Function $Function -Arguments @{ Name = $script:Var } -Environment $script:Wanted }
    }
    AfterEach {
        Remove-Item "Env:\$script:Var" -ErrorAction Ignore
        $global:DFEnvState = $script:SavedState
    }

    It 'passes an unset variable to the command' {
        (& $script:Run).Output.Trim() | Should -Be 'C:\x'
        Test-Path "Env:\$script:Var" | Should -BeFalse
    }
    It 'updates a variable DotForge wrote' {
        Set-Item "Env:\$script:Var" 'old'
        (Get-DFEnvState).Written[$script:Var] = 'old'
        (& $script:Run).Output.Trim() | Should -Be 'C:\x'
        (Get-Item "Env:\$script:Var").Value | Should -Be 'old'
    }
    It 'keeps a variable set outside DotForge' {
        Set-Item "Env:\$script:Var" 'mine'
        $out = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Function Probe -Arguments @{ Name = $script:Var } -Environment $script:Wanted -Verbose 4>&1
        ($out | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Output.Trim() | Should -Be 'mine'
        "$(@($out | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }))" | Should -BeLike "*$script:Var*"
        (Get-Item "Env:\$script:Var").Value | Should -Be 'mine'
    }
    It 'leaves an outside value that equals the wanted one in place' {
        Set-Item "Env:\$script:Var" 'C:\x'
        $null = & $script:Run
        (Get-Item "Env:\$script:Var").Value | Should -Be 'C:\x'
    }
    It 'restores after the command throws' {
        (& $script:Run 'Boom').ExitCode | Should -Be 1
        Test-Path "Env:\$script:Var" | Should -BeFalse
    }
    It "restores after an argv whose program doesn't exist" {
        try { $null = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'df-no-such-exe-zz' -Environment $script:Wanted } catch { }
        Test-Path "Env:\$script:Var" | Should -BeFalse
    }
    It 'keeps a value the command itself set' {
        $null = & $script:Run 'SetsIt'
        (Get-Item "Env:\$script:Var").Value | Should -Be 'from-manager'
    }
    It 'passes the variables to a child process' {
        $r = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv (Get-Process -Id $PID).Path, '-NoProfile', '-Command', "`$env:$script:Var" -Environment $script:Wanted
        $r.Output.Trim() | Should -Be 'C:\x'
    }
    It "says Windows' sudo doesn't pass the variables, in the output and as a warning" {
        function global:dffake-winsudo { 'ran' }
        try {
            $r = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'm', 'install', 'x' -Environment $script:Wanted `
                -Elevation ([pscustomobject]@{ Method = 'WindowsSudo'; Executable = 'dffake-winsudo' }) -WarningVariable warned 3>$null
            $r.Output | Should -BeLike "*not passed through Windows' sudo: $script:Var*"
            "$warned" | Should -BeLike "*$script:Var*"
        } finally { Remove-DFTestGlobal -Function dffake-winsudo }
    }
    It "says nothing about Windows' sudo without variables" {
        function global:dffake-winsudo { 'ran' }
        try {
            $r = Invoke-DFManagerCommand -Operation install -Manager $script:Mgr -Argv 'm', 'install', 'x' -Environment ([ordered]@{}) `
                -Elevation ([pscustomobject]@{ Method = 'WindowsSudo'; Executable = 'dffake-winsudo' }) -WarningVariable warned 3>$null
            $r.Output | Should -Not -BeLike '*not passed*'
            $warned | Should -BeNullOrEmpty
        } finally { Remove-DFTestGlobal -Function dffake-winsudo }
    }
    It 'leaves Get-DFEnvState unchanged' {
        $null = & $script:Run
        (Get-DFEnvState).Written.Count | Should -Be 0
        (Get-DFEnvState).Kept.Count | Should -Be 0
    }
}
