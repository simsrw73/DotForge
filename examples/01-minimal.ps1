#Requires -Version 7.0
# DotForge minimal profile
# ─────────────────────────────────────────────────────────────────────────────
# The simplest possible DotForge setup: import, initialize, register everything.
# Good for: getting started, CI environments, shared machines.

Import-Module DotForge

Initialize-DFEnvironment   # sets XDG dirs, detects package managers
Register-DFTool -All       # configures every installed tool in one call
