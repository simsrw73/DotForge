BeforeDiscovery {
    $script:Entries = foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json') {
        $record = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $packages = $record.PSObject.Properties['packages']?.Value
        $entry = if ($packages) { $packages.PSObject.Properties['script']?.Value }
        if ($entry) { @{ Name = $record.name; Entry = $entry } }
    }
}

# Every shipped record's script installer: an https URL DotForge runs, an installed path, and
# paths it may delete rooted in the home folder or an XDG folder.
Describe 'packages.script in Tools/*.json' {
    It '<Name> names an https installer and an installed path' -ForEach $script:Entries {
        $Entry.id | Should -Match '^https://'
        $Entry.installed | Should -Match '^\$\{(HOME|XDG_[A-Z]+_HOME)\}/'
    }
    It '<Name> removes only paths rooted at ${HOME} or an XDG folder' -ForEach $script:Entries {
        foreach ($path in @($Entry.PSObject.Properties['remove']?.Value)) {
            if ($path) { $path | Should -Match '^\$\{(HOME|XDG_[A-Z]+_HOME)\}/' -Because 'DotForge deletes these paths' }
            $path | Should -Not -Match '\.\.'
        }
    }
}
