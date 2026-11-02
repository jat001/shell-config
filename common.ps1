$_shared_os = if ($IsWindows -or $PSEdition -eq 'Desktop') {
    'windows'
}
elseif ($IsLinux) {
    'Linux'
}
else {
    ''
}

$_shared_platform = jq -r `
    --arg platform $_shared_os `
    --arg home $HOME `
    --arg mode platform `
    -f "$PSScriptRoot/common.jq" `
    "$PSScriptRoot/common.json"

Remove-Variable '_shared_os'

if (-not $_shared_platform) {
    Remove-Variable '_shared_platform'
    return
}

$OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding =
[System.Text.UTF8Encoding]::new()

# Windows PowerShell drops empty native arguments, so WSL-only values are passed only on WSL.
$_shared_arguments = @()
if ($_shared_platform -eq 'wsl') {
    $_shared_lc_all = $env:LC_ALL
    if (-not $_shared_lc_all) {
        foreach ($path in '/etc/locale.conf', '/etc/default/locale') {
            if (-not [IO.File]::Exists($path)) { continue }
            $assignment = [IO.File]::ReadAllLines($path) |
                Where-Object { $_ -match '^LC_ALL=' } | Select-Object -Last 1
            if ($assignment) {
                $_shared_lc_all = $assignment.Substring(7).Trim().Trim('"').Trim("'")
                if ($_shared_lc_all) { break }
            }
        }
    }
    # The repository is always <Windows home>/.config/shell, whether this path is the link or its target.
    $_shared_arguments = @(
        '--arg', 'windows_home',
        (Split-Path -Parent (Split-Path -Parent (Get-Item -LiteralPath $PSScriptRoot).ResolvedTarget)),
        '--arg', 'mounts', [IO.File]::ReadAllText('/proc/self/mounts'),
        '--arg', 'lc_all', $_shared_lc_all
    )
}

jq -r `
    --arg platform $_shared_platform `
    --arg home $HOME `
    @_shared_arguments `
    --arg mode pwsh `
    -f "$PSScriptRoot/common.jq" `
    "$PSScriptRoot/common.json" |
    Invoke-Expression

Remove-Variable '_shared_arguments', '_shared_lc_all' -ErrorAction SilentlyContinue

if ($_shared_platform -eq 'windows') {
    Set-PSReadLineOption -EditMode Emacs
}

oh-my-posh init pwsh `
    --config "$HOME/.config/oh-my-posh/shell-integration.omp.jsonc" |
    Invoke-Expression

# PowerShell computes PSModulePath at startup, before this profile sets XDG_DATA_HOME.
if ($_shared_platform -ne 'windows' -and $env:XDG_DATA_HOME) {
    $_shared_modules = Join-Path $env:XDG_DATA_HOME 'powershell/Modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $_shared_modules) {
        $env:PSModulePath = $_shared_modules + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Remove-Variable '_shared_modules'
}

Import-Module PSCompletions

# Docker Desktop unmounts its CLI tools when it is not running. WSL keeps the links, so Get-Command still finds
# one, but PowerShell refuses to run the missing target; only running it tells an installed CLI apart.
$_shared_docker = Get-Command docker -ErrorAction SilentlyContinue
if ($_shared_docker -and $IsLinux) {
    $_shared_error_action = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        docker --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $_shared_docker = $null }
    }
    catch {
        $_shared_docker = $null
    }
    finally {
        $ErrorActionPreference = $_shared_error_action
    }
}
Remove-Variable '_shared_error_action' -ErrorAction SilentlyContinue

if ($_shared_docker) {
    # The replacement is a no-op unless it matches the Docker CLI script exactly, which keeps the caller's error policy.
    $_shared_completion = docker completion powershell | Out-String
    $_shared_completion.Replace(
        'Invoke-Expression -OutVariable out "$RequestComp" 2>&1 | Out-Null',
        (
            '$ErrorActionPreference = ''Continue''; ' +
            'Invoke-Expression -OutVariable out ($RequestComp + '' 2>$null'') | Out-Null'
        )
    ) | Invoke-Expression
    Remove-Variable '_shared_completion'
}

Remove-Variable '_shared_docker'

Set-PSReadLineOption -HistorySearchCursorMovesToEnd

Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

if ($_shared_platform -eq 'windows') {
    # Machine entries are moved after the user entries so Scoop shims stay ahead of System32.
    $alias = @(
        'cat', 'cp', 'echo', 'ls', 'mv', 'pwd',
        'rm', 'rmdir', 'sleep', 'sort', 'tee'
    )
    $functions = @('mkdir')

    Remove-Item @(
        $alias | ForEach-Object { "Alias:$_" }
        $functions | ForEach-Object { "Function:$_" }
    ) -Force

    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' |
        Where-Object { $_ }

    $env:Path = @(
        $env:Path -split ';' | Where-Object { $_ -and $_ -notin $machine }
        $machine
    ) -join ';'

    Remove-Variable @('alias', 'functions', 'machine')
}

Remove-Variable '_shared_platform'
