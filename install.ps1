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
    [string]$WindowsUser = $env:USERNAME,
    [string]$Inventory,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'shell-ansible'),
    [string]$Network,
    [string]$Playbook = 'site.yml',
    [string[]]$AnsibleArgument,
    [switch]$PrepareOnly,
    [Parameter(DontShow)]
    [switch]$BootstrapWinRM
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
$clientCertificate = Join-Path $StateDirectory 'winrm-client.pem'
$serverCertificate = Join-Path $StateDirectory 'winrm-server.pem'
$credentialFile = Join-Path $StateDirectory 'winrm-credential.xml'
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$elevated = ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($BootstrapWinRM) {
    try {
        $bootstrap = @{
            ClientCertificate = $clientCertificate
            ServerCertificate = $serverCertificate
            User = $WindowsUser
        }
        if ([IO.File]::Exists($credentialFile)) { $bootstrap.CredentialFile = $credentialFile }
        & (Join-Path $repository 'ansible/bootstrap/winrm.ps1') @bootstrap
    } catch {
        [IO.File]::WriteAllText((Join-Path $StateDirectory 'winrm-bootstrap.log'), ($_ | Out-String), $utf8)
        exit 1
    }
    return
}

function Invoke-Wslc {
    $global:LASTEXITCODE = 0
    & wslc.exe @args
    if ($LASTEXITCODE -ne 0) { throw "wslc $($args[0]) failed ($LASTEXITCODE)." }
}

function Invoke-Elevated {
    param([string]$Command)

    $process = Start-Process -FilePath $powershell -Verb RunAs -WindowStyle Hidden -PassThru -Wait `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass $Command" -WhatIf:$false
    if ($process.ExitCode -ne 0) { throw "Elevated command failed ($($process.ExitCode)): $Command" }
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
if (-not [IO.File]::Exists($clientCertificate)) {
    if ($WindowsUser -notmatch '^[A-Za-z0-9._-]+$') { throw "Unsupported Windows user name: $WindowsUser" }
    Invoke-Wslc run --rm -v "${StateDirectory}:/state" $image openssl req -x509 -nodes `
        -newkey rsa:2048 -days 3650 -subj "/CN=$WindowsUser" `
        -keyout /state/winrm-client.key -out /state/winrm-client.pem `
        -addext "subjectAltName=otherName:1.3.6.1.4.1.311.20.2.3;UTF8:$WindowsUser@localhost" `
        -addext 'extendedKeyUsage=clientAuth' -addext 'keyUsage=digitalSignature,keyEncipherment'
}
if ($PrepareOnly) { return }

$startedWinRM = $false
$servers = [Collections.Generic.List[object]]::new()

try {
    if (-not $Inventory) {
        $thumbprint = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $clientCertificate
        ).Thumbprint
        $marker = Join-Path $StateDirectory 'winrm-ready'
        $ready = $Mode -ne 'init' -and [IO.File]::Exists($serverCertificate) -and
            [IO.File]::Exists($marker) -and [IO.File]::ReadAllText($marker).Trim() -eq $thumbprint
        $startedWinRM = (Get-Service WinRM).Status -ne 'Running'

        if (-not $ready) {
            $credential = Get-Credential -UserName "$env:COMPUTERNAME\$WindowsUser" `
                -Message 'Windows password for mapping the Ansible WinRM certificate'
            if (-not $credential) { throw 'A Windows credential is required for the WinRM bootstrap.' }
            $credential | Export-Clixml -LiteralPath $credentialFile -WhatIf:$false
            try {
                $command = '-File "{0}" -BootstrapWinRM -StateDirectory "{1}" -WindowsUser "{2}"' -f
                    $PSCommandPath, $StateDirectory, $WindowsUser
                if ($elevated) {
                    & $powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
                        -BootstrapWinRM -StateDirectory $StateDirectory -WindowsUser $WindowsUser
                    if ($LASTEXITCODE -ne 0) { throw 'WinRM bootstrap failed.' }
                } else {
                    Invoke-Elevated $command
                }
            } catch {
                $log = Join-Path $StateDirectory 'winrm-bootstrap.log'
                if ([IO.File]::Exists($log)) { throw "$_`n$([IO.File]::ReadAllText($log))" }
                throw
            } finally {
                Remove-Item -LiteralPath $credentialFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
            }
            [IO.File]::WriteAllText($marker, $thumbprint + [char]10, $utf8)
        } elseif ($startedWinRM) {
            if ($elevated) { Start-Service WinRM -WhatIf:$false } else { Invoke-Elevated '-Command Start-Service WinRM' }
        }

        $profileHome = if ($WindowsHome) { [IO.Path]::GetFullPath($WindowsHome) } else {
            [Environment]::GetFolderPath('UserProfile')
        }
        $hosts = [ordered]@{}
        $hosts['windows-host'] = [ordered]@{
            ansible_host = 'host.wslc.internal'
            ansible_port = 5986
            ansible_connection = 'psrp'
            ansible_psrp_protocol = 'https'
            ansible_psrp_auth = 'certificate'
            ansible_psrp_certificate_pem = '/state/winrm-client.pem'
            ansible_psrp_certificate_key_pem = '/state/winrm-client.key'
            ansible_psrp_ca_cert = '/state/winrm-server.pem'
        }
        $wslHosts = [ordered]@{}

        if (-not $SkipWsl -and [IO.File]::Exists($wsl)) {
            $env:WSL_UTF8 = '1'
            if (-not $WslDistribution) {
                $registered = & $wsl --list --quiet
                if ($LASTEXITCODE -eq 0 -and ($registered -join '').Trim()) {
                    $WslDistribution = @(& $wsl --exec printenv WSL_DISTRO_NAME)
                    if ($LASTEXITCODE -ne 0) { throw 'Could not discover the default WSL distribution.' }
                }
            }
            $key = [IO.File]::ReadAllText((Join-Path $StateDirectory 'id_ed25519.pub')).Trim()

            foreach ($distribution in $WslDistribution) {
                $distribution = $distribution.Replace([string][char]0, '').Trim()
                if (-not $distribution) { continue }

                $source = Invoke-Wsl $distribution @('wslpath', '-a', '-u', $repository)
                $user = Invoke-Wsl $distribution @('id', '-un')
                $port = Get-FreePort $distribution
                $sshd = (Invoke-Wsl $distribution @(
                    'sh', "$source/ansible/bootstrap/wsl.sh", [string]$port, '127.0.0.1', $key
                ) -Root) -split "`n" | Select-Object -Last 1
                $process = Start-Process -FilePath $wsl -WindowStyle Hidden -PassThru -WhatIf:$false `
                    -ArgumentList @('-d', $distribution, '-u', 'root', '--exec', $sshd,
                        '-D', '-e', '-f', '/etc/shell-ansible/sshd_config')
                $servers.Add(@{ Distribution = $distribution; Process = $process })
                Wait-Port $port

                $wslHosts["wsl-$($distribution -replace '[^A-Za-z0-9_-]', '-')"] = [ordered]@{
                    ansible_host = 'host.wslc.internal'
                    ansible_port = $port
                    ansible_user = 'root'
                    ansible_ssh_private_key_file = '/root/.ssh/shell-ansible'
                    shell_user = $user
                    shell_windows_home_native = $profileHome
                }
            }
        }

        $document = @{
            all = @{
                children = [ordered]@{
                    windows = @{ hosts = $hosts }
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
    if ($WslDevDriveOnly) { $arguments += @('--tags', 'dev_drive') }
    if ($WhatIfPreference) { $arguments += @('--check', '--diff') }
    if ($AnsibleArgument) { $arguments += $AnsibleArgument }

    & wslc.exe @arguments
    $code = $LASTEXITCODE
} finally {
    foreach ($server in $servers) {
        & $wsl -d $server.Distribution -u root --exec sh -c `
            'kill "$(cat /etc/shell-ansible/sshd.pid)" 2>/dev/null; rm -f /etc/shell-ansible/sshd.pid' *> $null
        if (-not $server.Process.HasExited) { Stop-Process -Id $server.Process.Id -Force -WhatIf:$false }
    }
    if ($startedWinRM) {
        if ($elevated) { Stop-Service WinRM -WhatIf:$false } else { Invoke-Elevated '-Command Stop-Service WinRM' }
    }
}

$global:LASTEXITCODE = $code
if ($code -ne 0) { throw "ansible-playbook failed ($code)." }
