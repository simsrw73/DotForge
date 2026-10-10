#Requires -Version 7.0

$script:DFToolRegistry = $null

function Get-DFToolRecordHash {
    <#
    .SYNOPSIS
        The registry key for a tool record's JSON: SHA-256 of its text with line endings normalized to LF.
    .PARAMETER Text
        The JSON text.
    .OUTPUTS
        System.String. Lowercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n").TrimStart([char]0xFEFF))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-DFToolRegistry {
    <#
    .SYNOPSIS
        Returns the shipped tool registry: tool name -> { sha256; record }, loaded once.
    .DESCRIPTION
        data/tool-registry.json (built by build/Build-DFToolRegistry.ps1) holds
        every shipped tool record already validated and normalized, so loading
        a tool skips parsing, validating and normalizing its JSON. An entry is
        used only when the hash of the JSON being read matches, so an edited
        record (or a user's own) always takes the slow path. A missing or
        unreadable registry is an empty one.
    .PARAMETER Path
        The registry file. Default: data/tool-registry.json in the module.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    if (-not $Path -and $null -ne $script:DFToolRegistry) { return $script:DFToolRegistry }
    $file = if ($Path) { $Path } else { Join-Path $PSScriptRoot '..' 'data' 'tool-registry.json' }
    $reg = @{}
    try {
        if ([IO.File]::Exists($file)) {
            $doc = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            foreach ($p in $doc.tools.PSObject.Properties) { $reg[$p.Name] = $p.Value }
        }
    } catch {
        Write-Verbose "DotForge: couldn't read the tool registry ($file): $($_.Exception.Message)"
        $reg = @{}
    }
    if (-not $Path) { $script:DFToolRegistry = $reg }
    $reg
}
