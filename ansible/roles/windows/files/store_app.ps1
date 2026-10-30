[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Mode,
    [string]$Name,
    [string]$StoreId,
    [string]$Release,
    [string]$Asset,
    [string]$Cache
)

# Installs a Microsoft Store app for the current user. winget's msstore source gives the Store package, which
# the Store then keeps up to date. Without winget, as in Windows Sandbox, the same package family is installed
# from the GitHub release instead.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Ansible.Changed = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-StoreDownload {
    param([string]$Uri, [string]$Destination)

    if ([IO.File]::Exists($Destination)) { return }
    $partial = $Destination + '.part'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
            Move-Item -LiteralPath $partial -Destination $Destination
            return
        } catch {
            if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force }
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Update-WinGetClient {
    $release = 'https://github.com/microsoft/winget-cli/releases'
    $tag = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $request = [Net.HttpWebRequest]::Create("$release/latest")
            $request.AllowAutoRedirect = $false
            $response = $request.GetResponse()
            try { $tag = ($response.Headers['Location'] -split '/')[-1] } finally { $response.Close() }
            break
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    if ($tag -notmatch '^v[0-9.]+$') { throw 'Unexpected WinGet release tag.' }
    $directory = Join-Path $Cache "winget/$tag"
    [void][IO.Directory]::CreateDirectory($directory)
    $assets = @('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle','DesktopAppInstaller_Dependencies.zip')
    foreach ($asset in $assets) {
        $path = Join-Path $directory $asset
        Invoke-StoreDownload -Uri "$release/download/$tag/$asset" -Destination $path
    }
    $work = Join-Path $directory ([guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath (Join-Path $directory $assets[1]) -DestinationPath $work
        $architecture = @{AMD64='x64';ARM64='arm64';x86='x86'}[$env:PROCESSOR_ARCHITECTURE]
        if (-not $architecture) { throw 'Unsupported WinGet architecture.' }
        $dependencies = @(Get-ChildItem -LiteralPath $work -Recurse -File |
            Where-Object { $_.Extension -in @('.appx','.msix') -and $_.FullName -match "[\\/]$architecture[\\/]" } |
            ForEach-Object FullName)
        Add-AppxPackage -Path (Join-Path $directory $assets[0]) -DependencyPath $dependencies -ForceApplicationShutdown
        $Ansible.Changed = $true
    } finally {
        $resolved = [IO.Path]::GetFullPath($work)
        if ($resolved.StartsWith([IO.Path]::GetFullPath($directory)+'\',[StringComparison]::OrdinalIgnoreCase) -and
            [IO.Directory]::Exists($resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

function Get-Installed {
    Get-AppxPackage -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
}

$installed = Get-Installed
$Ansible.Result = @{ version = [string]"$($installed.Version)"; source = '' }
if ($installed -and $Mode -ne 'update') { return }

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
    $Ansible.Result.source = 'msstore'
    if ($Ansible.CheckMode) { $Ansible.Changed = -not $installed; return }
    $action = if ($installed) { 'upgrade' } else { 'install' }
    $executable = $winget.Source
    $output = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $global:LASTEXITCODE = 0
        $output = & $executable $action --id $StoreId --source msstore --exact --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        # -1978335138: this winget client cannot use the current source. Refresh it once, then retry.
        if ($LASTEXITCODE -eq -1978335138 -and $executable -eq $winget.Source) {
            Update-WinGetClient
            $currentWinget = Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
                Sort-Object Version -Descending | Select-Object -First 1
            $executable = Join-Path $currentWinget.InstallLocation 'winget.exe'
            continue
        }
        # 0x8A15002B: no applicable upgrade.
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) { break }
        if ($attempt -eq 3) { throw "winget $action $StoreId failed ($LASTEXITCODE): $output" }
        Start-Sleep -Seconds 10
    }
    $current = Get-Installed
    if (-not $current) { throw "winget reported success, but $Name is not installed: $output" }
    $Ansible.Changed = $Ansible.Changed -or "$($current.Version)" -ne "$($installed.Version)"
    $Ansible.Result.version = [string]$current.Version
    return
}

# The latest-release page redirects to its tag; this avoids the rate-limited API.
# The tag must be v plus three or four numeric parts. A preview tag is not installed over the Store package.
$Ansible.Result.source = 'github'
$tag = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $request = [Net.HttpWebRequest]::Create("$Release/latest")
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        try { $tag = ($response.Headers['Location'] -split '/')[-1] } finally { $response.Close() }
        break
    } catch {
        if ($attempt -eq 3) { throw }
        Start-Sleep -Seconds (5 * $attempt)
    }
}
if ($tag -notmatch '^v(\d+(\.\d+){2,3})$') { throw "Unexpected $Name release: $tag" }
$version = $Matches[1]
if ($installed -and [version]$installed.Version -ge [version]$version) { return }

$Ansible.Changed = $true
$Ansible.Result.version = $version
if ($Ansible.CheckMode) { return }

$file = $Asset.Replace('{version}', $version)
$directory = if ($Cache) { $Cache } else { Join-Path $env:TEMP 'shell-store-apps' }
$null = New-Item -ItemType Directory -Force -Path $directory
$download = Join-Path $directory $file
Invoke-StoreDownload -Uri "$Release/download/$tag/$file" -Destination $download

if ($download -notlike '*.zip') {
    Add-AppxPackage -Path $download -ForceApplicationShutdown
    return
}

# A PreinstallKit archive carries the bundle together with its dependencies.
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$expanded = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('shell-store-app-' + [guid]::NewGuid().ToString('N'))))
if (-not $expanded.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Invalid Store application extraction path.'
}
try {
    Expand-Archive -LiteralPath $download -DestinationPath $expanded
    $bundle = Get-ChildItem -LiteralPath $expanded -Filter '*.msixbundle' | Select-Object -First 1
    if (-not $bundle) { throw "$file contains no msixbundle." }
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else { $env:PROCESSOR_ARCHITECTURE }
    $architecture = @{ AMD64='x64'; ARM64='arm64'; x86='x86' }[$nativeArchitecture]
    if (-not $architecture) { throw "Unsupported Store application architecture: $nativeArchitecture" }
    $dependencies = @(Get-ChildItem -LiteralPath $expanded -Recurse -Include '*.appx', '*.msix' |
        Where-Object { $_.Name -match "_($architecture|neutral)_" } | Select-Object -ExpandProperty FullName)
    Add-AppxPackage -Path $bundle.FullName -DependencyPath $dependencies -ForceApplicationShutdown
} finally {
    if ([IO.Directory]::Exists($expanded)) {
        Remove-Item -Recurse -Force -LiteralPath $expanded
    }
}
