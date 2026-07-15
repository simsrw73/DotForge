BeforeAll {
    $script:ToolsDir = "$PSScriptRoot/../Tools"

    # A tool's `picker` field takes one of three shapes, and Register-DFTool
    # (Public/Register-DFTool.ps1) only acts on the third:
    #
    #   null        - no picker
    #   "custom"    - a Tools/<name>.ps1 sidecar builds it
    #   { ... }     - declarative; Register-DFTool builds it
    #
    # Nothing verifies "custom". Register-DFTool's guard is `-is [PSCustomObject]`,
    # so a tool declaring "custom" with no sidecar picker silently does nothing:
    # no error, no warning, no picker. That is how ten tools came to advertise
    # pickers they did not have.
    #
    # Invoke-DFPicker is the marker for "this sidecar builds a picker". It is the
    # module's picker primitive (Invoke-DFFzf is private and mocked in tests), so
    # every real sidecar picker goes through it.
    $script:PickerMarker = 'Invoke-DFPicker'

    $script:Tools = Get-ChildItem $script:ToolsDir -Filter '*.json' | ForEach-Object {
        $json = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $sidecar = Join-Path $script:ToolsDir "$($_.BaseName).ps1"
        $hasSidecar = Test-Path $sidecar -PathType Leaf
        [PSCustomObject]@{
            Name            = $json.name
            File            = $_.Name
            Picker          = $json.PSObject.Properties['picker']?.Value
            SidecarPath     = $sidecar
            HasSidecar      = $hasSidecar
            SidecarHasPicker = $hasSidecar -and
                (Select-String -Path $sidecar -Pattern $script:PickerMarker -Quiet)
        }
    }
}

Describe 'Tools/*.json picker declarations' {
    It 'declares "custom" only when a sidecar actually builds a picker' {
        # Register-DFTool silently ignores a string picker, so an unbacked "custom"
        # is invisible: the tool registers "successfully" and the picker never exists.
        $liars = $script:Tools |
            Where-Object { $_.Picker -is [string] -and $_.Picker -eq 'custom' } |
            Where-Object { -not $_.SidecarHasPicker }

        $detail = ($liars | ForEach-Object {
            "$($_.File) declares picker 'custom' but $(if ($_.HasSidecar) { "Tools/$($_.Name).ps1 never calls $script:PickerMarker" } else { "Tools/$($_.Name).ps1 does not exist" })"
        }) -join "; "

        $liars | Should -BeNullOrEmpty -Because @"
$detail.
Register-DFTool only builds a picker from a declarative object, so "custom" without a
sidecar picker does nothing at all -- silently. Either implement the picker in the
sidecar, convert it to a declarative picker object, or set "picker": null and track the
work in docs/superpowers/specs/2026-07-15-legacy-profile-fold-in-design.md.
"@
    }

    It 'declares "custom" whenever a sidecar builds a picker' {
        # The inverse. A sidecar picker still works when the JSON says null -- the
        # sidecar is dot-sourced regardless -- but the field then under-reports, which
        # is how psreadline's fprl picker went unlisted. Enforcing both directions is
        # what makes the field trustworthy rather than decorative.
        $unlisted = $script:Tools |
            Where-Object { $_.SidecarHasPicker } |
            Where-Object { -not ($_.Picker -is [string] -and $_.Picker -eq 'custom') } |
            Where-Object { -not ($_.Picker -is [PSCustomObject]) }

        $detail = ($unlisted | ForEach-Object {
            "$($_.File) declares picker '$($_.Picker)' but Tools/$($_.Name).ps1 calls $script:PickerMarker"
        }) -join "; "

        $unlisted | Should -BeNullOrEmpty -Because "$detail. Set `"picker`": `"custom`" so the record matches reality."
    }

    It 'uses only a supported picker shape: null, "custom", or an object' {
        foreach ($tool in $script:Tools) {
            $ok = ($null -eq $tool.Picker) -or
                  ($tool.Picker -is [PSCustomObject]) -or
                  ($tool.Picker -is [string] -and $tool.Picker -eq 'custom')
            $ok | Should -BeTrue -Because "$($tool.File) has picker '$($tool.Picker)'; Register-DFTool only understands null, 'custom', or an object"
        }
    }

    It 'gives every declarative picker the fields Register-DFTool needs' {
        # Register-DFTool.ps1 reads alias/function/list off the object; without
        # function it builds nothing, and without list the picker has no input.
        foreach ($tool in ($script:Tools | Where-Object { $_.Picker -is [PSCustomObject] })) {
            $tool.Picker.PSObject.Properties['function']?.Value |
                Should -Not -BeNullOrEmpty -Because "$($tool.File) declares a declarative picker with no 'function'"
            $tool.Picker.PSObject.Properties['list']?.Value |
                Should -Not -BeNullOrEmpty -Because "$($tool.File) declares a declarative picker with no 'list'"
        }
    }
}
