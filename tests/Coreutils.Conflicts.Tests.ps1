BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"

    $script:Coreutils = (Get-Content "$PSScriptRoot/data/coreutils-commands.json" -Raw |
        ConvertFrom-Json).commands

    # Collisions we have consciously accepted. Each entry is a decision, not an
    # oversight: DotForge ships the alias knowing coreutils shadows it on machines
    # where that utility is enabled, and Get-DFCommandConflict tells the user at
    # runtime so they can pick a side.
    #
    # Adding a name here is the whole point of this tripwire — it should be a
    # deliberate act, with a reason.
    $script:AcceptedCollisions = @{
        'cat'   = 'bat.json aliases cat -> bat. Deliberate: bat is a cat replacement.'
        'ls'    = 'eza.json aliases ls -> eza. Deliberate: eza is an ls replacement.'
        'la'    = 'eza.json aliases la -> eza. Not a coreutils utility itself; the installer synthesizes it while ls is enabled.'
        'touch' = 'DFHelpers.FileSystem.ps1 aliases touch -> New-DFFile.'
        'env'   = 'DFHelpers.Environment.ps1 aliases env -> Get-DFEnv.'
        'paste' = 'DFHelpers.Clipboard.ps1 aliases paste -> Get-DFFromClipboard.'
    }

    # Every command name DotForge creates, from the two places it creates them:
    # the manifest's AliasesToExport (helper aliases, created at import with
    # -Scope Global, so the module never owns them and ExportedAliases is empty),
    # and the tool database (tool aliases + picker aliases).
    $script:OwnedNames = [System.Collections.Generic.List[string]]::new()

    $manifestData = Import-PowerShellDataFile "$PSScriptRoot/../DotForge.psd1"
    if ($manifestData.AliasesToExport) {
        $script:OwnedNames.AddRange([string[]]@($manifestData.AliasesToExport))
    }

    $db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
    foreach ($tool in $db.Values) {
        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) { $script:OwnedNames.AddRange([string[]]@($aliases.PSObject.Properties.Name)) }
        $picker = $tool.PSObject.Properties['picker']?.Value
        if ($picker -is [PSCustomObject]) {
            $pAlias = $picker.PSObject.Properties['alias']?.Value
            if ($pAlias) { $script:OwnedNames.Add([string]$pAlias) }
        }
    }
    $script:OwnedNames = @($script:OwnedNames | Sort-Object -Unique)
}

Describe 'Coreutils collision tripwire' {
    It 'flags any DotForge command that collides with coreutils and is not an accepted decision' {
        # Why this test exists: the runtime check (Get-DFCommandConflict) only fires on
        # machines that actually have coreutils. A contributor without it can add an
        # alias named `sort` or `stat` and never notice they have shipped a command that
        # silently cannot run for coreutils users -- the coreutils readline hook rewrites
        # the name before PowerShell resolves it, and Get-Command still reports
        # DotForge's version, so nothing looks wrong locally.
        $unexpected = $script:OwnedNames |
            Where-Object { $script:Coreutils -contains $_ } |
            Where-Object { -not $script:AcceptedCollisions.ContainsKey($_) }

        $unexpected | Should -BeNullOrEmpty -Because @"
these DotForge commands collide with a coreutils utility of the same name: $($unexpected -join ', ').
Coreutils' readline hook rewrites the name before PowerShell resolves it, so on a machine
where that utility is enabled the DotForge command never runs -- and Get-Command still
reports DotForge's version, so it looks fine while failing.
Either rename the command, or accept the collision by adding it to `$script:AcceptedCollisions
in this file with the reason. Users are warned at runtime by Get-DFCommandConflict.
"@
    }

    It 'keeps the accepted-collision list honest: every entry still collides' {
        # If coreutils drops a utility, or we rename an alias, the entry is dead weight
        # and should go -- otherwise the list slowly stops describing reality.
        foreach ($name in $script:AcceptedCollisions.Keys) {
            # 'la' is the documented exception: it is not a utility, it is synthesized
            # into the hook by the installer while 'ls' is enabled.
            if ($name -eq 'la') { continue }
            $script:Coreutils | Should -Contain $name -Because "'$name' is listed as an accepted coreutils collision but coreutils no longer ships it"
        }
    }

    It 'keeps the accepted-collision list honest: every entry is still a DotForge command' {
        foreach ($name in $script:AcceptedCollisions.Keys) {
            $script:OwnedNames | Should -Contain $name -Because "'$name' is listed as an accepted coreutils collision but DotForge no longer creates it"
        }
    }

    It 'gives a reason for every accepted collision' {
        foreach ($name in $script:AcceptedCollisions.Keys) {
            $script:AcceptedCollisions[$name] | Should -Not -BeNullOrEmpty
        }
    }

    It "does not list 'la' as a coreutils utility" {
        # Guards the fixture itself: coreutils-manager rejects `disable la`, so if this
        # ever appears in the list, Get-DFCommandConflict's la -> ls mapping needs review.
        $script:Coreutils | Should -Not -Contain 'la'
    }
}
