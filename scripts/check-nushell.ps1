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
        $Path = @(& git ls-files '*.nu')
    }

    if (-not (Get-Command nu -ErrorAction SilentlyContinue)) {
        throw 'Nushell is missing. Run scripts/setup-dev.ps1 first.'
    }

    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $nuPath = $resolved -replace '\\', '/'
        $output = & nu --ide-check 100 $nuPath 2>&1
        $diagnostics = @($output | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { Write-Verbose 'Skipping non-JSON output.' }
            })
        $errors = @($diagnostics | Where-Object {
                $_.severity -eq 'Error' -and $_.message -notlike 'File not found*'
            })
        foreach ($diagnostic in $errors) {
            '{0}: {1}' -f $file, $diagnostic.message
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
