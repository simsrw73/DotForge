BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Session config' {
    AfterEach { Set-DFTestConfig $null }

    Context 'Get-DFConfig' {
        It 'returns -Default before any config is set' {
            Get-DFConfig Theme -Default 'x' | Should -Be 'x'
            Get-DFConfig Theme | Should -BeNullOrEmpty
        }
        It 'returns a configured value, including $false, and -Default for a missing or $null key' {
            Set-DFTestConfig @{ Theme = 'nord'; SkipConflictCheck = $false; Defaults = $null }
            Get-DFConfig Theme | Should -Be 'nord'
            Get-DFConfig SkipConflictCheck -Default $true | Should -BeFalse
            Get-DFConfig Defaults -Default 'd' | Should -Be 'd'
            Get-DFConfig ExcludeTools -Default 'e' | Should -Be 'e'
        }
        It 'never reads a global $DFConfig' {
            $global:DFConfig = @{ Theme = 'from-global' }
            try { Get-DFConfig Theme | Should -BeNullOrEmpty }
            finally { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }
        }
    }

    Context 'Set-DFSessionConfig' {
        It 'stores a copy, so later changes to the caller''s hashtable do not leak in' {
            $cfg = @{ Theme = 'nord' }
            Set-DFSessionConfig -Config $cfg
            $cfg.Theme = 'changed'
            Get-DFConfig Theme | Should -Be 'nord'
        }
        It 'warns about an unknown key, suggesting a known one' {
            Set-DFSessionConfig -Config @{ ExludeTools = @('x') } -WarningVariable w 3>$null
            "$w" | Should -Match "ExludeTools.*ExcludeTools"
        }
        It 'warns about an unknown key with no close match' {
            Set-DFSessionConfig -Config @{ Frobnicate = 1 } -WarningVariable w 3>$null
            "$w" | Should -Match "Frobnicate"
        }
        It 'explains removed keys and what replaced them' {
            Set-DFSessionConfig -Config @{ SkipTools = @('lsd'); CompletionMode = 'Native' } -WarningVariable w 3>$null
            "$w" | Should -Match 'SkipTools.*ExcludeTools'
            "$w" | Should -Match "CompletionMode.*tab-completion"
        }
        It 'accepts every known key without warnings' {
            $cfg = @{}
            foreach ($k in $script:DFConfigKeys.Keys) { $cfg[$k] = $null }
            Set-DFSessionConfig -Config $cfg -WarningVariable w 3>$null
            $w | Should -BeNullOrEmpty
        }
    }

    Context 'known-key list' {
        It 'lists every key the code reads by name (Get-DFConfig and Get-DFConfiguredTheme -ToolKey)' {
            $root = Split-Path $PSScriptRoot -Parent
            $read = foreach ($file in Get-ChildItem (Join-Path $root 'Private'), (Join-Path $root 'Public'), (Join-Path $root 'Tools') -Filter '*.ps1') {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -in 'Get-DFConfig', 'Get-DFConfiguredTheme' }, $true) | ForEach-Object {
                    $els = $_.CommandElements
                    for ($i = 1; $i -lt $els.Count; $i++) {
                        $e = $els[$i]
                        $isKey = ($_.GetCommandName() -eq 'Get-DFConfig' -and $i -eq 1 -and $e -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                                 ($i -gt 1 -and $els[$i - 1] -is [System.Management.Automation.Language.CommandParameterAst] -and
                                  $els[$i - 1].ParameterName -in 'ToolKey', 'Key' -and $e -is [System.Management.Automation.Language.StringConstantExpressionAst])
                        if ($isKey) { $e.Value }
                    }
                }
            }
            $unknown = @($read | Sort-Object -Unique | Where-Object { -not $script:DFConfigKeys.Contains($_) })
            $unknown | Should -BeNullOrEmpty -Because 'add new $DFConfig keys to $script:DFConfigKeys in Private/DFSessionConfig.ps1'
        }
        It 'no code in Private, Public or Tools reads a $DFConfig variable' {
            $root = Split-Path $PSScriptRoot -Parent
            $hits = foreach ($file in Get-ChildItem (Join-Path $root 'Private'), (Join-Path $root 'Public'), (Join-Path $root 'Tools') -Filter '*.ps1') {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $ast.FindAll({ param($n)
                        ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -match '^(global:)?DFConfig$') -or
                        ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Variable' -and $n.Extent.Text -match '\bDFConfig\b')
                    }, $true) | ForEach-Object { "$($file.Name):$($_.Extent.StartLineNumber)" }
            }
            @($hits) | Should -BeNullOrEmpty
        }
    }
}
