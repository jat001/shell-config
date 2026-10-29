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
    [string]$CacheDirectory,
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
if (-not $CacheDirectory) { $CacheDirectory = Join-Path $StateDirectory 'cache' }
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Get-Wslc {
    $command = Get-Command wslc.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $paths = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join ';'
    foreach ($directory in ($paths -split ';' | Where-Object { $_ })) {
        $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim('"'))
        $candidate = Join-Path $directory 'wslc.exe'
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
}

function Invoke-Wslc {
    param([switch]$AllowFailure)

    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    & $wslc @args 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "wslc $($args[0]) failed ($LASTEXITCODE)." }
}

function Invoke-Wsl {
    param([string]$Distribution, [string[]]$Arguments, [switch]$Root)

    $user = if ($Root) { @('-u', 'root') } else { @() }
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = 'Continue'
    $output = & $wsl -d $Distribution @user --exec @Arguments 2>&1 | ForEach-Object { $_.ToString() }
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

function Test-Wsl {
    if (-not [IO.File]::Exists($wsl)) { return $false }
    # The inbox wsl.exe stub rejects --version; only an installed WSL release accepts it.
    $ErrorActionPreference = 'Continue'
    & $wsl --version 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

function Get-WslRegistration {
    Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath }
}

function Get-CachedDistribution {
    param([string]$Name)

    $downloader = Join-Path $repository 'ansible/roles/windows/files/download.ps1'
    $metadataPath = & $downloader -Cache (Join-Path $CacheDirectory 'wsl/metadata') `
        -Url 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
    $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
    $distribution = $metadata.ModernDistributions.PSObject.Properties |
        ForEach-Object { $_.Value } | Where-Object Name -EQ $Name | Select-Object -First 1
    if (-not $distribution) { return }
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else { $env:PROCESSOR_ARCHITECTURE }
    $field = @{ AMD64='Amd64Url'; ARM64='Arm64Url' }[$nativeArchitecture]
    if (-not $field -or -not $distribution.$field) { return }
    $asset = $distribution.$field
    $expected = $asset.Sha256 -replace '^0x', ''
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid published SHA256 for $Name." }
    $directory = Join-Path $CacheDirectory 'wsl/packages'
    $null = [IO.Directory]::CreateDirectory($directory)
    $name = [IO.Path]::GetFileName(([uri]$asset.Url).AbsolutePath) -replace '[^A-Za-z0-9._-]', '_'
    $path = Join-Path $directory ($expected.Substring(0, 16).ToUpperInvariant() + '-' + $name)
    if (-not [IO.File]::Exists($path)) {
        $partial = $path + '.' + [guid]::NewGuid().ToString('N') + '.part'
        try {
            $nativeDownloader = Join-Path $repository 'ansible/bootstrap/download-wsl.ps1'
            & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $nativeDownloader `
                -Url $asset.Url -Path $partial | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Downloading $Name failed ($LASTEXITCODE)." }
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $expected) {
                throw "The downloaded $Name image does not match the Microsoft distribution index; no package was cached."
            }
            [IO.File]::Move($partial, $path)
        } finally {
            if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
        }
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) {
        throw "The cached $Name image does not match the Microsoft distribution index: $path"
    }
    $path
}

$configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$distributions = @($configuration.environments.wsl.distributions | Where-Object { $_ })

# Ansible runs in a WSL container, so WSL itself is installed before anything else.
if (-not (Test-Wsl)) {
    if (-not $PSCmdlet.ShouldProcess('Windows Subsystem for Linux', 'Install with administrator approval')) {
        Write-Warning 'WSL is not installed; the playbook cannot run until it is.'
        return
    }
    & (Join-Path $repository 'ansible/bootstrap/wsl.ps1') -Cache $CacheDirectory -StateDirectory $StateDirectory
    if (-not (Test-Wsl)) {
        throw 'WSL setup finished; restart Windows, then run the installer again.'
    }
}

$wslc = Get-Wslc
if (-not $wslc) {
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

Invoke-Wslc -AllowFailure image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
    Invoke-Wslc build -t $image -f (Join-Path $context 'Containerfile') $context
} elseif ($Mode -eq 'update' -and -not $PrepareOnly) {
    $previous = @((Invoke-Wslc -AllowFailure image inspect $image | Out-String | ConvertFrom-Json))[0].Id
    Invoke-Wslc build --pull --no-cache -t $image -f (Join-Path $context 'Containerfile') $context
    $current = @((Invoke-Wslc -AllowFailure image inspect $image | Out-String | ConvertFrom-Json))[0].Id
    if ($previous -and $previous -ne $current) { & $wslc rmi $previous *> $null }
}

$null = [IO.Directory]::CreateDirectory($StateDirectory)
[IO.File]::WriteAllText((Join-Path $StateDirectory 'controller-image.txt'), $image + [char]10, $utf8)
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
        if (-not $SkipWsl -and -not $WslDistribution) {
            foreach ($name in $distributions) {
                if ($registered -contains $name) { continue }
                if (-not $PSCmdlet.ShouldProcess($name, 'Install WSL distribution')) { continue }
                $global:LASTEXITCODE = 0
                $package = Get-CachedDistribution $name
                $installArguments = if ($package) {
                    @('--install','--from-file',$package,'--name',$name,'--no-launch')
                } else { @('--install','--distribution',$name,'--no-launch') }
                $preference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $wsl @installArguments 2>&1 | ForEach-Object { $_.ToString() }
                } finally { $ErrorActionPreference = $preference }
                if ($LASTEXITCODE -ne 0) { throw "Installing the WSL distribution $name failed ($LASTEXITCODE)." }
                # The playbook prepares accounts and packages, so the distribution's first-run setup is skipped.
                Get-WslRegistration | Where-Object { $_.DistributionName -eq $name } |
                    ForEach-Object { Set-ItemProperty -LiteralPath $_.PSPath -Name RunOOBE -Value 0 }
                $registered += $name
            }
            if ($distributions -and $registered -contains $distributions[0]) {
                $default = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss').DefaultDistribution
                $current = (Get-WslRegistration | Where-Object { $_.PSChildName -eq $default }).DistributionName
                if ($current -ne $distributions[0] -and
                    $PSCmdlet.ShouldProcess($distributions[0], 'Set the default WSL distribution')) {
                    $global:LASTEXITCODE = 0
                    & $wsl --set-default $distributions[0]
                    if ($LASTEXITCODE -ne 0) { throw "Setting the default WSL distribution failed ($LASTEXITCODE)." }
                }
            }
        }
        if (-not $WslDistribution -and $distributions) {
            $WslDistribution = @($distributions | Where-Object { $registered -contains $_ })
        }
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
            $start = @{
                FilePath = $wsl
                WindowStyle = 'Hidden'
                PassThru = $true
                ArgumentList = @('-d', $distribution, '-u', 'root', '--exec', $sshd,
                    '-D', '-e', '-f', '/etc/shell-ansible/sshd_config')
            }
            if ((Get-Command Start-Process).Parameters.ContainsKey('WhatIf')) { $start.WhatIf = $false }
            $process = Start-Process @start
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
    if ($PSBoundParameters.ContainsKey('CacheDirectory')) { $variables.shell_download_cache = $CacheDirectory }
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

    Invoke-Wslc @arguments
    $code = $LASTEXITCODE
} finally {
    foreach ($server in $servers) {
        try {
            $sshdPid = Invoke-Wsl $server.Distribution @('cat', '/etc/shell-ansible/sshd.pid') -Root
            if ($sshdPid -match '^[0-9]+$') {
                $null = Invoke-Wsl $server.Distribution @('sh', '-c', 'kill $1', 'stop-sshd', $sshdPid) -Root
            }
        } catch { Write-Verbose $_.Exception.Message }
        # wsl.exe usually exits by itself once sshd is gone, possibly between the check and the stop.
        if (-not $server.Process.HasExited) {
            Stop-Process -Id $server.Process.Id -Force -WhatIf:$false -ErrorAction SilentlyContinue
        }
    }
}

$global:LASTEXITCODE = $code
if ($code -ne 0) { throw "ansible-playbook failed ($code)." }
