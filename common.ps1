$_shared_os = if ($IsWindows -or $PSEdition -eq 'Desktop') {
    'windows'
} elseif ($IsLinux) {
    'Linux'
} else {
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

$_shared_windows_home = $_shared_mounts = ''
if ($_shared_platform -eq 'wsl') {
    $_shared_windows_home = Split-Path -Parent (Split-Path -Parent (Get-Item -LiteralPath $PSScriptRoot).ResolvedTarget)
    $_shared_mounts = [IO.File]::ReadAllText('/proc/self/mounts')
}

jq -r `
    --arg platform $_shared_platform `
    --arg home $HOME `
    --arg windows_home $_shared_windows_home `
    --arg mounts $_shared_mounts `
    --arg mode pwsh `
    -f "$PSScriptRoot/common.jq" `
    "$PSScriptRoot/common.json" |
    Invoke-Expression

Remove-Variable @('_shared_windows_home', '_shared_mounts')

if ($_shared_platform -eq 'windows') {
    Set-PSReadLineOption -EditMode Emacs
}

oh-my-posh init pwsh `
    --config "$HOME/.config/oh-my-posh/shell-integration.omp.json" |
    Invoke-Expression

Import-Module PSCompletions

Set-PSReadLineOption -HistorySearchCursorMovesToEnd

Set-PSReadlineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadlineKeyHandler -Key DownArrow -Function HistorySearchForward

if ($_shared_platform -eq 'windows') {
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
