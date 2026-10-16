# The carapace specs DotForge bundles (Tools/carapace/specs/*.yaml), which
# Tools/carapace.ps1 deploys to $XDG_CONFIG_HOME\carapace\specs.
BeforeDiscovery {
    $script:SpecCases = foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools/carapace/specs" -Filter '*.yaml') {
        @{ Name = $file.BaseName; Path = $file.FullName }
    }
    $script:HaveCarapace = [bool](Get-Command carapace -CommandType Application -ErrorAction Ignore)
}

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    Import-Module powershell-yaml -ErrorAction Stop

    $script:ToolExecutables = foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json') {
        $record = Get-Content $file.FullName -Raw | ConvertFrom-Json
        [IO.Path]::GetFileNameWithoutExtension([string]$record.executable)
    }
}

Describe 'Bundled carapace spec <Name>' -ForEach $SpecCases {
    It 'parses, and is named after its file' {
        $spec = Get-Content $Path -Raw | ConvertFrom-Yaml
        $spec.name | Should -BeExactly $Name
    }

    It 'completes the executable of a DotForge tool' {
        $script:ToolExecutables | Should -Contain $Name
    }
}

Describe 'Bundled carapace spec <Name>, through carapace' -ForEach $SpecCases -Skip:(-not $HaveCarapace) {
    BeforeAll {
        Set-DFTestXdg
        $specDir = Join-Path $Env:XDG_CONFIG_HOME 'carapace' 'specs'
        New-Item -ItemType Directory -Force -Path $specDir | Out-Null
        Copy-Item $Path $specDir
        $script:Installed = [bool](Get-Command $Name -CommandType Application -ErrorAction Ignore)
    }
    AfterAll { Restore-DFTestXdg }

    It 'gives completions for an installed tool' {
        if (-not $script:Installed) { Set-ItResult -Skipped -Because "$Name is not installed"; return }
        # The same query the shell makes: subcommands for an empty word, flags for '-'.
        $count = 0
        foreach ($word in '', '-') {
            $answer = carapace $Name export $Name $word 2>$null | Out-String | ConvertFrom-Json
            $count += @($answer.values | Where-Object { $_.value -notmatch '[\\/]|\.\w+$' }).Count
        }
        $count | Should -BeGreaterThan 0
    }
}
