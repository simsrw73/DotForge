BeforeAll {
    $script:RealTools    = Join-Path $PSScriptRoot '../Tools'
    $script:CompanionPath = Join-Path $script:RealTools 'rustup.ps1'
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
}

Describe 'rustup tool JSON' {
    It 'relocates RUSTUP_HOME and CARGO_HOME under XDG_DATA_HOME' {
        $j = Get-Content (Join-Path $script:RealTools 'rustup.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.RUSTUP_HOME | Should -Be '${XDG_DATA_HOME}/rustup'
        $j.xdg.vars.CARGO_HOME  | Should -Be '${XDG_DATA_HOME}/cargo'
    }
}

Describe 'rustup companion' {
    BeforeEach {
        $script:SavedPath = $Env:Path
        $script:SavedCargoHome = $Env:CARGO_HOME
        $Env:Path       = 'C:\Windows\System32'
        $Env:CARGO_HOME = 'C:\fake\xdg-data\cargo'
    }

    AfterEach {
        $Env:Path       = $script:SavedPath
        $Env:CARGO_HOME = $script:SavedCargoHome
    }

    It 'adds $CARGO_HOME/bin to PATH' {
        . $script:CompanionPath
        ($Env:Path -split [IO.Path]::PathSeparator) | Should -Contain 'C:\fake\xdg-data\cargo\bin'
    }
}
