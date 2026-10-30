[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Url,
    [string]$Destination,
    [string]$Entry,
    [string]$Cache,
    [string]$Downloader,
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
# The downloader is a script file. A Restricted policy, as on Windows Sandbox, blocks it.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$ProgressPreference = 'SilentlyContinue'
$Ansible.Changed = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$marker = Join-Path $Destination '.shell-release'
$installed = [IO.File]::Exists((Join-Path $Destination $Entry))

# No marker means this tree was not installed here. update does not take it over, and a non-update run leaves it alone.
if ($installed -and ($Mode -ne 'update' -or -not [IO.File]::Exists($marker))) { return }
if (-not $installed -and [IO.Directory]::Exists($Destination) -and
    [IO.Directory]::GetFileSystemEntries($Destination).Length) {
    throw "Existing directory is not empty: $Destination"
}

$head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url
$release = @($head.Headers['ETag'])[0]
if (-not $release) { $release = @($head.Headers['Last-Modified'])[0] }
if ($installed -and [IO.File]::Exists($marker) -and
    [IO.File]::ReadAllText($marker).Trim() -eq $release) {
    return
}

if ($Ansible.CheckMode) {
    $Ansible.Changed = $true
    return
}

$work = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName())
$null = [IO.Directory]::CreateDirectory($work)
try {
    $archive = & $Downloader -Url $Url -Cache $Cache
    $global:LASTEXITCODE = 0
    & (Join-Path $env:SystemRoot 'System32/tar.exe') -xf $archive -C $work
    if ($LASTEXITCODE -ne 0) { throw "Could not extract $archive" }
    $source = Get-ChildItem -LiteralPath $work -Recurse -Filter $Entry -File |
        Select-Object -First 1
    if (-not $source) { throw "$Entry was not found in $Url" }

    if ([IO.Directory]::Exists($Destination)) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path $Destination))
    Move-Item -LiteralPath $source.DirectoryName -Destination $Destination
    [IO.File]::WriteAllText($marker, $release + [char]10, [Text.UTF8Encoding]::new($false))
    $Ansible.Changed = $true
} finally {
    if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
