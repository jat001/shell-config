[CmdletBinding()]
param(
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
Push-Location $repository
try {
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        throw 'Scoop is required. Install it from https://scoop.sh first.'
    }

    $packages = @(
        @{ Name = 'jq'; Bucket = 'main' }
        @{ Name = 'lefthook'; Bucket = 'main' }
        @{ Name = 'ruff'; Bucket = 'main' }
        @{ Name = 'shellcheck'; Bucket = 'main' }
        @{ Name = 'shfmt'; Bucket = 'main' }
        @{ Name = 'uv'; Bucket = 'main' }
    )
    foreach ($package in $packages) {
        if (Get-Command $package.Name -ErrorAction SilentlyContinue) {
            continue
        }
        Write-Host "Installing $($package.Bucket)/$($package.Name)"
        scoop install "$($package.Bucket)/$($package.Name)"
    }

    if (-not (Get-Command yamllint -ErrorAction SilentlyContinue)) {
        uv tool install yamllint
        if (-not (Get-Command yamllint -ErrorAction SilentlyContinue)) {
            throw "yamllint was installed but is not on PATH. Add $(uv tool dir --bin) to PATH."
        }
    }

    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Host 'Installing PSScriptAnalyzer'
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is required for ansible-lint.'
    }
    Write-Host 'Installing ansible-lint in the default WSL distribution'
    $linuxRepository = (& wsl.exe wslpath -a -u ($repository -replace '\\', '/') | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $linuxRepository) {
        throw 'Could not resolve the repository path inside WSL.'
    }
    & wsl.exe -e bash "$linuxRepository/scripts/install-wsl-ansible-lint.sh"
    if ($LASTEXITCODE -ne 0) {
        throw 'Installing ansible-lint in WSL failed.'
    }

    Write-Host 'Installing git hooks'
    & lefthook install
    if ($LASTEXITCODE -ne 0) {
        throw 'lefthook install failed.'
    }

    if ($Verify) {
        & lefthook run pre-commit --all-files
        if ($LASTEXITCODE -ne 0) {
            throw 'Checks failed.'
        }
    }

    Write-Host 'Ready. ansible-lint runs in the default WSL distribution and in CI.'
}
finally {
    Pop-Location
}
