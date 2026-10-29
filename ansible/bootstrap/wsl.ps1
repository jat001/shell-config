param(
    [string]$Cache,
    [string]$StateDirectory,
    [switch]$DownloadOnly,
    [string]$Package,
    [string]$Log
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Assert-MicrosoftSignature {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "The WSL installer does not have a valid Microsoft signature: $Path"
    }
}

if ($Package) {
    Assert-MicrosoftSignature $Package
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    $restart = $feature.State -eq 'EnablePending'
    if ($feature.State -notin @('Enabled', 'EnablePending')) {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
        $restart = $restart -or $result.RestartNeeded
    }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru `
        -ArgumentList @('/i', ('"' + $Package + '"'), '/qn', '/norestart', '/l*v', ('"' + $Log + '"'))
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "WSL MSI installation failed ($($process.ExitCode)); see $Log"
    }
    if ($restart -or $process.ExitCode -eq 3010) { exit 3010 }
    exit 0
}

if (-not $Cache) { throw 'A WSL runtime cache directory is required.' }
$request = [Net.HttpWebRequest]::Create('https://github.com/microsoft/WSL/releases/latest')
$request.AllowAutoRedirect = $false
$response = $request.GetResponse()
try { $tag = ($response.Headers['Location'] -split '/')[-1] } finally { $response.Close() }
if ($tag -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { throw 'Unexpected WSL release tag.' }
$version = if (($tag -split '\.').Count -eq 3) { "$tag.0" } else { $tag }
$nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
} else { $env:PROCESSOR_ARCHITECTURE }
$architecture = @{ AMD64='x64'; ARM64='arm64' }[$nativeArchitecture]
if (-not $architecture) { throw "Unsupported WSL architecture: $nativeArchitecture" }
$directory = Join-Path $Cache "wsl/runtime/$version"
$null = [IO.Directory]::CreateDirectory($directory)
$name = "wsl.$version.$architecture.msi"
$path = Join-Path $directory $name
if (-not [IO.File]::Exists($path)) {
    $partial = $path + '.' + [guid]::NewGuid().ToString('N') + '.part'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/microsoft/WSL/releases/download/$tag/$name" `
            -OutFile $partial
        Assert-MicrosoftSignature $partial
        [IO.File]::Move($partial, $path)
    } finally {
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
}
Assert-MicrosoftSignature $path
if ($DownloadOnly) { return $path }
if (-not $StateDirectory) { throw 'A WSL installation state directory is required.' }
$null = [IO.Directory]::CreateDirectory($StateDirectory)
$logPath = Join-Path $StateDirectory 'wsl-install.log'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
    '-Package', ('"' + $path + '"'), '-Log', ('"' + $logPath + '"')
)
$start = @{
    FilePath = $windowsPowerShell
    ArgumentList = $arguments
    Wait = $true
    PassThru = $true
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $start.Verb = 'RunAs'
    $start.WindowStyle = 'Hidden'
} else { $start.NoNewWindow = $true }
$process = Start-Process @start
if ($process.ExitCode -eq 3010) {
    throw 'WSL is installed, but Windows needs a restart. Restart Windows, then run the installer again.'
}
if ($process.ExitCode -ne 0) {
    throw "WSL setup failed ($($process.ExitCode)); see $logPath"
}
