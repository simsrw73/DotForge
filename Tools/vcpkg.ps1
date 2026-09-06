# Companion for vcpkg — vcpkg.exe lives at the root of its own tree (there is
# no bin/ subfolder, unlike cargo/rustup), so PATH gets $VCPKG_ROOT itself.
Add-DFToPath $Env:VCPKG_ROOT
