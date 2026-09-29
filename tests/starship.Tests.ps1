BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"

    # The shipped tool DB, keyed by name.
    $script:Db = @{}
    Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
        $t = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $script:Db[$t.name] = $t
    }
}

Describe 'prompt engine ordering against zoxide' {
    # zoxide --hook pwd wraps function:prompt; a prompt engine initialized after
    # it replaces that wrapper and silently stops directory tracking.
    It '<Engine> registers before zoxide in the shipped tool set' -ForEach @(
        @{ Engine = 'starship' }
        @{ Engine = 'oh-my-posh' }
    ) {
        # .NET randomizes string hashes per process, so hash order can't be
        # relied on to expose a missing dependsOn — put zoxide first on purpose.
        $tools = @($script:Db['zoxide']) + @($script:Db.Values | Where-Object name -ne 'zoxide')
        $order = @(Invoke-DFTopoSort -Tools $tools).name
        $order.IndexOf($Engine) | Should -BeGreaterOrEqual 0
        $order.IndexOf($Engine) | Should -BeLessThan $order.IndexOf('zoxide')
    }
}

Describe 'starship companion' {
    It 'initializes starship from cached full-init output' {
        $src = Get-Content "$PSScriptRoot/../Tools/starship.ps1" -Raw
        $src | Should -Match "Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship'"
        $src | Should -Match 'starship init powershell --print-full-init'
    }
}
