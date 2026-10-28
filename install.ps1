[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('init', 'full', 'update')]
    [string]$Mode = 'full',
    [string]$WindowsHome,
    [string]$Msys2Root,
    [string[]]$WslDistribution,
    [switch]$SkipMsys2,
    [switch]$SkipWsl,
    [switch]$WslDevDriveOnly,
    [string]$Inventory,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'shell-ansible'),
    [string]$Network,
    [string]$Playbook = 'site.yml',
    [string[]]$AnsibleArgument,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Run this installer from Windows PowerShell or PowerShell on Windows.'
}
if ($WslDevDriveOnly -and $SkipWsl) {
    throw '-WslDevDriveOnly cannot be combined with -SkipWsl.'
}

$repository = [IO.Path]::GetFullPath($PSScriptRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Invoke-Wslc {
    $global:LASTEXITCODE = 0
    & wslc.exe @args
    if ($LASTEXITCODE -ne 0) { throw "wslc $($args[0]) failed ($LASTEXITCODE)." }
}

function Invoke-Wsl {
    param([string]$Distribution, [string[]]$Arguments, [switch]$Root)

    $user = if ($Root) { @('-u', 'root') } else { @() }
    $global:LASTEXITCODE = 0
    $output = & $wsl -d $Distribution @user --exec @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed in $Distribution ($LASTEXITCODE): $($Arguments -join ' ')"
    }
    ($output -join [char]10).Replace([string][char]0, '').Trim()
}

function Get-FreePort {
    param([string]$Seed)

    $digest = [Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($Seed.ToLowerInvariant()))
    $port = 22000 + [BitConverter]::ToUInt16($digest, 0) % 1000
    for ($attempt = 0; $attempt -lt 1000; $attempt++) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
        try {
            $listener.Start()
            return $port
        } catch {
            $port = 22000 + (($port - 22000 + 1) % 1000)
        } finally {
            $listener.Stop()
        }
    }
    throw 'No free loopback port is available for the WSL SSH server.'
}

function Wait-Port {
    param([int]$Port)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $client.Connect([Net.IPAddress]::Loopback, $Port)
            return
        } catch {
            Start-Sleep -Milliseconds 500
        } finally {
            $client.Dispose()
        }
    }
    throw "The WSL SSH server did not start on port $Port."
}

if (-not (Get-Command wslc.exe -ErrorAction SilentlyContinue)) {
    throw 'wslc.exe was not found; install a WSL release that provides WSL containers.'
}

$hash = [Security.Cryptography.SHA256]::Create()
$context = Join-Path $repository 'ansible'
$fingerprint = foreach ($file in @('Containerfile', 'requirements.txt', 'requirements.yml')) {
    [BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes((Join-Path $context $file))))
}
$image = 'shell-ansible:' + [BitConverter]::ToString(
    $hash.ComputeHash($utf8.GetBytes($fingerprint -join ''))
).Replace('-', '').Substring(0, 12).ToLowerInvariant()

& wslc.exe image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
    Invoke-Wslc build -t $image -f (Join-Path $context 'Containerfile') $context
} elseif ($Mode -eq 'update' -and -not $PrepareOnly) {
    $previous = @((& wslc.exe image inspect $image | Out-String | ConvertFrom-Json))[0].Id
    Invoke-Wslc build --pull --no-cache -t $image -f (Join-Path $context 'Containerfile') $context
    $current = @((& wslc.exe image inspect $image | Out-String | ConvertFrom-Json))[0].Id
    if ($previous -and $previous -ne $current) { & wslc.exe rmi $previous *> $null }
}

$null = [IO.Directory]::CreateDirectory($StateDirectory)
if (-not [IO.File]::Exists((Join-Path $StateDirectory 'id_ed25519'))) {
    Invoke-Wslc run --rm -v "${StateDirectory}:/state" $image sh -c `
        "ssh-keygen -q -t ed25519 -N '' -C shell-ansible -f /state/id_ed25519"
}
if ($PrepareOnly) { return $image }

$servers = [Collections.Generic.List[object]]::new()

try {
    if (-not $Inventory) {
        if (-not [IO.File]::Exists($wsl)) { throw 'wsl.exe was not found.' }
        $env:WSL_UTF8 = '1'
        $registered = @(& $wsl --list --quiet | ForEach-Object { $_.Replace([string][char]0, '').Trim() } |
            Where-Object { $_ -and $_ -notlike 'docker-desktop*' })
        if (-not $WslDistribution) {
            if ($registered.Count) {
                $WslDistribution = @(& $wsl --exec printenv WSL_DISTRO_NAME)
                if ($LASTEXITCODE -ne 0) { throw 'Could not discover the default WSL distribution.' }
            }
        }
        $WslDistribution = @($WslDistribution | ForEach-Object { $_.Replace([string][char]0, '').Trim() } |
            Where-Object { $_ })
        if (-not $WslDistribution) {
            throw 'A WSL distribution is required; it also carries the Windows connection.'
        }

        $profileHome = if ($WindowsHome) { [IO.Path]::GetFullPath($WindowsHome) } else {
            [Environment]::GetFolderPath('UserProfile')
        }
        $key = [IO.File]::ReadAllText((Join-Path $StateDirectory 'id_ed25519.pub')).Trim()
        $windowsHosts = [ordered]@{}
        $wslHosts = [ordered]@{}

        foreach ($distribution in $WslDistribution) {
            $transport = $windowsHosts.Count -eq 0
            if ($SkipWsl -and -not $transport) { break }

            $source = Invoke-Wsl $distribution @('wslpath', '-a', '-u', $repository)
            $port = Get-FreePort $distribution
            $bootstrap = @('sh', "$source/ansible/bootstrap/wsl.sh", [string]$port, '127.0.0.1', $key)
            if ($transport) {
                $bootstrap += @(
                    (Invoke-Wsl $distribution @('wslpath', '-a', '-u', $windowsPowerShell))
                    (Invoke-Wsl $distribution @('wslpath', '-a', '-u', [Environment]::GetFolderPath('UserProfile')))
                    (@(
                        [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
                        [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
                    ) -ne $null -join ';')
                )
            }
            $sshd = (Invoke-Wsl $distribution $bootstrap -Root) -split "`n" | Select-Object -Last 1
            $process = Start-Process -FilePath $wsl -WindowStyle Hidden -PassThru -WhatIf:$false `
                -ArgumentList @('-d', $distribution, '-u', 'root', '--exec', $sshd,
                    '-D', '-e', '-f', '/etc/shell-ansible/sshd_config')
            $servers.Add(@{ Distribution = $distribution; Process = $process })
            Wait-Port $port

            $connection = [ordered]@{
                ansible_host = 'host.wslc.internal'
                ansible_port = $port
                ansible_user = 'root'
                ansible_ssh_private_key_file = '/root/.ssh/shell-ansible'
            }
            if ($transport) {
                $windows = [ordered]@{}
                foreach ($entry in $connection.GetEnumerator()) { $windows[$entry.Key] = $entry.Value }
                $windows.ansible_shell_type = 'powershell'
                $windowsHosts['windows-host'] = $windows
            }
            if (-not $SkipWsl) {
                # The WSL user takes the Windows user name, lowercased as Linux user names expect.
                $connection.shell_user = (Split-Path -Leaf $profileHome).ToLowerInvariant()
                $connection.shell_windows_home_native = $profileHome
                $wslHosts["wsl-$($distribution -replace '[^A-Za-z0-9_-]', '-')"] = $connection
            }
        }

        $document = @{
            all = @{
                children = [ordered]@{
                    windows = @{ hosts = $windowsHosts }
                    wsl = @{ hosts = $wslHosts }
                }
            }
        }
        $Inventory = Join-Path $StateDirectory 'inventory.json'
        [IO.File]::WriteAllText($Inventory, ($document | ConvertTo-Json -Depth 8), $utf8)
    }

    $variables = @{ shell_mode = $Mode }
    if ($WindowsHome) { $variables.shell_windows_home = [IO.Path]::GetFullPath($WindowsHome) }
    if ($Msys2Root) { $variables.shell_msys2_root = $Msys2Root }
    if ($SkipMsys2) { $variables.shell_msys2 = $false }
    [IO.File]::WriteAllText(
        (Join-Path $StateDirectory 'variables.json'),
        ($variables | ConvertTo-Json -Depth 4),
        $utf8
    )

    $inventoryPath = [IO.Path]::GetFullPath($Inventory)
    if (-not $inventoryPath.StartsWith($StateDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '-Inventory must be inside -StateDirectory.'
    }
    $arguments = @('run', '--rm')
    if ($Network) { $arguments += @('--network', $Network) }
    $arguments += @(
        '-v', "${repository}:/work:ro"
        '-v', "${StateDirectory}:/state"
        '-e', "SHELL_PLAYBOOK=$Playbook"
        '-e', 'ANSIBLE_FORCE_COLOR=1'
        $image, 'sh', '/work/ansible/run.sh', '-e', '@/state/variables.json'
        '-i', ('/state/' + $inventoryPath.Substring($StateDirectory.Length + 1).Replace('\', '/'))
    )
    $passthrough = Get-ChildItem Env: | Where-Object Name -Match '^(ANSIBLE|PROFILE_TASKS)_'
    $environment = foreach ($variable in $passthrough) { '-e'; "$($variable.Name)=$($variable.Value)" }
    $arguments = @($arguments[0..1]) + @($environment) + @($arguments[2..($arguments.Count - 1)])
    if ($WslDevDriveOnly) { $arguments += @('--tags', 'dev_drive') }
    if ($WhatIfPreference) { $arguments += @('--check', '--diff') }
    if ($AnsibleArgument) { $arguments += $AnsibleArgument }

    & wslc.exe @arguments
    $code = $LASTEXITCODE
} finally {
    foreach ($server in $servers) {
        & $wsl -d $server.Distribution -u root --exec sh -c `
            'kill "$(cat /etc/shell-ansible/sshd.pid)" 2>/dev/null' *> $null
        if (-not $server.Process.HasExited) { Stop-Process -Id $server.Process.Id -Force -WhatIf:$false }
    }
}

$global:LASTEXITCODE = $code
if ($code -ne 0) { throw "ansible-playbook failed ($code)." }
