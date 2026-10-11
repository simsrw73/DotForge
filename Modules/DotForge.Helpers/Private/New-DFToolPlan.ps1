#Requires -Version 7.2
# The plans New-DFTool carries out: what it writes or copies into the user tools folder.

function Get-DFNewToolPlan {
    <#
    .SYNOPSIS
        What New-DFTool -Name writes: a starter record, and optionally a companion skeleton.
    .PARAMETER Name
        The tool name.
    .PARAMETER Executable
        The program name, when it differs from the tool name.
    .PARAMETER Companion
        Also plan the companion skeleton.
    .PARAMETER Folder
        The user tools folder.
    .OUTPUTS
        PSCustomObject: Name, Action, Items (Path and Text each), Warning.
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$Executable, [switch]$Companion, [string]$Folder)

    $lookFor = if ($Executable) { $Executable } else { $Name }
    $app = @(Get-Command $lookFor -CommandType Application -ErrorAction Ignore)[0]
    $module = if (-not $app -and -not $Executable) { @(Get-Module -ListAvailable $Name)[0] }
    $warning = $null
    $record = [ordered]@{ name = $Name }
    if ($app) {
        $record.executable = $app.Name
        $record.description = [string](Get-Item -LiteralPath $app.Source -ErrorAction Ignore)?.VersionInfo?.FileDescription
    } elseif ($module) {
        $record.executable = $module.Name
        $record.type = 'module'
        $record.description = [string]$module.Description
    } else {
        $record.executable = $lookFor
        $record.description = ''
        $warning = "DotForge: '$lookFor' isn't on PATH or an installed PowerShell module; DotForge activates the tool once it is."
    }
    $record.tags = @()
    $record.aliases = [ordered]@{}
    $record.picker = $null

    $text = ($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine
    $schema = Test-DFToolSchema -Tool ($text | ConvertFrom-Json)
    if (-not $schema.Valid) { throw "DotForge: the starter record for '$Name' is invalid: $($schema.Errors -join '; ')" }

    $items = @([pscustomobject]@{ Path = Join-Path $Folder "$Name.json"; Text = $text; Source = $null })
    if ($Companion) {
        $items += [pscustomobject]@{ Path = Join-Path $Folder "$Name.ps1"; Text = (Get-DFCompanionSkeleton -Name $Name -Executable $record.executable); Source = $null }
    }
    [pscustomobject]@{ Name = $Name; Action = "Write a starter record for $Name"; Items = $items; Warning = $warning }
}

function Get-DFToolCopyPlan {
    <#
    .SYNOPSIS
        What New-DFTool -From copies: a shipped tool's record, scripts and data folder.
    .PARAMETER Name
        The shipped tool.
    .PARAMETER Folder
        The user tools folder.
    .OUTPUTS
        PSCustomObject: Name, Action, Items (Path and Source each), Warning; nothing when no such tool ships.
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$Folder)

    $shipped = Join-Path $PSScriptRoot '..' '..' '..' 'Tools'
    $json = Join-Path $shipped "$Name.json"
    if (-not (Test-Path -LiteralPath $json -PathType Leaf)) {
        Write-Error "DotForge: DotForge ships no tool named '$Name'. Get-DFTool lists the ones it does."
        return
    }
    # The record's own name, in case of a case difference on a case-insensitive file system.
    $Name = (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json).name
    $sources = foreach ($leaf in "$Name.json", "$Name.ps1", "$Name.setup.ps1", "$Name.manage.ps1", $Name) {
        $path = Join-Path $shipped $leaf
        if (Test-Path -LiteralPath $path) { $path }
    }
    [pscustomobject]@{
        Name    = $Name
        Action  = "Copy DotForge's $Name record and files"
        Items   = @(foreach ($source in $sources) { [pscustomobject]@{ Path = Join-Path $Folder (Split-Path $source -Leaf); Text = $null; Source = $source } })
        Warning = "DotForge: your copy of $Name replaces DotForge's, so DotForge's later fixes to it won't reach you. Delete the copied files from $Folder to go back."
    }
}

function Get-DFCompanionSkeleton {
    <#
    .SYNOPSIS
        The text of a new companion: comments, and commented-out picker and completer examples.
    .PARAMETER Name
        The tool name.
    .PARAMETER Executable
        The tool's program.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Name, [string]$Executable)
    $command = [IO.Path]::GetFileNameWithoutExtension($Executable)
    @"
# Companion for $Name. DotForge runs it each time it activates the tool.
#
# `$DFCurrentTool is the tool's record; `$DFCurrentTool.settings is the "settings"
# object from $Name.json, if you add one. Define commands with ``function global:``
# and aliases with ``-Scope Global``, or they're gone when this file returns.

# A picker: lists items in fzf and runs an action on the one you pick.
# function global:Select-${command}Item {
#     Invoke-DFPicker -List { $command list } -Header 'Select an item' -Action {
#         param(`$item)
#         $command open `$item
#     }
# }
# Set-Alias -Name f$command -Value Select-${command}Item -Scope Global -Force

# Tab completion for $command's arguments.
# Register-ArgumentCompleter -Native -CommandName $command, $Executable -ScriptBlock {
#     param(`$wordToComplete, `$commandAst, `$cursorPosition)
#     'build', 'test', 'run' | Where-Object { `$_ -like "`$wordToComplete*" } |
#         ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_) }
# }
"@
}
