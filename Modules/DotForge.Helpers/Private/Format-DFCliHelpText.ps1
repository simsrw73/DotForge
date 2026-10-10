#Requires -Version 7.0

function Format-DFCliHelpText {
    <#
    .SYNOPSIS
        Pure colorizer for external CLI help text. Returns the (optionally) colorized text.
    .DESCRIPTION
        Adds bold-yellow to section headers and a faint tint to option flags. Headers are
        non-indented lines, preceded by a blank line or start-of-file, that are ALL-CAPS or
        end in a colon. Flag tinting applies to indented option lines and covers only the
        flag portion before the description gap. With Color = $false the text is returned
        unchanged (NO_COLOR / non-VT passthrough).
    .PARAMETER Text
        The raw help text to colorize.
    .PARAMETER Color
        When false, returns Text unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory, Position = 1)]
        [bool]$Color
    )
    if (-not $Color -or [string]::IsNullOrEmpty($Text)) { return $Text }

    $header   = "`e[1;33m"
    $reset    = "`e[0m"
    $faint    = "`e[2m"
    $faintOff = "`e[22m"

    $lines = $Text -split "`r?`n"
    $prevBlank = $true   # start-of-file counts as "preceded by a blank line"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $isBlank = [string]::IsNullOrWhiteSpace($line)

        if (-not $isBlank -and $prevBlank -and $line -notmatch '^\s') {
            if ($line -cmatch '^[A-Z][A-Z0-9 ./_-]+$' -or $line -match '^\S.*:\s*$') {
                $lines[$i] = "$header$line$reset"
                $prevBlank = $isBlank
                continue
            }
        }

        if ($line -match '^\s+-') {
            $m = [regex]::Match($line, '^(\s+)(\S.*?)(\s{2,}.*)?$')
            if ($m.Success) {
                $indent = $m.Groups[1].Value
                $flags  = $m.Groups[2].Value
                $rest   = $m.Groups[3].Value
                $lines[$i] = "$indent$faint$flags$faintOff$rest"
            }
        }

        $prevBlank = $isBlank
    }

    return ($lines -join "`n")
}
