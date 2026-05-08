@{
    ModuleVersion     = '0.1.0'
    GUID              = '160e0d4a-5e2d-4c49-9ec2-562fbdb72b71'
    Author            = 'Randy W. Sims'
    CompanyName       = ''
    Copyright         = '(c) Randy W. Sims. All rights reserved.'
    Description       = 'Framework for registering and configuring CLI tools in a PowerShell profile — XDG paths, PATH management, fzf pickers, and completion caching.'
    PowerShellVersion = '7.0'
    RootModule        = 'DotForge.psm1'
    FunctionsToExport = @(
        # Layer 1 — Core Primitives
        'Add-DFToPath',
        'Ensure-DFDir',
        'Invoke-DFPicker',
        'Get-DFCachedCompletion',
        'Invoke-DFWithPager',
        # Layer 2 — Tool Registry
        'Get-DFTool',
        'Find-DFTool',
        'Register-DFTool',
        # Layer 3 — Tool Operations
        'Initialize-DFEnvironment',
        'Install-DFTool',
        'Update-DFCompletions',
        # General Helpers — Help & Discovery
        'Invoke-DFHelp',
        'Select-DFCommand',
        'Select-DFVerb',
        'Select-DFModule',
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
        'Get-DFPath',
        'Select-DFEnvVar',
        'Edit-DFProfile',
        'Invoke-DFProfileReload',
        # General Helpers — Clipboard
        'Copy-DFToClipboard',
        'Get-DFFromClipboard'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @(
        'pg',
        'hm', 'fcmd', 'fverb', 'fmod',
        'up', 'mkcd', 'fcd',
        'touch', 'which', 'open',
        'fps', 'top',
        'path', 'fenv', 'ep', 'reload',
        'copy', 'paste'
    )
    PrivateData       = @{
        PSData = @{
            Tags         = @('CLI', 'Tools', 'Profile', 'XDG', 'fzf', 'Configuration', 'Windows')
            LicenseUri   = 'https://github.com/simsrw73/DotForge/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/simsrw73/DotForge'
            ReleaseNotes = 'Initial release: tool registry, Register-DFTool, Install-DFTool, Initialize-DFEnvironment, Update-DFCompletions, 30 tool records.'
        }
    }
}
