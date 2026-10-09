BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Groups = Get-DFGroupDb -Path (New-Item (Join-Path $TestDrive 'groups.json') -Value (@'
{
  "core": { "description": "c", "tools": ["bat", "eza", "fzf"] },
  "git":  { "description": "g", "tools": ["delta", "gh", "bat"] }
}
'@) -Force).FullName
    $script:Known = 'bat', 'eza', 'fzf', 'delta', 'gh', 'starship', 'PSFzf'
    function script:Resolve {
        [CmdletBinding()]   # so -WarningVariable captures the warnings
        param([string[]]$Tools, [string[]]$Exclude = @())
        Resolve-DFRequestedTools -Tools $Tools -ExcludeTools $Exclude -GroupDb $script:Groups -KnownTools $script:Known
    }
}

Describe 'Resolve-DFRequestedTools' {
    It 'expands groups and keeps direct tools, in first-seen order without duplicates' {
        $r = Resolve -Tools '+core', 'starship', '+git'
        ($r | Where-Object { -not $_.Excluded }).Name | Should -Be @('bat', 'eza', 'fzf', 'starship', 'delta', 'gh')
    }
    It 'records what requested each tool, preferring a direct entry over a group' {
        $r = Resolve -Tools '+core', 'eza'
        ($r | Where-Object Name -eq 'bat').RequestedBy | Should -Be '+core'
        ($r | Where-Object Name -eq 'eza').RequestedBy | Should -Be 'Tools'
    }
    It 'uses the tool''s canonical name whatever case was typed' {
        (Resolve -Tools 'psfzf').Name | Should -Be 'PSFzf'
    }
    It 'removes excluded tools and groups but keeps them, marked Excluded' {
        $r = Resolve -Tools '+core', '+git' -Exclude 'eza', '+git'
        ($r | Where-Object { -not $_.Excluded }).Name | Should -Be @('fzf')
        ($r | Where-Object Excluded).Name | Should -Be @('bat', 'eza', 'delta', 'gh')
    }
    It 'lets an exclusion win over a direct request' {
        $r = Resolve -Tools 'bat' -Exclude 'bat'
        $r.Excluded | Should -BeTrue
    }
    It 'warns about an unknown tool, suggesting a known one, and leaves it out' {
        $r = Resolve -Tools 'batt', 'eza' 3>$null -WarningVariable w
        "$w" | Should -Match "batt.*bat"
        $r.Name | Should -Be @('eza')
    }
    It 'warns about an unknown group and leaves it out' {
        $r = Resolve -Tools '+nope', 'eza' 3>$null -WarningVariable w
        "$w" | Should -Match '\+nope'
        $r.Name | Should -Be @('eza')
    }
    It 'warns when an exclusion removes nothing that was requested' {
        $null = Resolve -Tools 'eza' -Exclude 'gh' 3>$null -WarningVariable w
        "$w" | Should -Match "gh.*not requested"
    }
    It 'returns nothing for an empty request' {
        @(Resolve -Tools @()).Count | Should -Be 0
    }
}
