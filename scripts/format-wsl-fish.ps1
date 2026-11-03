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
        $Path = @(& git ls-files '*.fish')
    }
    if ($Path.Count -eq 0) {
        return
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is required for fish formatting.'
    }
    & wsl.exe -e fish_indent --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'fish_indent is missing in the default WSL distribution.'
    }

    $linuxPaths = @(foreach ($file in $Path) {
            $resolved = (Resolve-Path -LiteralPath $file).Path
            $linuxPath = (& wsl.exe wslpath -a -u ($resolved -replace '\\', '/') | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $linuxPath) {
                throw 'Could not resolve the repository path inside WSL.'
            }
            $linuxPath
        })
    & wsl.exe -e fish_indent -w @linuxPaths
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
