BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:E = [char]27
}

# Pure rendering for the startup banner
# (docs/superpowers/specs/2026-10-11-startup-banner-design.md).
Describe 'Banner rendering' {
    It 'turns a hex color into a 24-bit escape' {
        ConvertTo-DFAnsiColor '#cba6f7' | Should -Be "$($script:E)[38;2;203;166;247m"
    }
    It 'passes numeric ANSI codes through and ignores names it does not know' {
        ConvertTo-DFAnsiColor '35' | Should -Be "$($script:E)[35m"
        ConvertTo-DFAnsiColor 'nonsense' | Should -Be ''
        ConvertTo-DFAnsiColor $null | Should -Be ''
    }
    It 'formats a line with key, separator and value colors' {
        $style = New-DFBannerStyle -KeyColor '#cba6f7' -OutputColor '#cdd6f4' -Separator '  '
        Format-DFBannerLine -Key 'Disk' -Value 'ok' -Style $style |
            Should -Be "$($script:E)[1m$($script:E)[38;2;203;166;247mDisk$($script:E)[0m  $($script:E)[38;2;205;214;244mok$($script:E)[0m"
    }
    It 'uses the alert color for an alert line' {
        $style = New-DFBannerStyle -KeyColor '' -OutputColor ''
        Format-DFBannerLine -Key 'Disk' -Value 'FAIL' -Style $style -Alert |
            Should -Match ([regex]::Escape("$($script:E)[38;2;243;139;168mFAIL"))
    }
    It 'replaces a placeholder line with several lines, in order, keeping the lines around it' {
        $style = New-DFBannerStyle
        $body = 'A  1', 'Disk  @DF:drives@', 'B  2'
        $fills = @{ drives = @(
                [pscustomobject]@{ Key = 'Disk x'; Value = 'ok'; Alert = $false }
                [pscustomobject]@{ Key = 'Disk y'; Value = 'ok'; Alert = $false }) }
        Merge-DFBannerBody -Body $body -Fills $fills -Style $style | Should -Be @('A  1', 'Disk x  ok', 'Disk y  ok', 'B  2')
    }
    It 'takes the key from the placeholder line when the fill has none' {
        $style = New-DFBannerStyle
        $body = "$($script:E)[38;2;1;2;3mPublic IP$($script:E)[0m  $($script:E)[38;2;4;5;6m@DF:publicip@$($script:E)[0m"
        $fills = @{ publicip = @([pscustomobject]@{ Key = $null; Value = '1.2.3.4'; Alert = $false }) }
        Merge-DFBannerBody -Body $body -Fills $fills -Style $style | Should -Be 'Public IP  1.2.3.4'
    }
    It 'removes a placeholder line with no fill' {
        Merge-DFBannerBody -Body 'A', 'X  @DF:none@', 'B' -Fills @{} -Style (New-DFBannerStyle) | Should -Be @('A', 'B')
    }
    It 'writes every line, with no delay when the delay is 0' {
        Mock Start-Sleep { }
        $out = [System.IO.StringWriter]::new()
        $old = [Console]::Out
        [Console]::SetOut($out)
        try { Write-DFBannerLines -Lines 'a', 'b' -DelayMs 0 } finally { [Console]::SetOut($old) }
        $out.ToString() -split "`r?`n" | Where-Object { $_ } | Should -Be @('a', 'b')
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
    It 'falls back to plain ASCII when the console is not UTF-8' {
        $old = [Console]::Out
        $oldEncoding = [Console]::OutputEncoding
        $out = [System.IO.StringWriter]::new()
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)
            [Console]::SetOut($out)
            Write-DFBannerLines -Lines 'NVMe · 99% life · 46°C', 'loading 3 tools…' -DelayMs 0
        } finally { [Console]::SetOut($old); [Console]::OutputEncoding = $oldEncoding }
        $out.ToString() -split "`r?`n" | Where-Object { $_ } | Should -Be @('NVMe - 99% life - 46C', 'loading 3 tools...')
    }
    It 'pauses between lines, not before the first' {
        Mock Start-Sleep { }
        $old = [Console]::Out
        [Console]::SetOut([System.IO.StringWriter]::new())
        try { Write-DFBannerLines -Lines 'a', 'b', 'c' -DelayMs 8 } finally { [Console]::SetOut($old) }
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }
}

Describe 'fastfetch color names' {
    It '<name> is SGR <code>' -ForEach @(
        @{ name = 'magenta'; code = '35' }, @{ name = 'blue'; code = '34' }, @{ name = 'white'; code = '37' },
        @{ name = 'bright_blue'; code = '94' }, @{ name = 'bright_black'; code = '90' }, @{ name = 'default'; code = '39' }
    ) {
        ConvertTo-DFAnsiColor $name | Should -Be "$([char]27)[${code}m"
    }
}
