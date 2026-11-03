[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('zsh', 'fish')]
    [string]$Shell,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
Push-Location $repository
try {
    if (-not $Path) {
        $Path = @(& git ls-files "*.$Shell")
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is required for zsh and fish checks.'
    }
    & wsl.exe -e $Shell --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "$Shell is missing in the default WSL distribution."
    }

    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $linuxPath = (& wsl.exe wslpath -a -u ($resolved -replace '\\', '/') | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $linuxPath) {
            throw 'Could not resolve the repository path inside WSL.'
        }
        if ($Shell -eq 'zsh') {
            & wsl.exe -e zsh -n $linuxPath
        }
        else {
            & wsl.exe -e fish --no-execute $linuxPath
        }
        if ($LASTEXITCODE -ne 0) {
            '{0}: {1} syntax error' -f $file, $Shell
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
