BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
}

Describe 'Get-DFCommandConflict' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        # 'cat' mirrors the real bat.json collision; 'ff' is a picker alias.
        @'
{
  "name": "testtool",
  "executable": "testtool.exe",
  "xdg": { "compliance": "none", "method": "default" },
  "aliases": { "cat": { "command": "bat", "args": [] } },
  "picker": { "alias": "ff", "function": "Select-TestTool", "list": "testtool list", "action": "output" }
}
'@ | Set-Content (Join-Path $script:TmpTools 'testtool.json')

        $script:SavedConfig = $Global:DFConfig
        $Global:DFConfig = $null
    }

    AfterEach {
        $Global:DFConfig = $script:SavedConfig
    }

    It 'returns nothing when no coreutils hook applies to this host' {
        # The hook is injected per-host, so a host that never loads it (e.g. VS Code)
        # must report no conflict even when coreutils is installed machine-wide.
        Mock Get-DFCoreutilsShadowSet { @() }
        Get-DFCommandConflict -ToolsPath $script:TmpTools | Should -BeNullOrEmpty
    }

    It 'reports a tool alias that coreutils shadows' {
        Mock Get-DFCoreutilsShadowSet { [string[]]@('cat', 'touch', 'ls') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools)
        $c.Command | Should -Contain 'cat'
    }

    It 'does not report DotForge commands coreutils leaves alone' {
        Mock Get-DFCoreutilsShadowSet { [string[]]@('cat', 'touch', 'ls') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools)
        # 'ff' is a DotForge picker alias but is not a coreutils utility.
        $c.Command | Should -Not -Contain 'ff'
        # 'ls' is a coreutils utility but this fixture's tool does not declare it.
        $c.Command | Should -Not -Contain 'ls'
    }

    It 'picks up a newly added tool alias with no code change' {
        # The owned-name set is derived from the tool database, so a future tool that
        # declares a colliding alias is covered automatically.
        @'
{
  "name": "futuretool",
  "executable": "futuretool.exe",
  "xdg": { "compliance": "none", "method": "default" },
  "aliases": { "sort": { "command": "futuretool", "args": ["--sort"] } },
  "picker": null
}
'@ | Set-Content (Join-Path $script:TmpTools 'futuretool.json')
        $script:DFToolDb = $null
        Mock Get-DFCoreutilsShadowSet { [string[]]@('sort') }
        (@(Get-DFCommandConflict -ToolsPath $script:TmpTools)).Command | Should -Contain 'sort'
    }

    It 'surfaces the exact fix command' {
        Mock Get-DFCoreutilsShadowSet { [string[]]@('cat') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools)
        $c[0].Fix | Should -BeLike '*coreutils-manager disable cat*'
        $c[0].ShadowedBy | Should -Be 'coreutils'
        $c[0].DisableWith | Should -Be 'cat'
    }

    It "resolves 'la' to 'ls', which is the utility coreutils-manager accepts" {
        # There is no la.cmd: the installer synthesizes 'la' into the hook only while
        # 'ls' is enabled, and `coreutils-manager disable la` is rejected. Suggesting
        # it would hand the user a command that fails.
        @'
{
  "name": "ezalike",
  "executable": "ezalike.exe",
  "xdg": { "compliance": "none", "method": "default" },
  "aliases": { "la": { "command": "eza", "args": ["--all"] } },
  "picker": null
}
'@ | Set-Content (Join-Path $script:TmpTools 'ezalike.json')
        $script:DFToolDb = $null
        Mock Get-DFCoreutilsShadowSet { [string[]]@('la', 'ls') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools)
        ($c | Where-Object Command -eq 'la').DisableWith | Should -Be 'ls'
        ($c | Where-Object Command -eq 'la').Fix | Should -Not -BeLike '*disable la*'
    }

    It 'suppresses conflicts listed in $DFConfig.IgnoreConflicts' {
        Mock Get-DFCoreutilsShadowSet { [string[]]@('cat') }
        $Global:DFConfig = @{ IgnoreConflicts = @('cat') }
        Get-DFCommandConflict -ToolsPath $script:TmpTools | Should -BeNullOrEmpty
    }

    It 'still reports ignored conflicts with -IncludeIgnored, flagged as Ignored' {
        Mock Get-DFCoreutilsShadowSet { [string[]]@('cat') }
        $Global:DFConfig = @{ IgnoreConflicts = @('cat') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools -IncludeIgnored)
        $c.Command | Should -Contain 'cat'
        ($c | Where-Object Command -eq 'cat').Ignored | Should -BeTrue
    }

    It 'reports the module helper aliases from the manifest, not just tool aliases' {
        # touch/env/paste are created at import by Public/*.ps1 with -Scope Global, so
        # the module never owns them and ExportedAliases is empty — AliasesToExport in
        # the manifest is the only maintained list of them.
        Mock Get-DFCoreutilsShadowSet { [string[]]@('touch', 'env', 'paste') }
        $c = @(Get-DFCommandConflict -ToolsPath $script:TmpTools)
        $c.Command | Should -Contain 'touch'
        $c.Command | Should -Contain 'env'
    }
}

Describe 'Get-DFCoreutilsShadowSet' {
    BeforeEach {
        $script:FakeProfile = Join-Path $TestDrive 'Microsoft.PowerShell_profile.ps1'
    }

    AfterEach {
        Remove-Variable -Name '__COREUTILS__' -Scope Global -ErrorAction Ignore
    }

    It 'returns empty when the profile carries no coreutils marker' {
        'Write-Host "an ordinary profile"' | Set-Content $script:FakeProfile
        Get-DFCoreutilsShadowSet -ProfilePath $script:FakeProfile | Should -BeNullOrEmpty
    }

    It 'returns empty when the profile does not exist' {
        Get-DFCoreutilsShadowSet -ProfilePath (Join-Path $TestDrive 'nope.ps1') |
            Should -BeNullOrEmpty
    }

    It 'reads the live set once the hook has loaded' {
        $Global:__COREUTILS__ = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@('cat', 'ls'), [System.StringComparer]::OrdinalIgnoreCase)
        $s = Get-DFCoreutilsShadowSet -ProfilePath $script:FakeProfile
        $s | Should -Contain 'cat'
        $s | Should -Contain 'ls'
    }

    It 'parses the pending hook from the profile before it has loaded' {
        # Regression: profiles load CurrentUserAllHosts (Register-DFTool -All) BEFORE
        # CurrentUserCurrentHost (the hook), so at check time $__COREUTILS__ does not
        # exist yet. Reading only the variable made this check dead code in a real
        # profile — it must fall back to the file.
        @'
# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a
$script:__COREUTILS__ = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('cat','ls','touch'),
    [System.StringComparer]::OrdinalIgnoreCase
)
# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a
'@ | Set-Content $script:FakeProfile

        Remove-Variable -Name '__COREUTILS__' -Scope Global -ErrorAction Ignore
        $s = Get-DFCoreutilsShadowSet -ProfilePath $script:FakeProfile
        $s | Should -Contain 'cat'
        $s | Should -Contain 'ls'
        $s | Should -Contain 'touch'
    }

    It 'prefers the loaded variable over the profile text' {
        # After `coreutils-manager disable ls` the registry and profile are rewritten,
        # but a session that already loaded the old hook keeps the old set. The live
        # variable is what the hook actually consults, so it wins.
        @'
# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a
$script:__COREUTILS__ = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('cat','ls','touch'),
    [System.StringComparer]::OrdinalIgnoreCase
)
'@ | Set-Content $script:FakeProfile
        $Global:__COREUTILS__ = [string[]]@('cat')

        $s = Get-DFCoreutilsShadowSet -ProfilePath $script:FakeProfile
        $s | Should -Contain 'cat'
        $s | Should -Not -Contain 'ls'
    }
}
