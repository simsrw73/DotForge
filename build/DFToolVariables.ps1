#Requires -Version 7.2
# The environment variables DotForge's tools set: a developer's shell that ran DotForge has them,
# so build/Test-DFFull.ps1 clears them for the run and a test can't pass on inherited values.

function Get-DFToolVariableName {
    <#
    .SYNOPSIS
        Every variable a tool record, a role or a companion sets, never XDG_*, Path or DF_TEST_*.
    .DESCRIPTION
        Records: env, xdg.vars, theme.env and each role block's env. roles.json:
        each role's fallback env and behaviors env. Companions (Tools/*.ps1): a
        literal -Name '<var>' passed to Set-DFEnv or its captured $_setEnv, and
        $Env:<var> = assignments.
    .PARAMETER ToolsPath
        The Tools folder.
    .PARAMETER RolesPath
        data/roles.json.
    .OUTPUTS
        System.String[], sorted, without duplicates.
    #>
    param([Parameter(Mandatory)][string]$ToolsPath, [Parameter(Mandatory)][string]$RolesPath)
    $keys = { param($block) if ($block -is [pscustomobject]) { $block.PSObject.Properties.Name } }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem $ToolsPath -Filter '*.json') {
        $record = Get-Content $file.FullName -Raw | ConvertFrom-Json
        foreach ($block in $record.PSObject.Properties['env']?.Value, $record.PSObject.Properties['xdg']?.Value?.vars,
                $record.PSObject.Properties['theme']?.Value?.env) {
            foreach ($name in @(& $keys $block)) { $names.Add($name) }
        }
        $roles = $record.PSObject.Properties['roles']?.Value
        if ($roles -is [pscustomobject]) {
            foreach ($role in $roles.PSObject.Properties) { foreach ($name in @(& $keys $role.Value.PSObject.Properties['env']?.Value)) { $names.Add($name) } }
        }
    }
    $roleDb = Get-Content $RolesPath -Raw | ConvertFrom-Json
    foreach ($role in $roleDb.PSObject.Properties) {
        if ($role.Value -isnot [pscustomobject]) { continue }
        foreach ($block in $role.Value.PSObject.Properties['fallback']?.Value?.env, $role.Value.PSObject.Properties['behaviors']?.Value?.env) {
            foreach ($name in @(& $keys $block)) { $names.Add($name) }
        }
    }
    foreach ($file in Get-ChildItem $ToolsPath -Filter '*.ps1') {
        $text = Get-Content $file.FullName -Raw
        foreach ($match in [regex]::Matches($text, '(?:Set-DFEnv|\$_setEnv)\s+-Name\s+[''"](\w+)[''"]')) { $names.Add($match.Groups[1].Value) }
        foreach ($match in [regex]::Matches($text, '(?m)^\s*\$Env:(\w+)\s*=(?!=)')) { $names.Add($match.Groups[1].Value) }
    }
    [string[]]@($names | Where-Object { $_ -and $_ -notlike 'XDG_*' -and $_ -ne 'Path' -and $_ -notlike 'DF_TEST_*' } | Sort-Object -Unique)
}
