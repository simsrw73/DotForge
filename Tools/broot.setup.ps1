# One-time setup for broot: tell broot its br shell function is handled, so it
# never offers to install its own. Its installer would add a line to your shell
# profiles and write launcher scripts under %APPDATA%\dystroy\broot\data; DotForge's
# br (Tools/broot.ps1) replaces it. The state goes into BROOT_CONFIG_DIR
# (launcher\installed-v5), which DotForge has set by now. The seeds (conf.hjson,
# verbs.hjson) are declared in Tools/broot.json and run before this. A failure
# doesn't fail setup: it leaves a note instead. To skip: SkipSetup = @('broot').
$_ok = $false
try {
    $_broot = (Get-Command broot -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    $_ok = (Invoke-DFBoundedProcess -FilePath ($_broot ?? 'broot') -ArgumentList '--set-install-state', 'installed' -TimeoutSeconds 30).ExitCode -eq 0
} catch {
    Write-Verbose "DotForge: broot: $($_.Exception.Message)"
    $_ok = $false
}
if ($_ok) {
    Add-DFToolSetupNote -Name 'broot' -Text "DotForge provides br (it moves the shell to the folder you leave broot in); broot's own br isn't installed."
} else {
    Add-DFToolSetupNote -Name 'broot' -Text "couldn't turn off broot's own br installer; run 'broot --set-install-state installed' before using broot, or it will offer to edit your shell profiles."
}
Complete-DFToolSetup -Name 'broot' -Actions @(@{ type = 'brootInstallState'; ok = $_ok })
