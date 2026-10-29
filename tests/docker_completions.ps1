param(
    [ValidateSet('Windows', 'WSL', 'MSYS2')][string[]]$Target = @('Windows', 'WSL', 'MSYS2'),
    [string[]]$WslDistribution,
    [string]$Msys2Root
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$windowsHome = [Environment]::GetFolderPath('UserProfile')
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$passed = [Collections.Generic.List[string]]::new()

function Invoke-Probe {
    param([string]$Executable, [string[]]$Arguments, [string]$Name)
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'DOCKER_COMPLETION_OK') {
        throw "Docker completion probe failed: $Name ($LASTEXITCODE)`n$($output -join "`n")"
    }
    if (($output -join "`n") -match 'Completion ended with directive:') {
        throw "Docker completion wrote diagnostic output: $Name"
    }
    $passed.Add($Name)
    "$Name passed."
}

$bash = @'
set -e
if ! complete -p docker >/dev/null 2>&1; then
    load_status=0
    _completion_loader docker || load_status=$?
    [[ $load_status == 0 || $load_status == 124 ]]
fi
definition=$(complete -p docker)
completion=${definition##* -F }
completion=${completion%% *}
compopt() { :; }
COMP_TYPE=9
COMP_WORDS=(docker ru)
COMP_CWORD=1
COMP_LINE='docker ru'
COMP_POINT=${#COMP_LINE}
"$completion" docker ru docker || :
printf '%s\n' "${COMPREPLY[@]}" | grep -qx run
COMP_WORDS=(docker context use de)
COMP_CWORD=3
COMP_LINE='docker context use de'
COMP_POINT=${#COMP_LINE}
"$completion" docker de use || :
printf '%s\n' "${COMPREPLY[@]}" | grep -Eq '^default([[:space:]]|$)'
printf '%s\n' DOCKER_COMPLETION_OK
'@
$zsh = @'
set -e
[[ ${_comps[docker]-} == _docker ]]
if [[ "$functions[_docker]" == *'autoload -X'* ]]; then
    autoload -Uz +X _docker
fi
[[ "$(docker __complete ru 2>/dev/null)" == run$'\t'* ]]
if [[ "$(uname -s)" != Linux ]]; then
    print -r -- DOCKER_COMPLETION_OK
    exit 0
fi
mkdir -p "$HOME/.cache"
probe_tmp=$(mktemp -d "$HOME/.cache/shell-docker.XXXXXXXX")
TRAPEXIT() {
    [[ "$probe_tmp" == "$HOME/.cache"/shell-docker.* && -d "$probe_tmp" ]] && rm -rf -- "$probe_tmp"
}
XDG_CACHE_HOME="$probe_tmp/cache"
fpath=("$probe_tmp" $fpath)
ln -s "$probe_tmp/target" "$probe_tmp/_shell_completion_fixture"
_shell_init_completion || exit 1
[[ -z ${_comps[shell-fixture]-} ]]
printf '%s\n' '#compdef shell-fixture' > "$probe_tmp/target"
_shell_init_completion || exit 1
[[ ${_comps[shell-fixture]-} == _shell_completion_fixture ]]
print -r -- DOCKER_COMPLETION_OK
'@
$fish = @'
complete -C 'docker ru' | string match -qr '^run(\t|$)'; or exit 1
complete -C 'docker context use de' | string match -qr '^default(\t|$)'; or exit 1
printf '%s\n' DOCKER_COMPLETION_OK
'@
$powershell = @'
$ErrorActionPreference = 'Stop'
foreach ($case in @(@('docker ru', 'run'), @('docker context use de', 'default'), @('docker --con', '--context'))) {
    $matches = [Management.Automation.CommandCompletion]::CompleteInput($case[0], $case[0].Length, $null)
    if ($matches.CompletionMatches.CompletionText -notcontains $case[1]) { throw "No $($case[1]) completion for $($case[0])." }
}
'DOCKER_COMPLETION_OK'
'@
$nu = @'
use std/assert
assert ('run' in ('docker ru' | commandline complete --detailed | get value))
assert ('default' in ('docker context use de' | commandline complete --detailed | get value))
assert ('--context' in ('docker --con' | commandline complete --detailed | get value))
assert ('--context=default' in ('docker --context=de' | commandline complete --detailed | get value))
print DOCKER_COMPLETION_OK
'@

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-docker-test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
try {
    $sources = @{ 'probe.bash'=$bash; 'probe.zsh'=$zsh; 'probe.fish'=$fish; 'probe.ps1'=$powershell; 'probe.nu'=$nu }
    foreach ($name in $sources.Keys) {
        [IO.File]::WriteAllText((Join-Path $temporary $name), $sources[$name], [Text.UTF8Encoding]::new($false))
    }
    if ($Target -contains 'Windows') {
        $scriptPath = Join-Path $temporary 'probe.ps1'
        $arguments = @('-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        Invoke-Probe $windowsPowerShell $arguments 'Windows PowerShell'
        Invoke-Probe (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source `
            $arguments 'Windows PowerShell 7'
        Invoke-Probe (Get-Command nu.exe -CommandType Application | Select-Object -First 1).Source @(
            '--env-config', (Join-Path $windowsHome 'AppData/Roaming/nushell/env.nu'),
            '--config', (Join-Path $windowsHome 'AppData/Roaming/nushell/config.nu'),
            (Join-Path $temporary 'probe.nu')
        ) 'Windows Nushell'
        $scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $windowsHome 'scoop' }
        $dockerScript = Join-Path $scoop 'apps/clink-completions/current/completions/docker.lua'
        if (-not [IO.File]::Exists($dockerScript)) { throw 'Clink Docker completion script is missing.' }
        $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        } else { $env:PROCESSOR_ARCHITECTURE }
        $architecture = @{ AMD64='x64'; ARM64='arm64'; x86='x86' }[$nativeArchitecture]
        if (-not $architecture) { throw "Unsupported Clink architecture: $nativeArchitecture" }
        $info = & (Join-Path $scoop "apps/clink/current/clink_$architecture.exe") info | Out-String
        if ($info -notmatch 'clink-completions') { throw 'Clink completion scripts are not registered.' }
        'Clink provider is installed and registered; interactive Tab verification is separate.'
    }
    if ($Target -contains 'WSL') {
        if (-not $WslDistribution) { $WslDistribution = @($configuration.environments.wsl.distributions) }
        foreach ($distribution in $WslDistribution) {
            $directory = & $wsl -d $distribution -u root --exec wslpath -a -u $temporary
            if ($LASTEXITCODE -ne 0) { throw "The probe path could not be resolved in $distribution." }
            $directory = ($directory -join '').Replace([string][char]0, '').Trim().TrimEnd('/')
            foreach ($shell in @('bash', 'zsh', 'fish')) {
                Invoke-Probe $wsl @('-d', $distribution, '-u', 'root', '--exec', $shell,
                    '-i', "$directory/probe.$shell") "$distribution $shell"
            }
            Invoke-Probe $wsl @('-d', $distribution, '-u', 'root', '--exec', 'pwsh',
                '-NoLogo', '-NonInteractive', '-File', "$directory/probe.ps1") "$distribution PowerShell"
            Invoke-Probe $wsl @('-d', $distribution, '-u', 'root', '--exec', 'nu',
                '--env-config', '/root/.config/nushell/env.nu', '--config', '/root/.config/nushell/config.nu',
                "$directory/probe.nu") "$distribution Nushell"
        }
    }
    if ($Target -contains 'MSYS2') {
        if (-not $Msys2Root) {
            $drive = [Environment]::GetEnvironmentVariable('DEV_DRIVE', 'User')
            $Msys2Root = $configuration.environments.msys2.root.Replace('${DEV_DRIVE}', $drive)
        }
        $savedHome = $env:HOME
        $savedSystem = $env:MSYSTEM
        try {
            $userHome = & (Join-Path $Msys2Root 'usr/bin/getent.exe') passwd $env:USERNAME
            if ($LASTEXITCODE -ne 0 -or -not $userHome) { throw 'The MSYS2 home could not be resolved.' }
            $env:HOME = ($userHome -split ':')[5]
            $env:MSYSTEM = 'MSYS'
            $directory = & (Join-Path $Msys2Root 'usr/bin/cygpath.exe') -u $temporary
            if ($LASTEXITCODE -ne 0) { throw 'The probe path could not be resolved in MSYS2.' }
            $directory = $directory.Trim().TrimEnd('/')
            foreach ($shell in @('bash', 'zsh', 'fish')) {
                Invoke-Probe (Join-Path $Msys2Root "usr/bin/$shell.exe") @('-li', "$directory/probe.$shell") "MSYS2 $shell"
            }
        } finally { $env:HOME=$savedHome; $env:MSYSTEM=$savedSystem }
    }
    "$($passed.Count) Docker completion probes passed."
} finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
