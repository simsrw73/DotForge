BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Private/Get-DFRoleDb.ps1"
    . "$PSScriptRoot/../Private/Write-DFRoleNotice.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolSteps.ps1"

    $rolesFile = Join-Path $TestDrive 'roles.json'
    @'
{ "prompt": { "kind": "single", "exclusive": true,  "hook": "Initialize-DFRolePrompt" },
  "pager":  { "kind": "single", "exclusive": false, "hook": "Initialize-DFRolePager" },
  "grep":   { "kind": "category" } }
'@ | Set-Content $rolesFile
    $script:RoleDb = Get-DFRoleDb -Path $rolesFile

    function New-RoleTool([string]$Name, [hashtable]$Roles) {
        ConvertTo-DFToolRecord ([pscustomobject]@{ name = $Name; executable = "$Name.exe"; roles = [pscustomobject]$Roles })
    }
}

Describe 'Get-DFRoleWinners' {
    BeforeEach {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:Installed = @('omp.exe', 'star.exe', 'less.exe', 'bat.exe', 'rg.exe')
        Mock Test-DFToolAvailable { $Executable -in $script:Installed }
        $omp  = New-RoleTool 'omp'  @{ prompt = [pscustomobject]@{ priority = 20 } }
        $star = New-RoleTool 'star' @{ prompt = [pscustomobject]@{ priority = 10 } }
        $less = New-RoleTool 'less' @{ pager  = [pscustomobject]@{ priority = 10 } }
        $bat  = New-RoleTool 'bat'  @{ pager  = [pscustomobject]@{ priority = 10 } }
        $rg   = New-RoleTool 'rg'   @{ grep   = [pscustomobject]@{} }
        $script:Db = @{ omp = $omp; star = $star; less = $less; bat = $bat; rg = $rg }
        $script:All = @($omp, $star, $less, $bat, $rg)
    }
    AfterEach { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }

    It 'picks the highest priority candidate when Defaults is absent' {
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb
        $w['prompt'].Winner | Should -Be 'omp'
        $w['prompt'].Reason | Should -Be 'priority'
        $w['prompt'].Candidates | Should -Be @('omp', 'star')
    }

    It 'breaks a priority tie on tool name' {
        (Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb)['pager'].Winner | Should -Be 'bat'
    }

    It 'lets Defaults override priority' {
        $Global:DFConfig = @{ Defaults = @{ prompt = 'star' } }
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb
        $w['prompt'].Winner | Should -Be 'star'
        $w['prompt'].Reason | Should -Be 'Defaults'
    }

    It 'warns and falls back to priority when Defaults names a non-member' {
        $Global:DFConfig = @{ Defaults = @{ prompt = 'less' } }
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb -WarningVariable warn -WarningAction SilentlyContinue
        $w['prompt'].Winner | Should -Be 'omp'
        "$warn" | Should -Match "Defaults\['prompt'\].*less"
    }

    It 'warns when Defaults names a role that does not exist' {
        $Global:DFConfig = @{ Defaults = @{ nosuchrole = 'omp' } }
        $null = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb -WarningVariable warn -WarningAction SilentlyContinue
        "$warn" | Should -Match 'nosuchrole'
    }

    It 'falls back silently when the Defaults tool is a member but not installed' {
        $script:Installed = @('omp.exe')
        $Global:DFConfig = @{ Defaults = @{ prompt = 'star' } }
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb -WarningVariable warn
        $warn | Should -BeNullOrEmpty
        $w['prompt'].Winner | Should -Be 'omp'
        $w['prompt'].Reason | Should -Be 'sole'
    }

    It 'treats an empty Defaults value as absent, without a warning' {
        $Global:DFConfig = @{ Defaults = @{ pager = '' } }
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools $script:All -RoleDb $script:RoleDb -WarningVariable warn
        $warn | Should -BeNullOrEmpty
        $w['pager'].Reason | Should -Be 'priority'
    }

    It 'considers only the tools being registered (subset registration)' {
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools @($script:Db.star) -RoleDb $script:RoleDb
        $w['prompt'].Winner | Should -Be 'star'
        $w['prompt'].Reason | Should -Be 'sole'
    }

    It 'leaves out roles with no candidate and category roles' {
        $w = Get-DFRoleWinners -ToolDb $script:Db -Tools @($script:Db.rg) -RoleDb $script:RoleDb
        $w.Count | Should -Be 0
    }

    It 'warns about a tool that declares a role missing from the role definitions, and ignores it' {
        $odd = New-RoleTool 'odd' @{ nosuch = [pscustomobject]@{} }
        $w = Get-DFRoleWinners -ToolDb @{ odd = $odd } -Tools @($odd) -RoleDb $script:RoleDb -WarningVariable warn -WarningAction SilentlyContinue
        "$warn" | Should -Match "odd declares unknown role 'nosuch'"
        $w.Count | Should -Be 0
    }

    It 'does not warn about unknown roles when no role definitions loaded at all' {
        $odd = New-RoleTool 'odd' @{ nosuch = [pscustomobject]@{} }
        $null = Get-DFRoleWinners -ToolDb @{ odd = $odd } -Tools @($odd) -RoleDb @{} -WarningVariable warn
        $warn | Should -BeNullOrEmpty
    }
}

Describe 'Write-DFRoleNotice' {
    BeforeEach {
        $script:SavedState = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive "state-$([guid]::NewGuid())"
        $script:StateFile = Join-Path $Env:XDG_STATE_HOME 'dotforge' 'role-state.json'
        $script:Unresolved = @{ prompt = [pscustomobject]@{ Role = 'prompt'; Winner = 'omp'; Reason = 'priority'; Candidates = [string[]]@('omp', 'star') } }
    }
    AfterEach { $Env:XDG_STATE_HOME = $script:SavedState }

    It 'warns once per candidate set, naming the winner and the override' {
        Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningVariable w1 -WarningAction SilentlyContinue
        "$w1" | Should -Match "using omp"
        "$w1" | Should -Match "Defaults = @\{ 'prompt' = 'star' \}"
        Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningVariable w2
        $w2 | Should -BeNullOrEmpty
    }

    It 'warns again when the candidate set changes' {
        Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningAction SilentlyContinue
        $script:Unresolved.prompt.Candidates = [string[]]@('new', 'omp', 'star')
        Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningVariable w -WarningAction SilentlyContinue
        $w | Should -Not -BeNullOrEmpty
    }

    It 'stays quiet for non-exclusive roles and for Defaults or sole winners' {
        $quiet = @{
            pager  = [pscustomobject]@{ Role = 'pager'; Winner = 'bat'; Reason = 'priority'; Candidates = [string[]]@('bat', 'less') }
            prompt = [pscustomobject]@{ Role = 'prompt'; Winner = 'star'; Reason = 'Defaults'; Candidates = [string[]]@('omp', 'star') }
        }
        Write-DFRoleNotice -RoleWinners $quiet -RoleDb $script:RoleDb -WarningVariable w
        $w | Should -BeNullOrEmpty
        Test-Path $script:StateFile | Should -BeFalse
    }

    It 'emits no error, only the warning, when the state file cannot be read' {
        New-Item -ItemType Directory -Force (Split-Path $script:StateFile) | Out-Null
        '{}' | Set-Content $script:StateFile
        Mock Get-Content { Write-Error 'The process cannot access the file because it is being used by another process.' }
        $out = Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningVariable w -WarningAction SilentlyContinue 2>&1
        @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Should -BeNullOrEmpty
        "$w" | Should -Match 'using omp'
    }

    It 'treats a corrupt state file as empty and rewrites it as valid JSON' {
        New-Item -ItemType Directory -Force (Split-Path $script:StateFile) | Out-Null
        '{ not json' | Set-Content $script:StateFile
        { Write-DFRoleNotice -RoleWinners $script:Unresolved -RoleDb $script:RoleDb -WarningAction SilentlyContinue } | Should -Not -Throw
        (Get-Content $script:StateFile -Raw | ConvertFrom-Json).prompt | Should -Be 'omp,star'
    }
}
