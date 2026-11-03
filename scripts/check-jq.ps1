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
        $Path = @(& git ls-files '*.jq')
    }

    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        throw 'jq is missing. Run scripts/setup-dev.ps1 first.'
    }

    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        & jq -r --arg platform windows --arg home $HOME --arg mode platform -f $resolved (Join-Path $repository 'common.json') > $null
        if ($LASTEXITCODE -ne 0) {
            '{0}: jq filter error' -f $file
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
