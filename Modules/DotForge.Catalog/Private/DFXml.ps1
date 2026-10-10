#Requires -Version 7.0

# StrictMode-safe readers for XML nodes (OData feeds: Chocolatey, PowerShell Gallery).

function Get-DFXmlMember {
    <#
    .SYNOPSIS
        Strict-safe read of a member (child element / attribute) on an XML node.
    .DESCRIPTION
        Returns $null when the member is absent, instead of throwing the way a
        bare $node.Member does under Set-StrictMode.

        Absent members are NORMAL in the NuGet v2 / OData feeds these providers
        parse: the schema marks Id/Authors/LastUpdated/Summary with
        m:FC_KeepInContent="false" ("feed customization"), which remaps them onto
        the Atom-standard <title>/<author>/<updated> elements and omits them from
        <m:properties> entirely. Callers must therefore be able to probe for a
        property and fall back — but under strict mode the probe itself is the
        violation, so the probe has to go through here.

        This is deliberately NOT a suppression of strict mode. A genuinely-absent
        feed property returns $null (expected, handled), while a typo'd or
        wrong-cased name also returns $null rather than throwing — the tradeoff
        is contained to feed parsing, where "absent" is data, not a defect.
    .PARAMETER Element
        The XML node to read from. $null yields $null.
    .PARAMETER Name
        The member name.
    .OUTPUTS
        The member's value, or $null when absent.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Element,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Element) { return $null }
    $property = $Element.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function Get-DFXmlText {
    <#
    .SYNOPSIS
        Strict-safe read of an XML member's text value.
    .DESCRIPTION
        Wraps Get-DFXmlMember and normalizes the two shapes PowerShell's XML
        adapter produces: a text-only element surfaces as a [string], while an
        element carrying attributes (e.g. <d:Published m:type="Edm.DateTime">)
        surfaces as an XmlElement holding its value in '#text'.
    .PARAMETER Element
        The XML node to read from. $null yields $null.
    .PARAMETER Name
        The member name.
    .OUTPUTS
        [string] the member's text, or $null when absent/empty.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Element,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $value = Get-DFXmlMember -Element $Element -Name $Name
    if ($null -eq $value) { return $null }
    if ($value -is [string]) { return $value }

    $inner = $value.PSObject.Properties['#text']
    if ($inner) { return [string]$inner.Value }
    return $null
}
