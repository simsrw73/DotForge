#Requires -Version 7.0
# Module files share one script scope when DotForge is imported, so two files
# initializing the same $script: variable at load time silently clobber each
# other (tests that dot-source files one at a time never see it).

Describe 'Module script-scope state' {
    It 'no two module files initialize the same $script: variable at load time' {
        $root = Split-Path $PSScriptRoot -Parent
        $owners = @{}
        foreach ($file in Get-ChildItem (Join-Path $root 'Shared'), (Join-Path $root 'Private'), (Join-Path $root 'Public'), (Join-Path $root 'Modules' 'DotForge.Catalog' 'Private'), (Join-Path $root 'Modules' 'DotForge.Catalog' 'Public'), (Join-Path $root 'Modules' 'DotForge.Helpers' 'Private'), (Join-Path $root 'Modules' 'DotForge.Helpers' 'Public') -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            # Top-level statements only (not inside functions).
            foreach ($stmt in $ast.EndBlock.Statements) {
                $assigns = $stmt.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -like 'script:*' }, $true)
                foreach ($a in $assigns) {
                    $name = $a.Left.VariablePath.UserPath -replace '^script:'
                    if (-not $owners[$name]) { $owners[$name] = [System.Collections.Generic.HashSet[string]]::new() }
                    $null = $owners[$name].Add($file.Name)
                }
            }
        }
        $shared = @($owners.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } |
            ForEach-Object { "$($_.Key): $($_.Value -join ', ')" })
        $shared | Should -BeNullOrEmpty
    }
}
