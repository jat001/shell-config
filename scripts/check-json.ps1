[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
Push-Location $repository
try {
    if (-not $Path) {
        $Path = @(& git ls-files '*.json' '*.jsonc')
    }

    $utf8 = [Text.UTF8Encoding]::new($false, $true)

    $failed = $false
    foreach ($file in $Path) {
        try {
            $text = $utf8.GetString([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file).Path))
            $options = [System.Text.Json.JsonDocumentOptions]::new()
            if ($file -match '\.jsonc$') {
                $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
                $options.AllowTrailingCommas = $true
            }
            [System.Text.Json.JsonDocument]::Parse($text, $options).Dispose()
        }
        catch {
            '{0}: {1}' -f $file, $_.Exception.Message
            $failed = $true
        }
    }
    if ($failed) {
        exit 1
    }
}
finally {
    Pop-Location
}
