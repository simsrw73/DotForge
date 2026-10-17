# One-time setup for television: download tv's channels once (tv update-channels)
# into $TELEVISION_CONFIG\cable, so its channels (files, git, env, ...) exist.
# The seeds (config.toml when absent, the four catppuccin themes) and the note
# for an existing config.toml are declared in Tools/television.json and run
# before this. A failed download doesn't fail setup: it leaves a note instead,
# so an offline start doesn't retry it every time. To run it again yourself:
# tv update-channels. To skip: SkipSetup = @('television').
Write-Host 'DotForge: downloading television channels (once)…'
$_ok = $false
try {
    tv update-channels *> $null
    $_ok = $LASTEXITCODE -eq 0
} catch {
    $_ok = $false
}
if (-not $_ok) { Add-DFToolSetupNote -Name 'television' -Text "couldn't download television's channels; run 'tv update-channels' to get them." }
Complete-DFToolSetup -Name 'television' -Actions @(@{ type = 'updateChannels'; ok = $_ok })
