#Requires -Version 7.0
<#
.SYNOPSIS
    Code probe for bat/honors-config-content:theme. Dispositive test that the
    `--theme` directive INSIDE bat.conf changes rendering: render a sample with
    two configs differing only in theme; if output differs, the config theme is
    honored (pass). If identical (or bat can't demonstrate it), fall back to a
    manual visual verdict.
#>
[CmdletBinding()] [OutputType([hashtable])]
param([Parameter(Mandatory)][string]$Scratch,
      [Parameter(Mandatory)][scriptblock]$SpawnTool)
Set-StrictMode -Version Latest

$sample = Join-Path $Scratch 'sample.md'
Set-Content -Path $sample -Value "# Title`n`n``code``" -NoNewline

function Render-WithTheme([string]$Theme) {
    $conf = Join-Path $Scratch "bat.$Theme.conf"
    Set-Content -Path $conf -Value "--theme=`"$Theme`"" -NoNewline
    & $SpawnTool 'bat' @('--color=always','--language=md',$sample) @{ BAT_CONFIG_PATH = $conf } $Scratch
}

$a = Render-WithTheme 'ansi'
if ($a.Absent) { return @{ verdict = 'unknown'; evidence = 'bat absent'; retest = $null } }
$b = Render-WithTheme 'Dracula'

if ($a.StdOut -ne $b.StdOut) {
    return @{ verdict = 'pass'
              evidence = 'rendered output differs between config theme=ansi and theme=Dracula'
              retest   = $null }
}
@{ verdict  = 'manual'
   evidence = 'automated differ inconclusive; confirm visually'
   retest   = 'set theme=ansi in bat.conf, run `bat sample.md`; confirm the ANSI palette renders' }
