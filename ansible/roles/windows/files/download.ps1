param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Cache
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$totalClock = [Diagnostics.Stopwatch]::StartNew()
$headAttempts = 0
$downloadAttempts = 0
$cacheHit = $false
$cacheBytes = $null
$networkBytes = $null
$averageBytesPerSecond = $null
$success = $false
$transferClock = $null
$uri = [uri]$Url
try {
    if ($uri.IsFile) {
        $source = Get-Item -LiteralPath $uri.LocalPath
        $validator = "$($source.Length):$($source.LastWriteTimeUtc.Ticks)"
    } else {
        $head = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $headAttempts++
            try {
                $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $uri
                break
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
        $validator = [string]$head.Headers['ETag'] + [string]$head.Headers['Last-Modified']
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Url`n$validator"))).Replace('-','')
    } finally { $hash.Dispose() }
    $name = [IO.Path]::GetFileName($uri.AbsolutePath) -replace '[^A-Za-z0-9._-]', '_'
    if (-not $name) { $name='download' }
    [void][IO.Directory]::CreateDirectory($Cache)
    $path = Join-Path $Cache ($key.Substring(0,16) + '-' + $name)
    # The cache name includes the validator. A changed ETag or file length is a different object, not an overwrite of a partial download.
    $cacheHit = [IO.File]::Exists($path)
    if (-not $cacheHit) {
        $partial = $path + '.' + [guid]::NewGuid().ToString('N') + '.part'
        try {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $downloadAttempts++
                try {
                    if ($uri.IsFile) { [IO.File]::Copy($source.FullName, $partial) }
                    else {
                        $transferClock = [Diagnostics.Stopwatch]::StartNew()
                        try { Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $partial }
                        finally { $transferClock.Stop() }
                    }
                    break
                } catch {
                    if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
                    if ($attempt -eq 3) { throw }
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
            [IO.File]::Move($partial, $path)
        } finally { if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) } }
    }
    $cacheBytes = (Get-Item -LiteralPath $path).Length
    $networkBytes = if ($cacheHit -or $uri.IsFile) { 0 } else { $cacheBytes }
    if (-not $cacheHit -and -not $uri.IsFile -and $transferClock.Elapsed.TotalSeconds -gt 0) {
        $averageBytesPerSecond = $networkBytes / $transferClock.Elapsed.TotalSeconds
    }
    $success = $true
    $path
} finally {
    $totalClock.Stop()
    try {
        $record = [ordered]@{
            timestamp = [DateTime]::UtcNow.ToString('o')
            tool = 'download.ps1'
            url = $uri.GetLeftPart([UriPartial]::Path)
            success = $success
            cacheHit = $cacheHit
            cacheBytes = $cacheBytes
            networkBytes = $networkBytes
            elapsedSeconds = [math]::Round($totalClock.Elapsed.TotalSeconds, 6)
            headAttempts = $headAttempts
            downloadAttempts = $downloadAttempts
            averageBytesPerSecond = $averageBytesPerSecond
        }
        $directory = Join-Path $Cache 'records'
        [void][IO.Directory]::CreateDirectory($directory)
        $name = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' +
            [guid]::NewGuid().ToString('N') + '.json'
        [IO.File]::WriteAllText((Join-Path $directory $name), ($record | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false))
    } catch {
        # Metrics are diagnostic and must not change the download result.
    }
}
