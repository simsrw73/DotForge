BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.Utility.ps1"

    # Canonical lower/upper-case v4 patterns: 8-4-4-4-12 hex, version nibble '4',
    # variant nibble in [89ab]. Anchored so length and shape are both enforced.
    $script:V4Lower = '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    $script:V4Upper = '^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$'
}

Describe 'New-DFUuid' {
    Context 'default format' {
        It 'is a lowercase, hyphenated, unbraced v4 UUID' {
            New-DFUuid | Should -Match $script:V4Lower
        }

        It 'generates a different value on each call' {
            (New-DFUuid) | Should -Not -Be (New-DFUuid)
        }

        It 'returns a single string' {
            $r = New-DFUuid
            $r | Should -BeOfType ([string])
            @($r).Count | Should -Be 1
        }
    }

    Context 'formatting switches' {
        It '-UpperCase emits upper-case hex' {
            New-DFUuid -UpperCase | Should -Match $script:V4Upper
        }

        It '-NoHyphens yields 32 contiguous lowercase hex digits' {
            New-DFUuid -NoHyphens | Should -Match '^[0-9a-f]{32}$'
        }

        It '-Braces wraps the canonical form in curly braces' {
            $r = New-DFUuid -Braces
            $r | Should -Match '^\{[0-9a-f-]+\}$'
            $r.TrimStart('{').TrimEnd('}') | Should -Match $script:V4Lower
        }
    }

    Context 'composed switches' {
        It '-UpperCase -Braces produces the registry/COM form' {
            New-DFUuid -UpperCase -Braces | Should -Match '^\{[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\}$'
        }

        It '-NoHyphens -Braces yields 32 hex digits inside braces' {
            New-DFUuid -NoHyphens -Braces | Should -Match '^\{[0-9a-f]{32}\}$'
        }

        It '-UpperCase -NoHyphens yields 32 upper-case hex digits' {
            New-DFUuid -UpperCase -NoHyphens | Should -Match '^[0-9A-F]{32}$'
        }
    }

    Context 'Sdk preset' {
        It 'matches the Windows SDK default (lowercase, hyphens, no braces)' {
            New-DFUuid -Sdk | Should -Match $script:V4Lower
        }

        It 'is byte-for-byte the same shape as the unparameterized default' {
            # Both produce the canonical 'D' form; compare structure, not the random value.
            (New-DFUuid -Sdk) -replace '[0-9a-f]', 'x' |
                Should -Be ((New-DFUuid) -replace '[0-9a-f]', 'x')
        }

        It 'cannot be combined with a formatting switch' {
            # Separate parameter set: PowerShell refuses to resolve the call.
            { New-DFUuid -Sdk -UpperCase } | Should -Throw
        }
    }

    Context 'uuidgen alias' {
        It 'exists and resolves to New-DFUuid' {
            $alias = Get-Alias uuidgen -ErrorAction Ignore
            $alias | Should -Not -BeNullOrEmpty
            $alias.ResolvedCommandName | Should -Be 'New-DFUuid'
        }

        It 'produces Unix-style output through the alias' {
            uuidgen | Should -Match $script:V4Lower
        }
    }
}
