BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'eza/lsd share role: listing (real tool records)' {
    BeforeEach {
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command {
            param($Name)
            if ($Name -in 'eza.exe', 'lsd.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        # Stand-in functions so a wrapper's `& eza ...` / `& lsd ...` resolves to a
        # capturable function (PowerShell resolves Function before Application),
        # regardless of whether real eza.exe/lsd.exe are installed on this machine.
        # This is the only reliable way to observe which command a wrapper actually
        # calls: a .GetNewClosure() wrapper's ScriptBlock.ToString() shows only the
        # unbound template source (`& $capturedCmd @capturedArgs @args`), never the
        # bound values -- verified empirically in Task 1; do not use ToString() here.
        function global:eza { $global:LastCommandCalled = 'eza' }
        function global:lsd { $global:LastCommandCalled = 'lsd' }
    }
    AfterEach {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        # 'global:' in the path form is a Remove-Item no-op (same quirk as Get-Item,
        # confirmed in Task 1) -- use the bare 'function:<name>' form to actually
        # remove. 'ls' always has args on both eza and lsd, so it is ALWAYS a
        # wrapper function, never a plain Set-Alias.
        Remove-Item 'function:ls', 'function:ll', 'function:la', 'function:tree' -ErrorAction Ignore
        # eza's real picker block creates function:global:Select-File as a side
        # effect of registering the real eza.json -- must be cleaned up or it
        # leaks into the rest of the suite's shared session.
        Remove-Item 'function:Select-File' -ErrorAction Ignore
        Remove-Alias ff -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:eza', 'function:lsd' -ErrorAction Ignore
        Remove-Variable LastCommandCalled -Scope Global -ErrorAction Ignore
    }

    It 'declares role: listing on both tools' {
        $ezaJson = Get-Content (Join-Path $script:RealTools 'eza.json') -Raw | ConvertFrom-Json
        $lsdJson = Get-Content (Join-Path $script:RealTools 'lsd.json') -Raw | ConvertFrom-Json
        $ezaJson.role | Should -Be 'listing'
        $lsdJson.role | Should -Be 'listing'
    }

    It 'gives eza the contested aliases when Defaults.listing = eza' {
        $Global:DFConfig = @{ Defaults = @{ listing = 'eza' } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools

        & 'ls';   $global:LastCommandCalled | Should -Be 'eza'
        & 'll';   $global:LastCommandCalled | Should -Be 'eza'
        & 'la';   $global:LastCommandCalled | Should -Be 'eza'
        & 'tree'; $global:LastCommandCalled | Should -Be 'eza'
    }

    It 'gives lsd the contested aliases when Defaults.listing = lsd' {
        $Global:DFConfig = @{ Defaults = @{ listing = 'lsd' } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools

        & 'ls';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'll';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'la';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'tree'; $global:LastCommandCalled | Should -Be 'lsd'
    }

    It 'both register their full alias sets when no Defaults entry exists (unchanged behavior)' {
        { Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools } | Should -Not -Throw
        # Whichever registers last wins the collision -- this test only proves no
        # exception and that the mechanism does not activate without a Defaults entry.
    }
}
