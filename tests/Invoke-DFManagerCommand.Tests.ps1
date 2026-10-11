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
