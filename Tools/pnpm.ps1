# Companion for pnpm: its global commands live in $Env:PNPM_HOME (set from xdg.vars, or by you), so
# they go on PATH. Reads nothing from $DFConfig; writes no files.
if ($Env:PNPM_HOME) { Add-DFToPath $Env:PNPM_HOME }