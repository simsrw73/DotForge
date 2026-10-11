BeforeDiscovery {
    $script:ToolCases = foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools/*.json") {
        @{ name = $file.BaseName; path = $file.FullName }
    }
}

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Every config, data or state path DotForge relocates must say where the tool
# keeps it by default, so a user's existing config is found before it's hidden
# (docs/superpowers/specs/2026-10-11-config-ownership-design.md).
Describe 'Old locations are declared for every relocated path' {
    It '<name> declares xdg.native for each relocated path' -ForEach $script:ToolCases {
        $record = ConvertTo-DFToolRecord (Get-Content $path -Raw | ConvertFrom-Json)
        $missing = @(Get-DFToolRelocation -Tool $record | Where-Object { -not $_.Native } | ForEach-Object Key)
        $missing | Should -BeNullOrEmpty -Because "add xdg.native entries for: $($missing -join ', ') (use [] when the default location is the XDG one)"
    }
    It '<name> declares an old location for what its wrapper relocates' -ForEach $script:ToolCases {
        $record = ConvertTo-DFToolRecord (Get-Content $path -Raw | ConvertFrom-Json)
        if ($record.xdg?.method -ne 'wrapper') { return }
        @(if ($record.xdg.native) { $record.xdg.native.PSObject.Properties }).Count | Should -BeGreaterThan 0
    }
}
