@{
    ModuleVersion     = '0.7.0'
    GUID              = '8c4d2e19-6b7a-4f30-a1c5-2e9f0d3b7a64'
    Author            = 'Randy W. Sims'
    CompanyName       = ''
    Copyright         = '(c) Randy W. Sims. All rights reserved.'
    Description       = 'DotForge general helpers: help and discovery, navigation, files, processes, environment and clipboard. Loaded on first use by DotForge.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    RootModule           = 'DotForge.Helpers.psm1'
    FunctionsToExport = @(
        # General Helpers — Help & Discovery
        'Invoke-DFHelp',
        'Show-DFCliHelp',
        'Show-DFCliHelpPaged',
        'Select-DFCommand',
        'Select-DFVerb',
        'Select-DFModule',
        'Select-DFHelpTopic',
        # General Helpers — Navigation
        'Set-DFLocationUp',
        'New-DFDirectoryAndSet',
        'Select-DFLocation',
        # General Helpers — File System
        'New-DFFile',
        'Get-DFWhich',
        'Open-DFItem',
        # General Helpers — Process
        'Select-DFProcess',
        'Get-DFTopProcess',
        # General Helpers — Environment & Profile
        'Get-DFEnv',
        'Get-DFPath',
        'Select-DFEnvVar',
        'Edit-DFProfile',
        'Invoke-DFProfileReload',
        # General Helpers — Clipboard
        'Copy-DFToClipboard',
        'Get-DFFromClipboard',
        # General Helpers — Utility
        'New-DFUuid'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    # Aliases (env, which, touch, ...) are exported by DotForge, so they win over programs of the same name.
    AliasesToExport   = @()
}
