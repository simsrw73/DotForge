#Requires -Version 7.2
# Every user-facing function must carry complete comment-based help: the
# module's exported functions, and the global functions each Tools/*.ps1
# companion defines (fco, wins, glow, ...). Sidecars are parsed, never run, so
# this needs none of the tools installed.

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent

    Import-Module (Join-Path $repo 'DotForge.psd1') -Force 3>$null
    $script:exported = @(Get-Command -Module DotForge -CommandType Function |
        Sort-Object Name | ForEach-Object { @{ Name = $_.Name } })

    # Global functions a sidecar defines, with the scriptblock that holds their help.
    $script:sidecarFns = foreach ($file in Get-ChildItem (Join-Path $repo 'Tools') -Filter '*.ps1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            if ($fn.Name -like 'global:*') {
                @{ File = $file.Name; Name = $fn.Name -replace '^global:'; Body = $fn.Body.Extent.Text }
            }
        }
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($cmd.GetCommandName() -ne 'Set-Item') { continue }
            $path = $cmd.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -like 'function:global:*'
            } | Select-Object -First 1
            $sb = $cmd.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true) |
                Select-Object -First 1
            if ($path -and $sb) {
                @{ File = $file.Name; Name = $path.Value -replace '^function:global:'; Body = $sb.ScriptBlock.Extent.Text }
            }
        }
    }
}

BeforeAll {
    # Returns the problems with one help object; empty when the help is complete.
    function Get-HelpGap {
        param($Help, [string[]]$ParameterNames)
        if (-not $Help) { return 'no comment-based help' }
        if (-not $Help.Synopsis)    { 'SYNOPSIS' }
        if (-not $Help.Description) { 'DESCRIPTION' }
        if (-not $Help.Examples)    { 'EXAMPLE' }
        if (-not $Help.Outputs)     { 'OUTPUTS' }
        foreach ($p in $ParameterNames) {
            if (-not $Help.Parameters -or -not $Help.Parameters[$p.ToUpperInvariant()]) { "PARAMETER $p" }
        }
    }

    # Parameters a function declares, minus the common ones CmdletBinding adds.
    function Get-DeclaredParameter {
        param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
        $params = $Ast.ParamBlock?.Parameters
        @($params | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    $script:common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                     [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
}

Describe 'Exported function help' {
    It '<Name> has complete comment-based help' -ForEach $script:exported {
        $cmd = Get-Command $Name
        $help = $cmd.ScriptBlock.Ast.Body.GetHelpContent()
        $params = @($cmd.Parameters.Keys | Where-Object { $_ -notin $script:common })
        @(Get-HelpGap -Help $help -ParameterNames $params) | Should -BeNullOrEmpty
    }

    It '<Name> help examples parse' -ForEach $script:exported {
        $help = (Get-Command $Name).ScriptBlock.Ast.Body.GetHelpContent()
        foreach ($example in @($help.Examples)) {
            # Example text: the code lines come first, then a blank line, then prose.
            $code = ($example -split '\r?\n\s*\r?\n', 2)[0]
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because "example in $Name`:`n$code"
        }
    }
}

Describe 'Sidecar global function help' {
    It '<Name> (<File>) has complete comment-based help' -ForEach $script:sidecarFns {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Body, [ref]$null, [ref]$null)
        # The body is a '{ ... }' scriptblock; its single statement holds the function body.
        $inner = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockAst] -and $n -ne $ast }, $true)
        $target = if ($inner) { $inner } else { $ast }
        $help = $target.GetHelpContent()
        @(Get-HelpGap -Help $help -ParameterNames (Get-DeclaredParameter $target)) | Should -BeNullOrEmpty
    }
}
