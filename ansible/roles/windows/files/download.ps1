param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Cache
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$uri = [uri]$Url
if ($uri.IsFile) {
    $source = Get-Item -LiteralPath $uri.LocalPath
    $validator = "$($source.Length):$($source.LastWriteTimeUtc.Ticks)"
} else {
    $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $uri
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
if (-not [IO.File]::Exists($path)) {
    $partial = $path + '.' + [guid]::NewGuid().ToString('N') + '.part'
    try {
        if ($uri.IsFile) { [IO.File]::Copy($source.FullName,$partial) }
        else { Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $partial }
        [IO.File]::Move($partial,$path)
    } finally { if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) } }
}
$path
