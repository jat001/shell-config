function ConvertFrom-WindowsTimeZone {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$MappingPath
    )

    $mapping = [IO.File]::ReadAllText($MappingPath) | ConvertFrom-Json
    $zone = $mapping.zones.PSObject.Properties | Where-Object Name -eq $Id | Select-Object -First 1
    if (-not $zone) {
        throw "Windows time zone '$Id' is not in the CLDR mapping. Update ansible/data/windows_timezones.json."
    }
    $iana = [string]$zone.Value
    if ($iana -notmatch '^(?:[A-Za-z0-9._+-]+/)+[A-Za-z0-9._+-]+$') {
        throw "Invalid IANA time zone '$iana' mapped from '$Id'."
    }
    $iana
}

function ConvertTo-PosixLocale {
    param([Parameter(Mandatory)][string]$Culture)

    # Windows can canonicalize a script-specific name to a two-part culture, so validate the input first.
    if ($Culture -notmatch '^[A-Za-z]{2,3}-[A-Za-z]{2}$') {
        throw "Culture '$Culture' has no unambiguous POSIX locale; use a specific language-region culture."
    }
    $info = [Globalization.CultureInfo]::GetCultureInfo($Culture)
    if ($info.IsNeutralCulture -or $info.Name -notmatch '^[A-Za-z]{2,3}-[A-Za-z]{2}$') {
        throw "Culture '$($info.Name)' has no unambiguous POSIX locale; use a specific language-region culture."
    }
    $parts = $info.Name -split '-'
    $parts[0].ToLowerInvariant() + '_' + $parts[1].ToUpperInvariant() + '.UTF-8'
}

function Get-HostRegionalSetting {
    param([Parameter(Mandatory)][string]$MappingPath)

    $windowsTimeZone = (Get-TimeZone).Id
    $culture = (Get-Culture).Name
    $iana = $null
    $locale = $null
    $lcAll = [Environment]::GetEnvironmentVariable('LC_ALL', 'Process')
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $iana = ConvertFrom-WindowsTimeZone -Id $windowsTimeZone -MappingPath $MappingPath
    } catch { $errors.Add($_.Exception.Message) }
    try {
        $locale = ConvertTo-PosixLocale -Culture $culture
    } catch { $errors.Add($_.Exception.Message) }
    if ([string]::IsNullOrWhiteSpace($lcAll)) {
        $lcAll = $locale
    } elseif ($lcAll -notmatch '^(?:C|C\.UTF-8|POSIX|[A-Za-z]{2,3}_[A-Za-z]{2}\.UTF-8)$') {
        $errors.Add("LC_ALL '$lcAll' is not a supported POSIX locale name.")
        $lcAll = $null
    }
    [ordered]@{
        shell_host_timezone_windows = $windowsTimeZone
        shell_host_timezone_iana = $iana
        shell_host_culture = $culture
        shell_host_locale = $locale
        shell_host_lc_all = $lcAll
        shell_host_regional_errors = @($errors)
    }
}
