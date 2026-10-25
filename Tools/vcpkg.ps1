# Companion for vcpkg — vcpkg.exe lives at the root of its own tree (there is
# no bin/ subfolder, unlike cargo/rustup), so PATH gets $VCPKG_ROOT itself.
# VCPKG_ROOT is whoever installed vcpkg's to set (scoop's env_set, or your own
# clone), never DotForge's; unset, nothing is added.
Add-DFToPath $Env:VCPKG_ROOT

# vcpkg's own completer ships with it as scripts\posh-vcpkg (it asks
# `vcpkg autocomplete` on each Tab); carapace has none. Importing it costs ~45 ms,
# so it loads on the first Tab after `vcpkg`. See docs/external-dependencies.md.
$_poshVcpkg = if ($Env:VCPKG_ROOT) { Join-Path $Env:VCPKG_ROOT 'scripts' 'posh-vcpkg' }
if ($_poshVcpkg -and (Test-Path (Join-Path $_poshVcpkg 'posh-vcpkg.psd1'))) {
    Register-DFLazyCompleter -CommandName vcpkg -Load {
        Import-Module $_poshVcpkg -Global
    }.GetNewClosure()
}
