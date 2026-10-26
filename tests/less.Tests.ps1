BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:LessJson = Get-Content "$PSScriptRoot/../Tools/less.json" -Raw | ConvertFrom-Json
}

# less's flags live in the lesskey file LESSKEYIN names, not in LESS
# (docs/superpowers/specs/2026-10-26-config-files-design.md).
Describe 'Tools/less.json' {
    It 'does not set LESS' {
        $block = $script:LessJson.PSObject.Properties['env']?.Value
        @(${block}?.PSObject.Properties.Name) | Should -Not -Contain 'LESS'
    }
    It 'seeds the lesskey LESSKEYIN names, with the flags in #env' {
        $script:LessJson.xdg.vars.LESSKEYIN | Should -Be '${XDG_CONFIG_HOME}/less/lesskey'
        $script:LessJson.setup.seed.'${XDG_CONFIG_HOME}/less/lesskey' | Should -Be 'less/lesskey'
        $text = Get-Content "$PSScriptRoot/../Tools/less/lesskey" -Raw
        $text | Should -Match '(?m)^#env\r?$'
        $text | Should -Match '(?m)^LESS = --RAW-CONTROL-CHARS --quit-if-one-screen --no-init\r?$'
    }
    It 'tells a user whose own lesskey is kept how to keep the options' {
        $note = @($script:LessJson.setup.notes) | Where-Object { $_.ifFile -eq '${XDG_CONFIG_HOME}/less/lesskey' }
        $note | Should -Not -BeNullOrEmpty
        $note.text | Should -Match '#env'
        $note.text | Should -Match 'LESS = --RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
    }
}
