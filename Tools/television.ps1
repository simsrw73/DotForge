# Companion for television (tv) — loads tv's PowerShell integration (its
# completer and its history / smart-autocomplete functions) without tv's own key
# bindings, then binds Ctrl+R / Ctrl+T when television wins history-search /
# path-insert. tv init power-shell ends by binding both keys itself; DotForge
# removes those calls so only role winners bind keys, and loads the rest as the
# module DotForge.Television so its functions outlive this companion. tv's
# function names are an undocumented dependency (docs/external-dependencies.md):
# if one disappears, its key stays unbound and the status says so.
# Theme and config: one-time setup (Tools/television.json, Tools/television.setup.ps1).

$_init = Get-DFCachedCommandOutput -Name 'television-init' -Executable 'tv' -Generate {
    Remove-DFKeyHandlerCall -Script (tv init power-shell | Out-String)
}
if ($_init) {
    New-Module -Name 'DotForge.Television' -ScriptBlock ([scriptblock]::Create($_init)) | Import-Module -Global -Force
} else {
    Add-DFToolNote -Tool 'television' -Note "couldn't load tv's PowerShell integration (tv init power-shell); Ctrl+R/Ctrl+T aren't bound to tv"
}

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    if (-not (Get-Command -Name Invoke-TvShellHistory -ErrorAction Ignore)) {
        Add-DFToolNote -Tool $Tool.name -Note "tv no longer defines Invoke-TvShellHistory, so Ctrl+R isn't bound"
        return
    }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+r' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -BriefDescription 'DotForge history-search (tv)' -Description 'Search history with television (DotForge)' -ScriptBlock { Invoke-TvShellHistory }
    }
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    if (-not (Get-Command -Name Invoke-TvSmartAutocomplete -ErrorAction Ignore)) {
        Add-DFToolNote -Tool $Tool.name -Note "tv no longer defines Invoke-TvSmartAutocomplete, so Ctrl+T isn't bound"
        return
    }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+t' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -BriefDescription 'DotForge path-insert (tv)' -Description 'Smart autocomplete with television (DotForge)' -ScriptBlock { Invoke-TvSmartAutocomplete }
    }
}
