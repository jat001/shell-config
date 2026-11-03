[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
Push-Location $repository
try {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is required for ansible-lint.'
    }

    $linuxRepository = (& wsl.exe wslpath -a -u ($repository -replace '\\', '/') | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $linuxRepository) {
        throw 'Could not resolve the repository path inside WSL.'
    }

    & wsl.exe -e bash -c 'command -v ansible-lint >/dev/null 2>&1'
    if ($LASTEXITCODE -ne 0) {
        throw 'ansible-lint is missing in the default WSL distribution. Run scripts/setup-dev.ps1.'
    }

    & wsl.exe -e bash -c "cd '$linuxRepository/ansible' && ansible-lint site.yml ../tests/prepare.yml ../tests/verify.yml"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
