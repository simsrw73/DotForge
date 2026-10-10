#Requires -Version 7.2

# Aliases for commands in the on-demand modules (DotForge.Catalog, DotForge.Helpers).
# They are defined here, in the startup core, so they exist from the first prompt:
# an alias exported by a module that has not loaded yet loses to a program of the
# same name on PATH (env, which, touch, paste). Calling one resolves its target
# function, which makes PowerShell load that module.

Set-Alias -Name trifle -Value Find-DFPackage
Set-Alias -Name tcats -Value Get-DFCategoryList
Set-Alias -Name ftrifle -Value Select-DFPackage
Set-Alias -Name yank -Value Copy-DFToClipboard
Set-Alias -Name paste -Value Get-DFFromClipboard
Set-Alias -Name path -Value Get-DFPath
Set-Alias -Name fenv -Value Select-DFEnvVar
Set-Alias -Name ep -Value Edit-DFProfile
Set-Alias -Name env -Value Get-DFEnv
Set-Alias -Name reload -Value Invoke-DFProfileReload
Set-Alias -Name touch -Value New-DFFile
Set-Alias -Name which -Value Get-DFWhich
Set-Alias -Name open -Value Open-DFItem
Set-Alias -Name hm -Value Invoke-DFHelp
Set-Alias -Name fcmd -Value Select-DFCommand
Set-Alias -Name fverb -Value Select-DFVerb
Set-Alias -Name fmod -Value Select-DFModule
Set-Alias -Name fh -Value Select-DFHelpTopic
Set-Alias -Name clh -Value Show-DFCliHelp
Set-Alias -Name clhp -Value Show-DFCliHelpPaged
Set-Alias -Name up -Value Set-DFLocationUp
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet
Set-Alias -Name fcd -Value Select-DFLocation
Set-Alias -Name fps -Value Select-DFProcess
Set-Alias -Name top -Value Get-DFTopProcess
Set-Alias -Name uuidgen -Value New-DFUuid
