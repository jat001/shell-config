param(
    [Parameter(Mandatory)][uri]$Url,
    [Parameter(Mandatory)][string]$Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Web.Http.HttpClient, Windows.Web.Http, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Web.Http.HttpProgress, Windows.Web.Http, ContentType=WindowsRuntime]

$filter = [Windows.Web.Http.Filters.HttpBaseProtocolFilter]::new()
$filter.CacheControl.WriteBehavior = 'NoCache'
$client = [Windows.Web.Http.HttpClient]::new($filter)
$client.DefaultRequestHeaders.Append('Accept', 'application/octet-stream')
$client.DefaultRequestHeaders.Append('User-Agent', 'wsl-install')
$inputStream = $null
$outputStream = $null

try {
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
        $_.GetGenericArguments().Count -eq 2 -and $_.GetParameters().Count -eq 1
    } | Select-Object -First 1
    $operation = $client.GetInputStreamAsync($Url)
    $task = $asTask.MakeGenericMethod(
        [Windows.Storage.Streams.IInputStream], [Windows.Web.Http.HttpProgress]
    ).Invoke($null, @($operation))
    $response = $task.GetAwaiter().GetResult()
    $asStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1
    } | Select-Object -First 1
    $inputStream = $asStream.Invoke($null, @($response))
    $outputStream = [IO.File]::Create($Path)
    $inputStream.CopyTo($outputStream)
} finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    $client.Dispose()
    $filter.Dispose()
}
