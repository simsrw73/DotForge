# One-time setup for television: download tv's channels once (tv update-channels)
# into $TELEVISION_CONFIG\cable, so its channels (files, git, env, ...) exist.
# The seeds (config.toml when absent, the four catppuccin themes) and the note
# for an existing config.toml are declared in Tools/television.json and run
# before this. A failed download doesn't fail setup: it leaves a note instead,
# so an offline start doesn't retry it every time. A download still running
# after 60 s (a stalled network) is stopped and counts as failed, so it can't
# hang the shell start. To run it again yourself: tv update-channels.
# To skip: SkipSetup = @('television').
Write-Host 'DotForge: downloading television channels (once)…'
$_ok = $false
try {
    $_tv = (Get-Command tv -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    $_ok = (Invoke-DFBoundedProcess -FilePath ($_tv ?? 'tv') -ArgumentList 'update-channels' -TimeoutSeconds 60).ExitCode -eq 0
} catch {
    Write-Verbose "DotForge: television: $($_.Exception.Message)"
    $_ok = $false
}
if (-not $_ok) { Add-DFToolSetupNote -Name 'television' -Text "couldn't download television's channels; run 'tv update-channels' to get them." }
Complete-DFToolSetup -Name 'television' -Actions @(@{ type = 'updateChannels'; ok = $_ok })
