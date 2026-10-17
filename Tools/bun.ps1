# Companion for bun: its global commands live in $Env:BUN_INSTALL (set from xdg.vars, or by you), so
# they go on PATH. Reads nothing from $DFConfig; writes no files.
if ($Env:BUN_INSTALL) { Add-DFToPath (Join-Path $Env:BUN_INSTALL 'bin') }