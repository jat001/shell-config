[CmdletBinding()]
param(
    [ValidateSet('arch', 'debian', 'sandbox')]
    [string[]]$Target = @('arch', 'debian', 'sandbox'),
    [ValidateSet('init', 'prepare', 'full', 'idempotence', 'update', 'verify', 'unprivileged')]
    [string[]]$Step = @('init', 'prepare', 'full', 'idempotence', 'update', 'verify', 'unprivileged'),
    [string]$StateDirectory = (Join-Path $env:TEMP 'shell-ansible-test'),
    [switch]$Reuse,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
# Python, git and wslc report progress on stderr. On PowerShell 7 that must not fail the run.
$PSNativeCommandUseErrorActionPreference = $false
$repository = Split-Path $PSScriptRoot
$installer = Join-Path $repository 'install.ps1'
$network = 'shell-test'
$images = @{ arch = 'archlinux:latest'; debian = 'debian:testing' }
$utf8 = [Text.UTF8Encoding]::new($false)
$linux = @($Target | Where-Object { $_ -ne 'sandbox' })

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)

    # Successful programs such as Python's unittest write progress to stderr. Stop would turn
    # that into a terminating error when this script's output is redirected; the exit code decides.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments[0]) failed ($LASTEXITCODE)." }
}

function Test-Wslc {
    # A missing network or container is reported on stderr and is not a failure of this probe.
    $ErrorActionPreference = 'Continue'
    & wslc.exe @args *> $null
    $LASTEXITCODE -eq 0
}

$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$sandbox = Join-Path $StateDirectory 'sandbox'
$cache = Join-Path $StateDirectory 'cache'
$null = [IO.Directory]::CreateDirectory($sandbox)
$null = [IO.Directory]::CreateDirectory((Join-Path $cache 'scoop'))
$volumes = @{
    arch = @('-v', 'shell-test-pacman:/var/cache/pacman/pkg', '-v', 'shell-test-aur:/var/cache/shell-aur')
    debian = @('-v', 'shell-test-apt:/var/cache/apt/archives', '-v', 'shell-test-releases:/var/cache/shell-releases')
}
$timings = [ordered]@{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$image = & $installer -PrepareOnly -StateDirectory $StateDirectory | Select-Object -Last 1
foreach ($test in @(
    'test_terminal_settings.py', 'test_release_update.py', 'test_shell_paths.py',
    'test_nushell_defaults.py', 'test_invariants.py'
)) {
    Invoke-Native wslc.exe @(
        'run', '--rm', '-v', "${repository}:/work:ro", $image,
        'python', '-B', "/work/tests/$test"
    )
}
$windowsUser = 'shelltest'
$adminUser = 'WDAGUtilityAccount'
$unprivileged = [ordered]@{}
$key = [IO.File]::ReadAllText((Join-Path $StateDirectory 'id_ed25519.pub')).Trim()
$windows = [ordered]@{}
$wsl = [ordered]@{}
$jobs = [ordered]@{}

# The control container joins this network for every target, including Windows Sandbox alone.
# wslc's next default pool is inside 172.16.0.0/12. 172.18.0.0/16 contains the Hyper-V Default
# Switch, so a sandbox address looks on-link and the connection fails with "No route to host".
$networkSubnet = '10.77.90.0/24'
$networkGateway = '10.77.90.1'

function Get-TestNetworkSubnet {
    param([string]$Name)

    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $details = & wslc.exe network inspect $Name 2>$null
    $inspected = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if (-not $inspected) { return $null }
    [string]@(@(($details | Out-String | ConvertFrom-Json))[0].IPAM.Config)[0].Subnet
}

if ((Get-TestNetworkSubnet $network) -ne $networkSubnet) {
    $ErrorActionPreference = 'Continue'
    foreach ($name in @('arch', 'debian')) { & wslc.exe remove -f "shell-test-$name" *> $null }
    & wslc.exe network remove $network *> $null
    $ErrorActionPreference = 'Stop'
    Invoke-Native wslc.exe @(
        'network', 'create', '--subnet', $networkSubnet, '--gateway', $networkGateway, $network
    )
}

$linuxSetup = {
    param($Name, $Image, $Network, $Repository, $Volumes, $Key, $Reuse, $Log)

    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $container = "shell-test-$Name"
    function Invoke-Logged {
        # wslc writes progress to stderr, and a missing container makes remove fail; the exit code is the result.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        & wslc.exe @args *>> $Log
        if ($LASTEXITCODE -ne 0) { throw "wslc $($args[0]) failed for $container ($LASTEXITCODE); see $Log" }
    }

    $ErrorActionPreference = 'Continue'
    $details = & wslc.exe inspect $container 2>$null
    $inspected = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    $running = $inspected -and
        @(($details | Out-String | ConvertFrom-Json))[0].State.Running -eq $true
    if (-not ($Reuse -and $running)) {
        $ErrorActionPreference = 'Continue'
        & wslc.exe remove -f $container *> $null
        $ErrorActionPreference = 'Stop'
        Invoke-Logged (@(
            'run', '-d', '--name', $container, '--hostname', $Name, '--network', $Network
            '-v', "${Repository}:/mnt/c/Users/shell/.config/shell:ro"
        ) + $Volumes + @($Image, 'sleep', 'infinity'))
        Invoke-Logged exec $container rm -f /etc/apt/apt.conf.d/docker-clean
    }

    # Bootstrap logs package installation on stderr. In a job, Stop would fail the job on that progress.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $sshd = & wslc.exe exec $container sh /mnt/c/Users/shell/.config/shell/ansible/bootstrap/wsl.sh 22 0.0.0.0 $Key 2>> $Log |
        Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "Bootstrap failed in $container; see $Log" }
    $alive = 'pid=$(cat /etc/shell-ansible/sshd.pid 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid"'
    & wslc.exe exec $container sh -c $alive *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Logged exec $container setsid -f $sshd.Trim() -D -E /var/log/shell-ansible-sshd.log `
            -f /etc/shell-ansible/sshd_config
        Invoke-Logged exec $container sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do $alive && exit 0; sleep 1; done; exit 1"
    }
}

foreach ($name in $linux) {
    $log = Join-Path $StateDirectory "setup-$name.log"
    [IO.File]::WriteAllText($log, '')
    $jobs[$name] = Start-Job -ScriptBlock $linuxSetup -ArgumentList @(
        $name, $images[$name], $network, $repository, $volumes[$name], $key, [bool]$Reuse, $log
    )
    $wsl[$name] = [ordered]@{
        ansible_host = "shell-test-$name"
        ansible_user = 'root'
        ansible_ssh_private_key_file = '/root/.ssh/shell-ansible'
        ansible_ssh_common_args = '-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
        shell_windows_home = '/mnt/c/Users/shell'
        shell_user = 'shell'
        shell_aur_cache = '/var/cache/shell-aur'
    }
}

if ($Target -contains 'sandbox') {
    foreach ($mirrorName in @('Scoop', 'Main', 'Versions')) {
        $mirror = Join-Path $cache "git/$mirrorName.git"
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = 'Continue'
        if (-not [IO.Directory]::Exists($mirror)) {
            & git clone -q --bare --depth 1 "https://github.com/ScoopInstaller/$mirrorName" $mirror
        } else {
            & git -C $mirror fetch -q --depth 1 origin '+refs/heads/*:refs/heads/*'
        }
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { throw "Could not mirror ScoopInstaller/$mirrorName." }
    }
    $msys2 = Join-Path $cache 'msys2-base-x86_64-latest.sfx.exe'
    if (-not [IO.File]::Exists($msys2)) {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -OutFile $msys2 `
            -Uri 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-base-x86_64-latest.sfx.exe'
    }
    foreach ($user in @($windowsUser, $adminUser)) {
        if ([IO.File]::Exists((Join-Path $StateDirectory "winrm-$user.pem"))) { continue }
        Invoke-Native wslc.exe @(
            'run', '--rm', '-v', "${StateDirectory}:/state", $image, 'openssl', 'req', '-x509', '-nodes'
            '-newkey', 'rsa:2048', '-days', '3650', '-subj', "/CN=$user"
            '-keyout', "/state/winrm-$user.key", '-out', "/state/winrm-$user.pem"
            '-addext', "subjectAltName=otherName:1.3.6.1.4.1.311.20.2.3;UTF8:$user@localhost"
            '-addext', 'extendedKeyUsage=clientAuth', '-addext', 'keyUsage=digitalSignature,keyEncipherment'
        )
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox.ps1'), (Join-Path $PSScriptRoot 'winrm.ps1'),
        (Join-Path $StateDirectory "winrm-$windowsUser.pem"), (Join-Path $StateDirectory "winrm-$adminUser.pem") `
        -Destination $sandbox -Force

    $jobs.sandbox = Start-Job -ArgumentList @(
        $StateDirectory, $sandbox, $cache, $repository, $windowsUser, $adminUser, [bool]$Reuse
    ) -ScriptBlock {
        param($StateDirectory, $Sandbox, $Cache, $Repository, $WindowsUser, $AdminUser, $Reuse)

        $ErrorActionPreference = 'Stop'
        $PSNativeCommandUseErrorActionPreference = $false
        $utf8 = [Text.UTF8Encoding]::new($false)
        $idFile = Join-Path $StateDirectory 'sandbox-id'
        $id = if ([IO.File]::Exists($idFile)) { [IO.File]::ReadAllText($idFile).Trim() }
        $running = $id -and ((& wsb.exe list 2>$null) -match [regex]::Escape($id))

        if (-not ($Reuse -and $running)) {
            if ($running) { & wsb.exe stop --id $id *> $null }
            $configuration = @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$Repository</HostFolder>
      <SandboxFolder>C:\shell-repo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$Sandbox</HostFolder>
      <SandboxFolder>C:\shell-test</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$Cache</HostFolder>
      <SandboxFolder>C:\shell-cache</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
</Configuration>
"@
            $id = ((& wsb.exe start --config $configuration --raw) | ConvertFrom-Json).Id
            if (-not $id) { throw 'Could not start Windows Sandbox.' }
            [IO.File]::WriteAllText($idFile, $id, $utf8)
        }

        $address = $null
        for ($attempt = 0; $attempt -lt 30 -and -not $address; $attempt++) {
            $address = ((& wsb.exe ip --id $id --raw 2>$null) | ConvertFrom-Json).Networks |
                Select-Object -ExpandProperty IpV4Address -First 1
            if (-not $address) { Start-Sleep -Seconds 5 }
        }
        if (-not $address) { throw 'Could not read the Windows Sandbox address.' }

        $settingsFile = Join-Path $Sandbox 'settings.json'
        if (-not [IO.File]::Exists($settingsFile) -or -not $Reuse) {
            $password = -join ((1..24) | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 127) }) + 'aA1!'
            [IO.File]::WriteAllText($settingsFile, (@{
                Address = $address; Password = $password; User = $WindowsUser; AdminUser = $AdminUser
            } | ConvertTo-Json), $utf8)
        }
        $ready = Join-Path $Sandbox 'ready'
        if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
        # wsb splits a command string on powershell switches, so the switches live in a launcher file.
        $launcher = Join-Path $Sandbox 'launch.cmd'
        [IO.File]::WriteAllText($launcher, @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File C:\shell-test\sandbox.ps1 > C:\shell-test\setup.log 2>&1
"@, [Text.Encoding]::ASCII)
        for ($attempt = 0; $attempt -lt 30 -and -not [IO.File]::Exists($ready); $attempt++) {
            $ErrorActionPreference = 'Continue'
            & wsb.exe exec --id $id -r System -c 'C:\shell-test\launch.cmd' *> $null
            $ErrorActionPreference = 'Stop'
            if (-not [IO.File]::Exists($ready)) { Start-Sleep -Seconds 5 }
        }
        if (-not [IO.File]::Exists($ready)) {
            throw "Sandbox setup failed; see $(Join-Path $Sandbox 'setup.log')"
        }
        Copy-Item -LiteralPath (Join-Path $Sandbox 'winrm-server.pem') -Destination $StateDirectory -Force
        [pscustomobject]@{ Address = $address }
    }
}

$address = $null
foreach ($entry in $jobs.GetEnumerator()) {
    $result = Receive-Job -Job $entry.Value -Wait -ErrorAction Stop
    if ($entry.Key -eq 'sandbox') { $address = @($result | Where-Object Address)[-1].Address }
    $timings["setup $($entry.Key)"] = $entry.Value.PSEndTime - $entry.Value.PSBeginTime
    Remove-Job -Job $entry.Value
}

if ($Target -contains 'sandbox') {
    foreach ($user in @($windowsUser, $adminUser)) {
        $connection = [ordered]@{
            ansible_host = $address
            ansible_port = 5986
            ansible_connection = 'psrp'
            ansible_psrp_protocol = 'https'
            ansible_psrp_auth = 'certificate'
            ansible_psrp_certificate_pem = "/state/winrm-$user.pem"
            ansible_psrp_certificate_key_pem = "/state/winrm-$user.key"
            ansible_psrp_ca_cert = '/state/winrm-server.pem'
            shell_dev_drive_task = $true
            shell_msys2_root = 'C:/msys64'
            shell_msys2_installer = 'file:///C:/shell-cache/msys2-base-x86_64-latest.sfx.exe'
            shell_msys2_cache = 'C:\shell-cache\msys2'
            shell_store_cache = 'C:\shell-cache\store'
        }
        if ($user -eq $adminUser) {
            $windows.sandbox = $connection
        } else {
            $connection.shell_elevate = $false
            $unprivileged['sandbox-user'] = $connection
        }
    }
}

$document = @{ all = @{ children = [ordered]@{ windows = @{ hosts = $windows }; linux = @{ hosts = $wsl } } } }
$inventoryPath = Join-Path $StateDirectory 'inventory.json'
[IO.File]::WriteAllText($inventoryPath, ($document | ConvertTo-Json -Depth 8), $utf8)

$userInventory = Join-Path $StateDirectory 'inventory-user.json'
[IO.File]::WriteAllText($userInventory, (@{ all = @{ children = @{ windows = @{ hosts = $unprivileged } } } } |
    ConvertTo-Json -Depth 8), $utf8)

# Ansible colors the recap. The escape sequences are removed before changed= is read, or a clean run looks dirty.
function Assert-Unchanged {
    param([object[]]$Output, [string]$Label)

    $recap = ($Output -join [char]10) -replace '\x1b\[[0-9;]*m', ''
    $changed = [regex]::Matches($recap, '(?m)^(\S+)\s*:\s*ok=\d+\s+changed=(\d+)') |
        Where-Object { $_.Groups[2].Value -ne '0' }
    if ($changed) {
        throw "$Label changed hosts: $(($changed | ForEach-Object { $_.Groups[1].Value }) -join ', ')"
    }
}

$env:ANSIBLE_CALLBACKS_ENABLED = 'ansible.posix.profile_tasks'
$env:PROFILE_TASKS_TASK_OUTPUT_LIMIT = '15'

$common = @{
    Inventory = $inventoryPath
    StateDirectory = $StateDirectory
    Network = $network
}

try {
    foreach ($name in $Step) {
        Write-Host "=== $name ===" -ForegroundColor Cyan
        $clock.Restart()
        switch ($name) {
            'init' { & $installer -Mode init @common }
            'prepare' { & $installer -Playbook ../tests/prepare.yml @common }
            'full' { & $installer -Mode full @common }
            'idempotence' {
                & $installer -Mode full @common 2>&1 | Tee-Object -Variable output | Out-Host
                Assert-Unchanged $output 'Second full run'
            }
            'update' { & $installer -Mode update @common }
            'verify' { & $installer -Playbook ../tests/verify.yml @common }
            'unprivileged' {
                if ($unprivileged.Count) {
                    $user = @{
                        Mode = 'full'
                        Inventory = $userInventory
                        StateDirectory = $StateDirectory
                        Network = $network
                        AnsibleArgument = @('--tags', 'config,dev_drive')
                    }
                    & $installer @user
                    & $installer @user 2>&1 | Tee-Object -Variable output | Out-Host
                    Assert-Unchanged $output 'Second unprivileged run'
                }
            }
        }
        $timings[$name] = $clock.Elapsed
    }
} finally {
    Remove-Item Env:ANSIBLE_CALLBACKS_ENABLED, Env:PROFILE_TASKS_TASK_OUTPUT_LIMIT -ErrorAction SilentlyContinue
    if ($name -and -not $timings.Contains($name)) { $timings[$name] = $clock.Elapsed }
    $report = $timings.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Step = $_.Key; Duration = $_.Value.ToString('hh\:mm\:ss') }
    }
    $report | Format-Table -AutoSize | Out-Host
    [IO.File]::WriteAllText((Join-Path $StateDirectory 'timings.json'), ($report | ConvertTo-Json), $utf8)
    if (-not $Keep) {
        $ErrorActionPreference = 'Continue'
        foreach ($target in $linux) { & wslc.exe remove -f "shell-test-$target" *> $null }
        & wslc.exe network remove $network *> $null
        if ($windows.Contains('sandbox')) {
            & wsb.exe stop --id ([IO.File]::ReadAllText((Join-Path $StateDirectory 'sandbox-id')).Trim()) *> $null
        }
    }
}
