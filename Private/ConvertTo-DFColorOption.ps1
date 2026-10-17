#Requires -Version 7.2

function ConvertTo-DFColorOption {
    <#
    .SYNOPSIS
        Builds a --color=name:value,... option from a theme file's "colors" object, skipping invalid entries.
    .DESCRIPTION
        fzf and skim share this grammar. The option becomes a raw token in
        FZF_DEFAULT_OPTS / SKIM_DEFAULT_OPTIONS, which the tool splits into
        options, so only the documented color grammar is accepted (hex, -1,
        0-255, default, or a color name, each optionally followed by :bold and
        similar); anything else is skipped with a warning, so a theme file can't
        inject an option such as --bind=execute(...).
    .PARAMETER Path
        The theme file.
    .PARAMETER Tool
        The tool name, for the warning.
    .OUTPUTS
        System.String, or $null when the file has no valid colors.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tool)
    $theme = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $colors = $theme.PSObject.Properties['colors']?.Value
    if (-not $colors) { return $null }
    $validKey   = '^[A-Za-z][A-Za-z0-9_-]*\+?$'
    $validValue = '^(#[0-9A-Fa-f]{3,8}|-1|[0-9]{1,3}|default|[A-Za-z]+(:(bold|underline|reverse|italic|dim|strikethrough))*)$'
    $pairs = @(foreach ($entry in $colors.PSObject.Properties) {
        if ($entry.Name -cmatch $validKey -and [string]$entry.Value -cmatch $validValue) {
            "$($entry.Name):$($entry.Value)"
        } else {
            Write-Warning "DotForge: invalid $Tool color entry '$($entry.Name)':'$($entry.Value)' — skipping"
        }
    })
    if ($pairs.Count -eq 0) { return $null }
    '--color=' + ($pairs -join ',')
}
