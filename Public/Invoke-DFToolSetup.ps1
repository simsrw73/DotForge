#Requires -Version 7.0

function Invoke-DFToolSetup {
    <#
    .SYNOPSIS
        Runs a tool's one-time setup again: its seeded config files, then its setup script.
    .DESCRIPTION
        Setup normally runs once per machine, the first time a tool is
        activated, and is then recorded so it never repeats (a config file you
        delete stays deleted). This clears that record for one tool and runs
        setup now. A seeded file that exists is kept, unless -Force, which
        overwrites it with DotForge's default after confirmation. The tool
        must be active in this session.
    .PARAMETER Name
        The tool.
    .PARAMETER Force
        Overwrite seeded files that exist (asks first).
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch

        Recreates fastfetch's default config if you deleted it.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch -Force

        Replaces your fastfetch config with DotForge's default.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/writing-a-tool.md
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [switch]$Force, [string]$ToolsPath)
    $s = Get-DFToolStatus -Name $Name 3>$null
    if (-not $s -or $s.State -ne 'Active') {
        Write-Error "DotForge: $Name is not active in this session; put it in Tools and run Start-DFSession first."
        return
    }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $tool = (Import-DFToolDb -Name $Name @pathArgs)[$Name]
    $toolsDir = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath } else { Join-Path $PSScriptRoot '../Tools' })
    $seed = if ($tool.setup) { $tool.setup.seed }
    if ($Force -and $seed) {
        foreach ($p in $seed.PSObject.Properties) {
            $dest = ConvertTo-DFPath (Expand-DFXdgPath $p.Name)
            if ((Test-Path -LiteralPath $dest) -and $PSCmdlet.ShouldProcess($dest, 'Overwrite with the default')) { Remove-Item -LiteralPath $dest }
        }
    }
    Clear-DFToolSetupState -Name $Name
    Invoke-DFToolCompanion -Tool $tool -ToolsPath $toolsDir -SetupOnly
}
