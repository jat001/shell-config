param([string]$Repository)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
. (Join-Path $Repository 'ansible/roles/windows/files/host_regional.ps1')
$mappingPath = Join-Path $Repository 'ansible/data/windows_timezones.json'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$Message)
    try { $null = & $Script } catch {
        if ($_.Exception.Message -like "*$Message*") { return }
        throw
    }
    throw "Expected an error containing '$Message'."
}

$mapping = [IO.File]::ReadAllText($mappingPath) | ConvertFrom-Json
if (@($mapping.zones.PSObject.Properties).Count -lt 100) { throw 'The CLDR timezone mapping is incomplete.' }
foreach ($zone in $mapping.zones.PSObject.Properties) {
    if ($zone.Value -match '\s') { throw "Invalid default mapping for $($zone.Name)." }
}
Assert-Equal (ConvertFrom-WindowsTimeZone -Id 'China Standard Time' -MappingPath $mappingPath) 'Asia/Shanghai' 'China mapping failed.'
Assert-Equal (ConvertFrom-WindowsTimeZone -Id 'UTC' -MappingPath $mappingPath) 'Etc/UTC' 'UTC mapping failed.'
Assert-Equal (ConvertTo-PosixLocale -Culture 'zh-CN') 'zh_CN.UTF-8' 'Chinese locale conversion failed.'
Assert-Equal (ConvertTo-PosixLocale -Culture 'EN-us') 'en_US.UTF-8' 'Culture canonicalization failed.'
Assert-Throws { ConvertFrom-WindowsTimeZone -Id 'Missing Standard Time' -MappingPath $mappingPath } 'not in the CLDR mapping'
Assert-Throws { ConvertTo-PosixLocale -Culture 'zh-Hans-CN' } 'no unambiguous POSIX locale'
Assert-Throws { ConvertTo-PosixLocale -Culture 'en' } 'no unambiguous POSIX locale'
Assert-Throws { ConvertTo-PosixLocale -Culture 'en-001' } 'no unambiguous POSIX locale'

function Get-TimeZone { [pscustomobject]@{ Id = 'China Standard Time' } }
function Get-Culture { [pscustomobject]@{ Name = 'zh-CN' } }
$savedLcAll = $env:LC_ALL
$env:LC_ALL = $null
$hostSettings = Get-HostRegionalSetting -MappingPath $mappingPath
Assert-Equal $hostSettings.shell_host_timezone_windows 'China Standard Time' 'Windows timezone was not collected.'
Assert-Equal $hostSettings.shell_host_timezone_iana 'Asia/Shanghai' 'IANA timezone was not collected.'
Assert-Equal $hostSettings.shell_host_culture 'zh-CN' 'Culture was not collected.'
Assert-Equal $hostSettings.shell_host_locale 'zh_CN.UTF-8' 'Locale was not collected.'
Assert-Equal $hostSettings.shell_host_lc_all 'zh_CN.UTF-8' 'Unset LC_ALL did not fall back to the host locale.'
Assert-Equal @($hostSettings.shell_host_regional_errors).Count 0 'Supported host settings returned conversion errors.'

function Get-TimeZone { [pscustomobject]@{ Id = 'Missing Standard Time' } }
function Get-Culture { [pscustomobject]@{ Name = 'zh-Hans-CN' } }
$unsupported = Get-HostRegionalSetting -MappingPath $mappingPath
Assert-Equal @($unsupported.shell_host_regional_errors).Count 2 'Unsupported host settings did not defer both conversion errors.'

function Get-TimeZone { [pscustomobject]@{ Id = 'China Standard Time' } }
function Get-Culture { [pscustomobject]@{ Name = 'zh-CN' } }
$env:LC_ALL = 'en_GB.UTF-8'
$explicit = Get-HostRegionalSetting -MappingPath $mappingPath
Assert-Equal $explicit.shell_host_lc_all 'en_GB.UTF-8' 'Explicit host LC_ALL was not preserved.'
Assert-Equal @($explicit.shell_host_regional_errors).Count 0 'Explicit host LC_ALL returned an error.'
$env:LC_ALL = 'bad value'
$invalid = Get-HostRegionalSetting -MappingPath $mappingPath
Assert-Equal @($invalid.shell_host_regional_errors).Count 1 'Invalid host LC_ALL was not rejected.'
$env:LC_ALL = $savedLcAll

"PowerShell $($PSVersionTable.PSVersion): regional collection and conversion checks passed."
