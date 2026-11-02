$ErrorActionPreference = 'Stop'
$downloader = Join-Path $PSScriptRoot '../ansible/roles/windows/files/download.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-download-metrics-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

try {
    $sourceDirectory = Join-Path $temporary 'source'
    $cache = Join-Path $temporary 'cache'
    $null = [IO.Directory]::CreateDirectory($sourceDirectory)
    $source = Join-Path $sourceDirectory 'payload.bin'
    $payload = $utf8.GetBytes('download-metrics-' * 200)
    [IO.File]::WriteAllBytes($source, $payload)
    $url = ([uri]$source).AbsoluteUri

    $first = & $downloader -Url $url -Cache $cache
    if (@($first).Count -ne 1 -or $first -isnot [string]) { throw 'The first download changed the path-only output.' }
    $stamp = (Get-Item -LiteralPath $first).LastWriteTimeUtc.Ticks
    $second = & $downloader -Url $url -Cache $cache
    if (@($second).Count -ne 1 -or $second -isnot [string] -or $second -ne $first) {
        throw 'The cached download changed the path-only output.'
    }
    if ((Get-Item -LiteralPath $second).LastWriteTimeUtc.Ticks -ne $stamp) { throw 'The cached file was replaced.' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($second)) -cne [Convert]::ToBase64String($payload)) {
        throw 'The downloaded content changed.'
    }

    $records = @(Get-ChildItem -LiteralPath (Join-Path $cache 'records') -Filter '*.json' -File |
            Sort-Object CreationTimeUtc)
    if ($records.Count -ne 2) { throw "Expected two download records, got $($records.Count)." }
    $miss = [IO.File]::ReadAllText($records[0].FullName) | ConvertFrom-Json
    $hit = [IO.File]::ReadAllText($records[1].FullName) | ConvertFrom-Json
    if (-not $miss.success -or $miss.cacheHit -or $miss.cacheBytes -ne $payload.Length -or
        $miss.networkBytes -ne 0 -or $miss.downloadAttempts -ne 1 -or $null -ne $miss.averageBytesPerSecond) {
        throw 'The initial file copy was not recorded as a cache miss.'
    }
    if (-not $hit.success -or -not $hit.cacheHit -or $hit.cacheBytes -ne $payload.Length -or
        $hit.networkBytes -ne 0 -or $hit.downloadAttempts -ne 0 -or $null -ne $hit.averageBytesPerSecond) {
        throw 'The reuse was not recorded as a cache hit.'
    }
    foreach ($record in @($miss, $hit)) {
        if ($record.url -ne ([uri]$source).GetLeftPart([UriPartial]::Path) -or $record.elapsedSeconds -lt 0) {
            throw 'The download record is invalid.'
        }
    }

    $blockedCache = Join-Path $temporary 'blocked-cache'
    $null = [IO.Directory]::CreateDirectory($blockedCache)
    [IO.File]::WriteAllText((Join-Path $blockedCache 'records'), 'not a directory', $utf8)
    $withoutMetrics = & $downloader -Url $url -Cache $blockedCache
    if (-not [IO.File]::Exists($withoutMetrics)) { throw 'A metrics write failure changed the download result.' }

    "PowerShell $($PSVersionTable.PSVersion): download metrics miss, hit and path-only output passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
