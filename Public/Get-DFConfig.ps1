#Requires -Version 7.2

function Get-DFConfig {
    <#
    .SYNOPSIS
        Reads one setting of the current DotForge session, or returns -Default when it isn't set.
    .DESCRIPTION
        Reads the configuration Start-DFSession stored for this session. It is
        read-only: to change a setting, pass a new configuration to
        Start-DFSession. A missing key or a $null value returns -Default; a
        configured $false is returned as is. Like any PowerShell command, an
        array value is written to the pipeline element by element, so read
        list settings with @(Get-DFConfig Tools).

        DotForge's on-demand modules (the package catalog and the general
        helpers) read session settings through this command.
    .PARAMETER Key
        The setting name, e.g. 'Theme' or 'Tools'.
    .PARAMETER Default
        Returned when the setting isn't configured. Default: $null.
    .EXAMPLE
        Get-DFConfig Theme

        Shows the session's color theme, e.g. catppuccin-mocha.
    .EXAMPLE
        @(Get-DFConfig Tools)

        Lists the tools and +groups this session was started with.
    .EXAMPLE
        Get-DFConfig PSReadLineEditMode -Default Windows

        Returns the configured edit mode, or Windows when none is set.
    .OUTPUTS
        System.Object. The setting's value, or -Default.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)]$Default = $null
    )
    if ($script:DFSessionConfig -and $script:DFSessionConfig.Contains($Key) -and $null -ne $script:DFSessionConfig[$Key]) {
        return $script:DFSessionConfig[$Key]
    }
    $Default
}
