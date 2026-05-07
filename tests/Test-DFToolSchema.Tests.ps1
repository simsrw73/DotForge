BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
}

Describe 'Test-DFToolSchema' {
    Context 'valid records' {
        It 'passes a minimal valid tool record' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }

        It 'passes a fully populated valid record' {
            $tool = [PSCustomObject]@{
                name        = 'bat'
                executable  = 'bat.exe'
                description = 'Modern cat'
                tags        = @('viewer')
                packages    = [PSCustomObject]@{ scoop = 'bat' }
                xdg         = [PSCustomObject]@{
                    compliance = 'partial'
                    method     = 'env'
                    vars       = [PSCustomObject]@{ BAT_CONFIG_PATH = '${XDG_CONFIG_HOME}/bat/bat.conf' }
                    dirs       = @()
                }
                completions = [PSCustomObject]@{
                    type  = 'static'
                    flags = @('--theme', '--language')
                }
                aliases = [PSCustomObject]@{}
                picker  = $null
            }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }
    }

    Context 'invalid records' {
        It 'fails when name is missing' {
            $tool = [PSCustomObject]@{ executable = 'tool.exe' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'name' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when executable is missing' {
            $tool = [PSCustomObject]@{ name = 'mytool' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'executable' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when xdg.method is not a valid value' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
                xdg        = [PSCustomObject]@{ method = 'invalid' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'xdg.method' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when completions.type is not a valid value' {
            $tool = [PSCustomObject]@{
                name        = 'mytool'
                executable  = 'mytool.exe'
                completions = [PSCustomObject]@{ type = 'magic' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'completions.type' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when completions.type is dynamic but command is missing' {
            $tool = [PSCustomObject]@{
                name        = 'mytool'
                executable  = 'mytool.exe'
                completions = [PSCustomObject]@{ type = 'dynamic' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'command' } | Should -Not -BeNullOrEmpty
        }
    }
}
