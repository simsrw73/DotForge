#Requires -Version 7.2

# The script-installer source (T-84): a tool whose installer is a script from its vendor
# (irm <url> | iex) declares it in packages.script:
#   { "id": "<https url>", "installed": "<path template>", "update": [argv] | "self", "remove": [path templates] }
# DotForge passes only the URL ({id}) to these functions; each finds the rest of the entry in the
# tool records. Only an https URL a record names is ever downloaded and run, and only declared
# paths inside the home folder are ever deleted. See docs/superpowers/specs/2026-10-27-claude-code-design.md.

function Find-DFScriptPackage {
    <#
    .SYNOPSIS
        The tool record and packages.script entry whose installer URL is -Url; throws when no record names it.
    .PARAMETER Url
        The installer URL.
    .OUTPUTS
        PSCustomObject: Tool (the record), Entry (its packages.script object).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    foreach ($tool in (Import-DFToolDb).Values) {
        $entry = if ($tool.packages) { $tool.packages.PSObject.Properties['script']?.Value }
        if ($entry -is [pscustomobject] -and $entry.PSObject.Properties['id']?.Value -ceq $Url) {
            return [pscustomobject]@{ Tool = $tool; Entry = $entry }
        }
    }
    throw "DotForge: no tool record names the installer $Url, so it isn't run."
}

function Expand-DFScriptPath {
    <#
    .SYNOPSIS
        Expands a packages.script path template (${HOME} or ${XDG_*}) to a canonical path.
    .PARAMETER Template
        The template.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)
    ConvertTo-DFPath (Expand-DFXdgPath ($Template.Replace('${HOME}', $HOME)))
}

function Invoke-DFScriptDownload {
    <#
    .SYNOPSIS
        Downloads an installer script's text (a seam tests mock).
    .PARAMETER Url
        The https URL.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Url)
    [string](Invoke-RestMethod -Uri $Url -ErrorAction Stop)
}

function Invoke-DFScriptProcess {
    <#
    .SYNOPSIS
        Runs a downloaded installer script in a child pwsh, so it can't change this session (a seam tests mock).
    .DESCRIPTION
        The child inherits this process's environment, which holds the tool's
        install variables while a manager command runs (Invoke-DFManagerCommand).
    .PARAMETER Path
        The script file.
    .OUTPUTS
        System.Int32: the exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)
    & (Join-Path $PSHOME 'pwsh') -NoProfile -ExecutionPolicy Bypass -File $Path | Out-Host
    $LASTEXITCODE
}

function Install-DFScriptPackage {
    <#
    .SYNOPSIS
        Installs tools whose installer is a script: downloads each named URL, asks, runs it in a child pwsh, deletes the download.
    .DESCRIPTION
        Only an https URL a tool record names in packages.script is run. It
        asks before running each (ConfirmImpact High); -Confirm:$false (the
        restore) runs without asking, -WhatIf runs nothing.
    .PARAMETER Id
        The installer URLs (the {id} of each package).
    .OUTPUTS
        System.String: what was installed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string[]]$Id)
    foreach ($url in $Id) {
        if ($url -notmatch '^https://') { throw "DotForge: an installer must be an https URL; refusing $url." }
        $package = Find-DFScriptPackage -Url $url
        if (-not $PSCmdlet.ShouldProcess($package.Tool.name, "Download and run the installer $url")) { continue }
        $file = Join-Path ([IO.Path]::GetTempPath()) ("dotforge-install-" + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Set-Content -LiteralPath $file -Value (Invoke-DFScriptDownload -Url $url) -Encoding utf8
            $code = Invoke-DFScriptProcess -Path $file
            if ($code -ne 0) { throw "DotForge: the installer for $($package.Tool.name) ($url) exited with code $code." }
            "installed $($package.Tool.name) with $url"
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction Ignore }
    }
}

function Update-DFScriptPackage {
    <#
    .SYNOPSIS
        Updates script-installed tools with the command their record declares, or says one updates itself.
    .PARAMETER Id
        The installer URLs.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Id)
    foreach ($url in $Id) {
        $package = Find-DFScriptPackage -Url $url
        $update = @($package.Entry.PSObject.Properties['update']?.Value)
        if (-not $update -or ($update.Count -eq 1 -and $update[0] -eq 'self')) { "$($package.Tool.name) updates itself"; continue }
        $result = Invoke-DFManagerCommand -Operation update -Manager ([pscustomobject]@{ name = 'script' }) -Argv ([string[]]$update)
        if ($result.ExitCode -ne 0) { throw "DotForge: updating $($package.Tool.name) failed: $($result.Output)" }
        "updated $($package.Tool.name)"
    }
}

function Remove-DFScriptPackage {
    <#
    .SYNOPSIS
        Removes script-installed tools by deleting exactly the paths their record declares, all inside the home folder.
    .DESCRIPTION
        Every path is checked before anything is deleted: one that resolves
        outside $HOME refuses the whole removal.
    .PARAMETER Id
        The installer URLs.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string[]]$Id)
    $root = (ConvertTo-DFPath $HOME) + [IO.Path]::DirectorySeparatorChar
    foreach ($url in $Id) {
        $package = Find-DFScriptPackage -Url $url
        $paths = @(foreach ($template in @($package.Entry.PSObject.Properties['remove']?.Value)) { if ($template) { Expand-DFScriptPath $template } })
        $outside = @($paths | Where-Object { -not $_.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
        if ($outside) { throw "DotForge: $($package.Tool.name)'s record names paths outside your home folder ($($outside -join ', ')); nothing was removed." }
        foreach ($path in $paths) {
            if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, "Remove $($package.Tool.name)'s files")) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
        }
        "removed $($package.Tool.name)"
    }
}

function Get-DFScriptInstalled {
    <#
    .SYNOPSIS
        Lists script-installed tools: each record whose packages.script installed path exists.
    .PARAMETER Manager
        The script manager record.
    .OUTPUTS
        PSCustomObject with Id (the installer URL), Installed and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    foreach ($tool in (Import-DFToolDb).Values) {
        $entry = if ($tool.packages) { $tool.packages.PSObject.Properties['script']?.Value }
        if ($entry -isnot [pscustomobject]) { continue }
        $installed = $entry.PSObject.Properties['installed']?.Value
        if ($installed -and (Test-Path -LiteralPath (Expand-DFScriptPath $installed))) {
            [pscustomobject]@{ Id = $entry.id; Installed = 'installed'; Available = $null }
        }
    }
}
