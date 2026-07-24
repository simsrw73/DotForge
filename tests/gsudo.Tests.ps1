BeforeAll {
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/gsudo.ps1'
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
}

Describe 'gsudo companion' {
    BeforeEach {
        $script:SavedPath = $Env:Path
        $script:SavedWinDir = $Env:WINDIR
        $Env:Path = 'C:\Windows\System32;C:\Users\user\scoop\shims'
        $Env:WINDIR = 'C:\Windows'

        Mock Get-Command {
            param($Name)
            switch ($Name) {
                'gsudo.exe' { [PSCustomObject]@{ Path = 'C:\Users\user\scoop\shims\gsudo.exe' } }
                'sudo' { [PSCustomObject]@{ Path = 'C:\Windows\System32\sudo.exe' } }
            }
        }
    }

    AfterEach {
        $Env:Path = $script:SavedPath
        $Env:WINDIR = $script:SavedWinDir
        Remove-Alias sudo -Scope Global -Force -ErrorAction Ignore
        Remove-Item 'function:global:please' -ErrorAction Ignore
    }

    It 'moves the gsudo shim ahead of Windows sudo and wires the sudo alias' {
        . $script:CompanionPath

        Should -Invoke Get-Command -Times 1 -ParameterFilter { $Name -eq 'sudo' -and $All }
        ($Env:Path -split [IO.Path]::PathSeparator)[0] | Should -Be 'C:\Users\user\scoop\shims'
        (Get-Alias sudo).Definition | Should -Be 'gsudo'
    }
}
