# Companion for ps-dotenv — loads .env files as you change folders.
#
# Everything here runs only when ps-dotenv wins the project-env role. Dotenv is
# imported by its discovered path: scoop's install nests the manifest one level
# deeper than PowerShell expects, so `Import-Module Dotenv` by name fails
# (docs/external-dependencies.md). Update-Dotenv is chained onto
# LocationChangedAction rather than the prompt, so it needs no ordering against
# prompt engines and survives an fpot theme switch.
param()

function Initialize-DFRoleProjectEnv {
    # Called by DotForge only when ps-dotenv wins the project-env role.
    param([PSCustomObject]$Tool, [string]$Role)
    $manifest = (Get-Module -ListAvailable Dotenv | Select-Object -First 1).Path
    Import-Module $manifest -Global -ErrorAction Stop
    Enable-Dotenv
    # Set explicitly, not left to the module's shipped defaults. Async off: a
    # script doing `cd project; npm test` must see the .env already loaded.
    $Dotenv.SafeMode = [bool](Get-DFConfig DotenvSafeMode -Default $true)
    $Dotenv.Async = $false
    foreach ($dir in @(Get-DFConfig DotenvApprovedDirs)) {
        if (-not $dir) { continue }
        # ConvertTo-DFPath returns a relative path unchanged (with a warning);
        # approving it would bind it to whatever folder is current. Skip it.
        $path = ConvertTo-DFPath $dir
        if (-not [IO.Path]::IsPathRooted($path)) { continue }
        try {
            Approve-DotenvDir -Path $path -ErrorAction Stop
        } catch {
            Write-Warning "DotForge: ps-dotenv could not approve '$dir': $($_.Exception.Message)"
        }
    }
    if (-not $global:DFDotenvLocationHook) {
        $global:DFDotenvLocationHook = [EventHandler[System.Management.Automation.LocationChangedEventArgs]] { Dotenv\Update-Dotenv }
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction =
            [Delegate]::Combine($ExecutionContext.SessionState.InvokeCommand.LocationChangedAction, $global:DFDotenvLocationHook)
    }
    Dotenv\Update-Dotenv
}
