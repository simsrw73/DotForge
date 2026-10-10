BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'tab-completion role declarations' {
    It 'uses the approved single-role definition and the three priorities' {
        $roles = Get-Content "$PSScriptRoot/../data/roles.json" -Raw | ConvertFrom-Json
        $roles.'tab-completion'.kind | Should -Be 'single'
        $roles.'tab-completion'.exclusive | Should -BeFalse
        (Get-Content "$PSScriptRoot/../Tools/PSFzf.json" -Raw | ConvertFrom-Json).roles.'tab-completion'.priority | Should -Be 20
        (Get-Content "$PSScriptRoot/../Tools/carapace.json" -Raw | ConvertFrom-Json).roles.'tab-completion'.priority | Should -Be 10
        $is = Get-Content "$PSScriptRoot/../Tools/inshellisense.json" -Raw | ConvertFrom-Json
        $is.roles.'tab-completion'.optIn | Should -BeTrue
    }

    It 'registers PSFzf after fzf, so fzf''s env block cannot wipe the --ansi PSFzf''s Tab hook adds' {
        # fzf.json sets FZF_DEFAULT_OPTS unconditionally; PSFzf's hook appends --ansi to it.
        (Get-Content "$PSScriptRoot/../Tools/PSFzf.json" -Raw | ConvertFrom-Json).requires | Should -Contain 'fzf'
    }
}

Describe 'core plugin invariant' {
    It 'does not branch on a literal shipped tool name in Private or Public code' {
        $root = Split-Path $PSScriptRoot -Parent
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem (Join-Path $root 'Tools') -Filter '*.json' | ForEach-Object {
            [void]$names.Add((Get-Content $_ -Raw | ConvertFrom-Json).name)
        }
        # Package-manager/catalog branches are deliberately deferred to audit item
        # #8. Keep this list exact: a new literal, even in one of these files,
        # fails below; stale entries also fail.
        $allowlist = @(
            [pscustomobject]@{ File = 'DFCatalog.Base.ps1'; Literal = 'scoop'; Reason = 'Scoop catalog bucket-qualified identity key' }
            [pscustomobject]@{ File = 'Find-DFPackage.ps1'; Literal = 'scoop'; Reason = 'Scoop catalog bucket-qualified query' }
        )
        $occurrences = foreach ($file in Get-ChildItem (Join-Path $root 'Shared'), (Join-Path $root 'Private'), (Join-Path $root 'Public'), (Join-Path $root 'Modules' 'DotForge.Catalog' 'Private'), (Join-Path $root 'Modules' 'DotForge.Catalog' 'Public'), (Join-Path $root 'Modules' 'DotForge.Helpers' 'Private'), (Join-Path $root 'Modules' 'DotForge.Helpers' 'Public') -Filter '*.ps1') {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $nodes = $ast.FindAll({ param($node)
                $isShippedName = {
                    param($candidate)
                    $candidate -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $names.Contains($candidate.Value)
                }
                if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
                    $leftHit = & $isShippedName $node.Left
                    $rightHit = & $isShippedName $node.Right
                    return $node.Operator.ToString() -match '^(?i:[ic]?(eq|ne|like|match|in|contains))$' -and ($leftHit -or $rightHit)
                }
                if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    return $node.Member.Value -match '^(?i:Contains|ContainsKey|Equals|StartsWith)$' -and
                        @($node.Arguments | Where-Object { & $isShippedName $_ }).Count -gt 0
                }
                if ($node -is [System.Management.Automation.Language.SwitchStatementAst]) {
                    foreach ($clause in $node.Clauses) {
                        if (@($clause.Item1.FindAll({ param($part) & $isShippedName $part }, $true)).Count -gt 0) { return $true }
                    }
                }
                $false
            }, $true)
            foreach ($node in $nodes) {
                $literals = if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
                    @($node.Left, $node.Right)
                } elseif ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    @($node.Arguments)
                } else {
                    foreach ($clause in $node.Clauses) { $clause.Item1.FindAll({ param($part) $part -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) }
                }
                foreach ($literal in @($literals | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $names.Contains($_.Value) })) {
                    [pscustomobject]@{ File = $file.Name; Literal = $literal.Value; Text = $node.Extent.Text }
                }
            }
        }
        $unallowed = @($occurrences | Where-Object {
            $occurrence = $_
            -not @($allowlist | Where-Object { $_.File -eq $occurrence.File -and $_.Literal -ieq $occurrence.Literal }).Count
        })
        $stale = @($allowlist | Where-Object {
            $entry = $_
            -not @($occurrences | Where-Object { $_.File -eq $entry.File -and $_.Literal -ieq $entry.Literal }).Count
        })
        @($unallowed | ForEach-Object { "$($_.File):$($_.Literal):$($_.Text)" }) | Should -BeNullOrEmpty -Because 'core code must remain tool-agnostic outside the catalog/package-manager audit allowlist'
        @($stale | ForEach-Object { "$($_.File):$($_.Literal)" }) | Should -BeNullOrEmpty -Because 'every deferred audit allowlist entry must still match real code'
    }
}
