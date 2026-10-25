BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Record([string]$Name) { ConvertTo-DFToolRecord (Get-Content (Join-Path $PSScriptRoot "../Tools/$Name.json") -Raw | ConvertFrom-Json) }
}

# Where the records point each tool, checked against the real tools on 2026-10-25
# (restore notes, Audit and Summary of gaps).
Describe 'Tool locations' {
    It 'relocates uv tools and uv-installed Pythons, noting the old folders without blocking uv' {
        $uv = Record uv
        $uv.xdg.vars.UV_TOOL_DIR | Should -Be '${XDG_DATA_HOME}/uv/tools'
        $uv.xdg.vars.UV_PYTHON_INSTALL_DIR | Should -Be '${XDG_DATA_HOME}/uv/python'
        foreach ($var in 'UV_TOOL_DIR', 'UV_PYTHON_INSTALL_DIR') {
            $native = $uv.xdg.native.$var
            $native.block | Should -BeFalse
            $native.move | Should -BeFalse
            $native.paths | Should -Contain ('${APPDATA}/uv/' + ($var -eq 'UV_TOOL_DIR' ? 'tools' : 'python'))
        }
    }
    It "moves npm's cache under XDG_CACHE_HOME" {
        (Record npm).xdg.vars.NPM_CONFIG_CACHE | Should -Be '${XDG_CACHE_HOME}/npm'
    }
    It 'sets nothing for chezmoi, which follows XDG_CONFIG_HOME itself' {
        $chezmoi = Record chezmoi
        $chezmoi.xdg.method | Should -Be 'default'
        @($chezmoi.xdg.vars?.PSObject.Properties | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'leaves VCPKG_ROOT to whoever installed vcpkg' {
        $vcpkg = Record vcpkg
        $vcpkg.xdg.vars.PSObject.Properties['VCPKG_ROOT'] | Should -BeNullOrEmpty
        $vcpkg.xdg.vars.VCPKG_DOWNLOADS | Should -Be '${XDG_CACHE_HOME}/vcpkg/downloads'
    }
}
