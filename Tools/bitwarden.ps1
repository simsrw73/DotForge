# Companion for the Bitwarden CLI (bw) — the fbw picker, which copies a password.
#
# Defines: Select-BwItem (alias fbw).
# The password goes only to the clipboard: never to the output, the fzf list or a preview.

function global:Select-BwItem {
    <#
    .SYNOPSIS
        Fuzzy-picks a Bitwarden vault item and copies its password, clearing the clipboard after 30 seconds.
    .DESCRIPTION
        Checks bw status first: a vault that is logged out or locked gets the
        command to fix it, and nothing is listed. Otherwise lists the vault's
        items (name and username; no secrets), and Enter copies the chosen
        item's password to the clipboard. After 30 seconds a background
        thread job clears the clipboard, but only if it still holds that
        password, so something you copied since is left alone. An item with
        no password (a secure note, a card) gets a warning.

        Windows clipboard history (Win+V) and clipboard sync may keep their own
        copy of the password; turn them off if that matters to you.

        Defined by DotForge's bitwarden companion. Requires fzf (or $Env:Picker)
        and an unlocked vault (BW_SESSION set, e.g. $Env:BW_SESSION = bw unlock --raw).
    .PARAMETER Type
        List only this kind of item: login, note, card, identity, or all (default).
    .EXAMPLE
        fbw -Type login

        Picks a login and copies its password for 30 seconds.
    .OUTPUTS
        None. The password goes to the clipboard only.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([ValidateSet('login', 'note', 'card', 'identity', 'all')][string]$Type = 'all')

    $status = (bw status 2>$null | ConvertFrom-Json -ErrorAction Ignore)?.status
    switch ($status) {
        'unlocked' { }
        'locked' { Write-Warning 'DotForge: the Bitwarden vault is locked. Unlock it with: $Env:BW_SESSION = bw unlock --raw'; return }
        'unauthenticated' { Write-Warning 'DotForge: not logged in to Bitwarden. Run: bw login'; return }
        default { Write-Warning "DotForge: couldn't read bw status; is the Bitwarden CLI working?"; return }
    }
    # Bitwarden's item types: 1 login, 2 secure note, 3 card, 4 identity.
    $typeId = @{ login = 1; note = 2; card = 3; identity = 4 }[$Type]
    $items = @(bw list items 2>$null | ConvertFrom-Json -ErrorAction Ignore | Where-Object { -not $typeId -or $_.type -eq $typeId })
    $names = @{}
    $lines = foreach ($item in $items) {
        $names[$item.id] = $item.name
        $user = $item.PSObject.Properties['login']?.Value?.username
        "$($item.name)`t$user`t$($item.id)"
    }

    Invoke-DFPicker -List { $lines } -Delimiter "`t" -WithNth '1,2' -Header 'Select vault item  [Enter to copy its password for 30 s]' `
        -Parse { ($_ -split "`t")[2] } -Action {
            param($id)
            $secret = bw get password $id 2>$null
            if (-not $secret) { Write-Warning "DotForge: '$($names[$id])' has no password."; return }
            Set-Clipboard -Value $secret
            Write-Host "Copied the password for '$($names[$id])'; the clipboard clears in 30 s."
            $null = Start-ThreadJob -ArgumentList $secret, 30 -ScriptBlock {
                param($copied, $seconds)
                Start-Sleep -Seconds $seconds
                if ((Get-Clipboard -Raw) -ceq $copied) { Set-Clipboard -Value $null }
            }
        }
}
Set-Alias -Name fbw -Value Select-BwItem -Scope Global -Force
