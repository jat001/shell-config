[CmdletBinding()]
param(
    [ValidateSet('arch', 'debian', 'sandbox')]
    [string[]]$Target = @('arch', 'debian', 'sandbox'),
    [ValidateSet('init', 'prepare', 'full', 'idempotence', 'update', 'verify')]
    [string[]]$Step = @('init', 'prepare', 'full', 'idempotence', 'update', 'verify'),
    [string]$StateDirectory = (Join-Path $env:TEMP 'shell-ansible-test'),
    [switch]$Reuse,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$installer = Join-Path $repository 'install.ps1'
$network = 'shell-test'
$images = @{ arch = 'archlinux:latest'; debian = 'debian:sid' }
$utf8 = [Text.UTF8Encoding]::new($false)
$linux = @($Target | Where-Object { $_ -ne 'sandbox' })

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)

    $global:LASTEXITCODE = 0
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments[0]) failed ($LASTEXITCODE)." }
}

function Test-Wslc {
    & wslc.exe @args *> $null
    $LASTEXITCODE -eq 0
}

$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$sandbox = Join-Path $StateDirectory 'sandbox'
$null = [IO.Directory]::CreateDirectory($sandbox)
& $installer -PrepareOnly -StateDirectory $StateDirectory -WindowsUser WDAGUtilityAccount
$key = [IO.File]::ReadAllText((Join-Path $StateDirectory 'id_ed25519.pub')).Trim()
$bootstrap = '/mnt/c/Users/Jat/.config/shell/ansible/bootstrap/wsl.sh'

$windows = [ordered]@{}
$wsl = [ordered]@{}

if ($linux) {
    if (-not (Test-Wslc network inspect $network)) {
        Invoke-Native wslc.exe @('network', 'create', $network)
    }

    foreach ($name in $linux) {
        $container = "shell-test-$name"
        $details = & wslc.exe inspect $container 2>$null
        $running = $LASTEXITCODE -eq 0 -and
            @(($details | Out-String | ConvertFrom-Json))[0].State.Running -eq $true
        if (-not ($Reuse -and $running)) {
            & wslc.exe remove -f $container *> $null
            Invoke-Native wslc.exe @(
                'run', '-d', '--name', $container, '--hostname', $name, '--network', $network
                '-v', "${repository}:/mnt/c/Users/Jat/.config/shell:ro"
                $images[$name], 'sleep', 'infinity'
            )
        }
        $global:LASTEXITCODE = 0
        $sshd = (& wslc.exe exec $container sh $bootstrap 22 0.0.0.0 $key | Select-Object -Last 1)
        if ($LASTEXITCODE -ne 0) { throw "Bootstrap failed in $container." }
        & wslc.exe exec $container sh -c 'pid=$(cat /etc/shell-ansible/sshd.pid 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid"' *> $null
        if ($LASTEXITCODE -ne 0) {
            Invoke-Native wslc.exe @(
                'exec', $container, 'setsid', '-f', $sshd.Trim(), '-D', '-E', '/var/log/shell-ansible-sshd.log'
                '-f', '/etc/shell-ansible/sshd_config'
            )
            $probe = 'for i in 1 2 3 4 5 6 7 8 9 10; do pid=$(cat /etc/shell-ansible/sshd.pid 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" && exit 0; sleep 1; done; cat /var/log/shell-ansible-sshd.log >&2; exit 1'
            Invoke-Native wslc.exe @('exec', $container, 'sh', '-c', $probe)
        }
        $wsl[$name] = [ordered]@{
            ansible_host = $container
            ansible_user = 'root'
            ansible_ssh_private_key_file = '/root/.ssh/shell-ansible'
            ansible_ssh_common_args = '-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
            shell_windows_home = '/mnt/c/Users/Jat'
        }
    }
}

if ($Target -contains 'sandbox') {
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
      <HostFolder>$repository</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\.config\shell</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$sandbox</HostFolder>
      <SandboxFolder>C:\shell-test</SandboxFolder>
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

    $settingsFile = Join-Path $sandbox 'settings.json'
    if (-not [IO.File]::Exists($settingsFile) -or -not $Reuse) {
        $password = -join ((1..24) | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 127) }) + 'aA1!'
        [IO.File]::WriteAllText($settingsFile, (@{ Address = $address; Password = $password } | ConvertTo-Json), $utf8)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox.ps1'),
        (Join-Path $repository 'ansible/bootstrap/winrm.ps1'),
        (Join-Path $StateDirectory 'winrm-client.pem') -Destination $sandbox -Force
    $ready = Join-Path $sandbox 'ready'
    if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
    $command = 'cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File C:\shell-test\sandbox.ps1 > C:\shell-test\setup.log 2>&1"'
    for ($attempt = 0; $attempt -lt 30 -and -not [IO.File]::Exists($ready); $attempt++) {
        & wsb.exe exec --id $id -r System -c $command *> $null
        if (-not [IO.File]::Exists($ready)) { Start-Sleep -Seconds 5 }
    }
    if (-not [IO.File]::Exists($ready)) {
        throw "Sandbox setup failed; see $(Join-Path $sandbox 'setup.log')"
    }
    Copy-Item -LiteralPath (Join-Path $sandbox 'winrm-server.pem') -Destination $StateDirectory -Force

    $windows.sandbox = [ordered]@{
        ansible_host = $address
        ansible_port = 5986
        ansible_connection = 'psrp'
        ansible_psrp_protocol = 'https'
        ansible_psrp_auth = 'certificate'
        ansible_psrp_certificate_pem = '/state/winrm-client.pem'
        ansible_psrp_certificate_key_pem = '/state/winrm-client.key'
        ansible_psrp_ca_cert = '/state/winrm-server.pem'
        shell_msys2_root = 'C:/msys64'
        shell_dev_drive_task = $true
    }
}

$document = @{ all = @{ children = [ordered]@{ windows = @{ hosts = $windows }; linux = @{ hosts = $wsl } } } }
$inventoryPath = Join-Path $StateDirectory 'inventory.json'
[IO.File]::WriteAllText($inventoryPath, ($document | ConvertTo-Json -Depth 8), $utf8)

$common = @{
    Inventory = $inventoryPath
    StateDirectory = $StateDirectory
    Network = $network
}

try {
    foreach ($name in $Step) {
        Write-Host "=== $name ===" -ForegroundColor Cyan
        switch ($name) {
            'init' { & $installer -Mode init @common }
            'prepare' { & $installer -Playbook ../tests/prepare.yml @common }
            'full' { & $installer -Mode full @common }
            'idempotence' {
                & $installer -Mode full @common 2>&1 | Tee-Object -Variable output | Out-Host
                $recap = ($output -join [char]10) -replace '\x1b\[[0-9;]*m', ''
                $changed = [regex]::Matches($recap, '(?m)^(\S+)\s*:\s*ok=\d+\s+changed=(\d+)') |
                    Where-Object { $_.Groups[2].Value -ne '0' }
                if ($changed) {
                    throw "Second full run changed hosts: $(($changed | ForEach-Object { $_.Groups[1].Value }) -join ', ')"
                }
            }
            'update' { & $installer -Mode update @common }
            'verify' { & $installer -Playbook ../tests/verify.yml @common }
        }
    }
} finally {
    if (-not $Keep) {
        foreach ($name in $linux) { & wslc.exe remove -f "shell-test-$name" *> $null }
        if ($linux) { & wslc.exe network remove $network *> $null }
        if ($windows.Contains('sandbox')) {
            & wsb.exe stop --id ([IO.File]::ReadAllText((Join-Path $StateDirectory 'sandbox-id')).Trim()) *> $null
        }
    }
}
