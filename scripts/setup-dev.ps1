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

    Write-Host 'Ready. ansible-lint runs in CI because Windows is not an Ansible control node.'
}
finally {
    Pop-Location
}
