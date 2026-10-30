[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root,
    [string]$Mode,
    [string]$Cache,
    [string]$Bootstrap,
    [string[]]$Buckets,
    [object[]]$Apps
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$scoop = Join-Path $Root 'shims/scoop.ps1'
$env:SCOOP = $Root
if ($Cache) { $env:SCOOP_CACHE = $Cache }
$env:PATH = (Join-Path $Root 'shims') + ';' + $env:PATH

$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Invoke-PowerShell {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File @args 2>&1 |
        Out-String
    if ($LASTEXITCODE -ne 0) { throw "$($args -join ' ') failed ($LASTEXITCODE): $output" }
    $output
}

function Invoke-Scoop {
    Invoke-PowerShell $scoop @args
}

function Read-AppFile {
    param([string]$Name, [string]$File)

    foreach ($candidate in @("scoop-$File.json", "$File.json")) {
        $path = Join-Path $Root "apps/$Name/current/$candidate"
        if ([IO.File]::Exists($path)) { return [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    }
}

function Get-AppVersion {
    param([string]$Name)

    (Read-AppFile $Name 'manifest').version
}

function Get-AppBucket {
    param([string]$Name)

    (Read-AppFile $Name 'install').bucket
}

if ($Ansible.CheckMode) {
    $missing = @($Apps | Where-Object {
        $version = Get-AppVersion $_.name
        if ($version) { return $_.bucket -and (Get-AppBucket $_.name) -ne $_.bucket }
        -not ($_.command -and (Get-Command $_.command -ErrorAction SilentlyContinue))
    })
    $Ansible.Changed = $Mode -ne 'update' -and (
        -not [IO.File]::Exists($scoop) -or
        -not (Get-Command git.exe -ErrorAction SilentlyContinue) -or
        @($Buckets | Where-Object { -not [IO.Directory]::Exists((Join-Path $Root "buckets/$_")) }).Count -or
        $missing.Count
    )
    $Ansible.Result = @{ pending = @($missing | ForEach-Object { $_.name }) }
    return
}

if (-not [IO.File]::Exists($scoop)) {
    # update refuses to bootstrap Scoop. A missing install is an init failure, not an upgrade.
    if ($Mode -eq 'update') { throw "Scoop is not installed at $Root; run the init mode first." }
    $installer = if ($Cache) {
        $null = [IO.Directory]::CreateDirectory($Cache)
        Join-Path $Cache 'scoop-install.ps1'
    } else { Join-Path $env:TEMP 'scoop-install.ps1' }
    if (-not [IO.File]::Exists($installer)) {
        $partial = $installer + '.part'
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri 'https://get.scoop.sh' -OutFile $partial
                Move-Item -LiteralPath $partial -Destination $installer
                break
            } catch {
                if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force }
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
    }
    try {
        $null = Invoke-PowerShell $installer -RunAsAdmin -ScoopDir $Root
    } finally {
        if (-not $Cache) { Remove-Item -LiteralPath $installer -Force }
    }
    if (-not [IO.File]::Exists($scoop)) { throw 'Scoop installation failed.' }
    $Ansible.Changed = $true
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    if ($Mode -eq 'update') { throw 'Git is required to update Scoop buckets.' }
    $null = Invoke-Scoop install $Bootstrap
    $Ansible.Changed = $true
}

foreach ($bucket in $Buckets) {
    if (-not [IO.Directory]::Exists((Join-Path $Root "buckets/$bucket"))) {
        $null = Invoke-Scoop bucket add $bucket
        $Ansible.Changed = $true
    }
}

$installed = [Collections.Generic.List[object]]::new()
$before = @{}

foreach ($app in $Apps) {
    $version = Get-AppVersion $app.name
    if ($version) {
        $bucket = Get-AppBucket $app.name
        if ($app.bucket -and $bucket -ne $app.bucket) {
            $null = Invoke-Scoop uninstall $app.name
            $null = Invoke-Scoop install "$($app.bucket)/$($app.name)"
            $Ansible.Changed = $true
        }
        $installed.Add($app.name)
        $before[$app.name] = Get-AppVersion $app.name
        continue
    }
    if ($app.command -and (Get-Command $app.command -ErrorAction SilentlyContinue)) { continue }
    if ($Mode -eq 'update') { continue }

    $name = if ($app.bucket) { "$($app.bucket)/$($app.name)" } else { $app.name }
    $null = Invoke-Scoop install $name
    $installed.Add($app.name)
    $Ansible.Changed = $true
}

if ($Mode -eq 'update' -and $installed.Count) {
    $null = Invoke-Scoop update
    $null = Invoke-Scoop update @($installed)
    foreach ($name in $installed) {
        if ((Get-AppVersion $name) -ne $before[$name]) { $Ansible.Changed = $true }
    }
}

$Ansible.Result = @{
    apps = @(foreach ($name in $installed) { @{ name = $name; version = Get-AppVersion $name } })
}
