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
        'Add-DFToPath',
        'Ensure-DFDir',
        'Invoke-DFPicker',
        'Get-DFCachedCompletion',
        'Get-DFTool',
        'Find-DFTool',
        'Register-DFTool',
        'Initialize-DFEnvironment',
        'Install-DFTool',
        'Update-DFCompletions'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('CLI', 'Tools', 'Profile', 'XDG', 'fzf', 'Configuration', 'Windows')
            LicenseUri   = 'https://github.com/simsrw73/DotForge/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/simsrw73/DotForge'
            ReleaseNotes = 'Initial release: tool registry, Register-DFTool, Install-DFTool, Initialize-DFEnvironment, Update-DFCompletions, 30 tool records.'
        }
    }
}
