# Companion for rustup — CARGO_HOME/RUSTUP_HOME are relocated under
# $XDG_DATA_HOME by the tool JSON's xdg.vars; cargo/rustc binaries themselves
# live in "$CARGO_HOME/bin", which core's env-var application never touches.
Add-DFToPath (Join-Path $Env:CARGO_HOME 'bin')
