#Requires -Version 7.2

Describe 'Public surface consistency' {
    BeforeAll {
        $script:repo = Split-Path $PSScriptRoot -Parent
        # The core and its on-demand modules: each manifest exports its own Public/ folder.
        $script:psd1Paths = @(
            (Join-Path $script:repo 'DotForge.psd1'),
            (Join-Path $script:repo 'Modules' 'DotForge.Catalog' 'DotForge.Catalog.psd1'),
            (Join-Path $script:repo 'Modules' 'DotForge.Helpers' 'DotForge.Helpers.psd1')
        )
        $script:psd1Path = $script:psd1Paths[0]
        $script:buildScriptPath = Join-Path $script:repo 'build' 'Build-DFReferenceDocs.ps1'

        # Normalizes manifest comment headers to reference doc sections
        function script:ConvertTo-RefSection([string]$ManifestComment) {
            switch -Wildcard ($ManifestComment) {
                'Layer 1*'                             { 'Core' }
                'Layer 2*'                             { 'Core' }
                'Layer 3*'                             { 'Core' }
                'General Helpers — Help & Discovery'   { 'Help and discovery' }
                'General Helpers — Navigation'         { 'Navigation' }
                'General Helpers — File System'        { 'Files' }
                'General Helpers — Process'            { 'Processes' }
                'General Helpers — Environment & Profile' { 'Environment and profile' }
                'General Helpers — Clipboard'          { 'Clipboard, pager and utilities' }
                'General Helpers — Utility'            { 'Clipboard, pager and utilities' }
                'Catalog Info (trifle)'                { 'Package catalog' }
                default                                { throw "Unknown manifest group comment: '$ManifestComment'" }
            }
        }

        # The three manifests' exports, as one surface.
        $script:manifestData = @{
            FunctionsToExport = @(foreach ($p in $script:psd1Paths) { (Import-PowerShellDataFile $p).FunctionsToExport })
            AliasesToExport   = (Import-PowerShellDataFile $script:psd1Path).AliasesToExport
        }

        # Discover functions defined at top level in each module's Public/*.ps1 via PowerShell AST
        $script:publicFiles = @(@(foreach ($p in $script:psd1Paths) { Get-ChildItem -Path (Join-Path (Split-Path $p) 'Public') -Filter '*.ps1' }) | Sort-Object Name)
        $script:publicFunctionMap = [ordered]@{} # FunctionName -> FileBaseName
        $script:topLevelFunctions = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $script:publicFiles) {
            $fTokens = $null
            $fErrors = $null
            $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$fTokens,
                [ref]$fErrors
            )

            $fnAsts = $fileAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Parent -eq $fileAst.EndBlock
            }, $false)

            foreach ($fn in $fnAsts) {
                $script:topLevelFunctions.Add($fn.Name)
                $script:publicFunctionMap[$fn.Name] = $file.BaseName
            }
        }

        # Extract FunctionsToExport comment groups from each manifest's AST & tokens
        $script:manifestFunctionGroups = [ordered]@{}
        foreach ($p in $script:psd1Paths) {
            $tokens = $null
            $errors = $null
            $manifestAst = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
            $manifestHash = $manifestAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | Select-Object -First 1
            $fteEntry = foreach ($kv in $manifestHash.KeyValuePairs) {
                if ($kv.Item1.Extent.Text -eq 'FunctionsToExport') { $kv; break }
            }
            $fteTokens = $tokens | Where-Object {
                $_.Extent.StartOffset -ge $fteEntry.Item2.Extent.StartOffset -and
                $_.Extent.EndOffset -le $fteEntry.Item2.Extent.EndOffset
            }
            $currentGroup = $null
            foreach ($t in $fteTokens) {
                if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
                    $currentGroup = $t.Text.TrimStart('#').Trim()
                } elseif ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::StringLiteral) {
                    $script:manifestFunctionGroups[$t.Value] = $currentGroup
                }
            }
        }

        # Parse sectionByFile from build/Build-DFReferenceDocs.ps1 via AST
        $bTokens = $null
        $bErrors = $null
        $buildAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:buildScriptPath,
            [ref]$bTokens,
            [ref]$bErrors
        )

        $assign = $buildAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -like '*sectionByFile*'
        }, $true) | Select-Object -First 1

        $hashAst = $assign.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.HashtableAst]
        }, $true) | Select-Object -First 1

        $script:sectionByFile = [ordered]@{}
        foreach ($kv in $hashAst.KeyValuePairs) {
            $key = $kv.Item1.Extent.Text.Trim("'`"")
            $val = $kv.Item2.Extent.Text.Trim("'`"")
            $script:sectionByFile[$key] = $val
        }
    }

    Context 'FunctionsToExport parity with Public/*.ps1 (1a)' {
        It 'lists every function defined at top level in Public/*.ps1 in FunctionsToExport' {
            $missingFromManifest = @($script:topLevelFunctions | Where-Object { $_ -notin $script:manifestData.FunctionsToExport })
            $missingFromManifest | Should -BeNullOrEmpty -Because 'every top-level function defined in Public/*.ps1 must be listed in DotForge.psd1 FunctionsToExport'
        }

        It 'defines every FunctionsToExport entry at top level in Public/*.ps1' {
            $missingFromPublic = @($script:manifestData.FunctionsToExport | Where-Object { $_ -notin $script:topLevelFunctions })
            $missingFromPublic | Should -BeNullOrEmpty -Because 'every function listed in DotForge.psd1 FunctionsToExport must be defined at top level in Public/*.ps1'
        }
    }

    Context 'AliasesToExport resolution (1b)' {
        BeforeAll {
            Import-Module (Join-Path $script:repo 'DotForge.psd1') -Force
        }

        AfterAll {
            Remove-Module DotForge -ErrorAction SilentlyContinue
        }

        It 'resolves every alias in AliasesToExport after Import-Module' {
            $unresolved = foreach ($alias in $script:manifestData.AliasesToExport) {
                $cmd = Get-Command -Name $alias -ErrorAction SilentlyContinue
                if (-not $cmd) { $alias }
            }
            $unresolved | Should -BeNullOrEmpty -Because 'every alias in AliasesToExport must resolve to a command after importing DotForge'
        }
    }

    Context 'Reference doc section grouping consistency (1c)' {
        It 'assigns each public function to the same section in the manifest and Build-DFReferenceDocs.ps1' {
            $mismatches = [System.Collections.Generic.List[string]]::new()
            foreach ($fn in $script:manifestData.FunctionsToExport) {
                $file = $script:publicFunctionMap[$fn]
                $docSection = $script:sectionByFile[$file]
                $manifestComment = $script:manifestFunctionGroups[$fn]
                $expectedSection = script:ConvertTo-RefSection $manifestComment

                if ($docSection -ne $expectedSection) {
                    $mismatches.Add("Function '$fn' in '$file': docSection='$docSection' vs expected='$expectedSection' (from '$manifestComment')")
                }
            }
            $mismatches | Should -BeNullOrEmpty -Because 'each public function must land in the same group in both the manifest and Build-DFReferenceDocs.ps1'
        }
    }

    Context 'Build-DFReferenceDocs sectionByFile coverage (1d)' {
        It 'explicitly maps every Public/*.ps1 file in sectionByFile without silent fallback' {
            # Files that define public functions (DFAliases.ps1 only defines aliases).
            $unmapped = foreach ($file in $script:publicFiles | Where-Object { $_.BaseName -in $script:publicFunctionMap.Values }) {
                if (-not $script:sectionByFile.Contains($file.BaseName)) {
                    $file.Name
                }
            }
            $unmapped | Should -BeNullOrEmpty -Because 'every Public/*.ps1 file must be explicitly present in sectionByFile with no silent fallback'
        }
    }
}
