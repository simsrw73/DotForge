# Companion for jq — the fjq picker, a live jq playground in fzf.
#
# Defines: Select-JsonPath (alias fjq).

function global:Select-JsonPath {
    <#
    .SYNOPSIS
        A live jq playground: type a filter in fzf, watch its output, and press Enter to run it.
    .DESCRIPTION
        Opens fzf on a JSON file with the query box as the jq filter (starting
        at '.'). The preview shows jq's output for the filter as you type it;
        Enter runs the filter on the file and writes jq's output to the
        pipeline. Esc runs nothing.

        Without -Path, first picks a *.json file below the current folder
        (with fd when it is installed, else Get-ChildItem).

        A filter that contains double quotes may not preview correctly, but
        Enter passes it to jq unchanged.

        Defined by DotForge's jq companion. Requires fzf (or $Env:Picker).
    .PARAMETER Path
        The JSON file. When omitted, you pick one.
    .EXAMPLE
        fjq package.json

        Opens the playground on package.json; type .dependencies and press Enter to print them.
    .EXAMPLE
        $names = fjq data.json

        Captures the output of the filter you settle on.
    .OUTPUTS
        System.String. jq's output for the chosen filter.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][string]$Path)

    if (-not $Path) {
        $list = if (Get-Command fd -ErrorAction Ignore) { { fd --type f --extension json } } else { { Get-ChildItem -Recurse -File -Filter '*.json' -Name } }
        $Path = Invoke-DFPicker -List $list -Preview 'jq -C . {}' -Header 'Select JSON file'
        if (-not $Path) { return }
    }
    $file = (Resolve-Path -LiteralPath $Path -ErrorAction Ignore)?.ProviderPath
    if (-not $file) { Write-Warning "DotForge: no file '$Path'."; return }

    # enter:print-query makes fzf return the filter as typed, not a list item.
    $filter = Invoke-DFPicker -List { 'Type a jq filter; Enter runs it on the file' } -Preview "jq -C {q} ""$file""" `
        -PreviewWindow 'up:85%:wrap' -Header "jq on $(Split-Path $file -Leaf)  [Enter to run the filter, Esc to cancel]" `
        -FzfArgs '--disabled', '--query', '.', '--bind', 'enter:print-query'
    if (-not $filter) { return }
    jq $filter $file
}
Set-Alias -Name fjq -Value Select-JsonPath -Scope Global -Force
