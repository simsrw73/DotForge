BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # The shipped tool DB, keyed by name.
    $script:Db = @{}
    Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
        $t = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $script:Db[$t.name] = $t
    }
}

Describe 'prompt engine ordering against zoxide' {
    BeforeEach { Reset-DFTestSession }
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
    BeforeEach { Reset-DFTestSession }
    It 'initializes starship from cached full-init output' {
        $src = Get-Content "$PSScriptRoot/../Tools/starship.ps1" -Raw
        $src | Should -Match "Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship'"
        $src | Should -Match 'starship init powershell --print-full-init'
    }

    Context 'transient prompt helpers' {
        BeforeAll {
            # Stand-in for starship's init: like the real script, it defines its
            # helpers inside a dynamic module created with New-Module. Global so the
            # companion can see it from inside the module scope below.
            function global:Get-DFCachedCommandOutput {
                param($Name, $Executable, $Generate)
                '$null = New-Module starship { function Enable-TransientPrompt { ''enabled'' }; ' +
                'function Disable-TransientPrompt { }; ' +
                'Export-ModuleMember -Function Enable-TransientPrompt, Disable-TransientPrompt }'
            }
        }
        AfterAll {
            Remove-DFTestGlobal -Function 'Get-DFCachedCommandOutput'
            Remove-Module starship, DFCompanionHost -Force -ErrorAction Ignore
        }

        It 'exposes Enable-TransientPrompt globally when run from a module scope' {
            # Register-DFTool dot-sources companions inside DotForge's module session
            # state; without the global re-import the helpers stay stranded there.
            $companion = (Resolve-Path "$PSScriptRoot/../Tools/starship.ps1").Path
            $null = New-Module DFCompanionHost -ArgumentList $companion {
                param($Path)
                . $Path; . Initialize-DFRolePrompt -Role prompt
                # Like DotForge's manifest, export only the host's own functions
                # (none) — so nothing leaks out except what the companion re-imports.
                Export-ModuleMember -Function @()
            }
            (Get-Command Enable-TransientPrompt -ErrorAction Ignore)?.ModuleName | Should -Be 'starship'
            Enable-TransientPrompt | Should -Be 'enabled'
        }
    }
}

Describe 'starship XDG defaults' {
    BeforeEach { Reset-DFTestSession }
    It 'keeps its config in its own folder under XDG_CONFIG_HOME' {
        $script:Db['starship'].xdg.vars.STARSHIP_CONFIG | Should -Be '${XDG_CONFIG_HOME}/starship/starship.toml'
    }
}

Describe 'starship companion contract' {
    BeforeEach { Reset-DFTestSession }
    AfterEach { Remove-DFTestGlobal -Function 'Get-DFCachedCommandOutput' }

    It 'only defines its hook when dot-sourced; the prompt init runs only through the hook' {
        function global:Get-DFCachedCommandOutput { throw 'init ran outside the hook' }
        $definedHook = & { . "$PSScriptRoot/../Tools/starship.ps1"; Test-Path function:Initialize-DFRolePrompt }
        $definedHook | Should -BeTrue
    }
}
