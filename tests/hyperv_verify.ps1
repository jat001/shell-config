param(
    [switch]$AfterRestart,
    [switch]$RestartGuest,
    [switch]$Queue,
    [switch]$Prepare,
    [Parameter(Mandatory)][string]$OperationId
)

$ErrorActionPreference = 'Stop'
$repository = Join-Path $env:USERPROFILE '.config/shell'
$result = @{ OperationId=$OperationId; Success=$false; Checks=@(); Running=$true }
$resultPath = 'C:\shell-test\verification-result.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$taskName = 'Shell Config Verify Once'
$script = Join-Path $repository 'tests/hyperv_verify.ps1'
function Write-VerificationResult {
    $json = $script:result | ConvertTo-Json -Depth 5
    $temporary = "$script:resultPath.$($script:result.OperationId).tmp"
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $bytes = $script:utf8.GetBytes($json)
            $stream = [IO.File]::Open($temporary, 'Create', 'Write', 'Read')
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
            if ([IO.File]::Exists($script:resultPath)) {
                [IO.File]::Replace($temporary, $script:resultPath, [NullString]::Value)
            } else { [IO.File]::Move($temporary, $script:resultPath) }
            $stream = [IO.File]::Open($script:resultPath, 'Open', 'Write', 'Read')
            try { $stream.Flush($true) } finally { $stream.Dispose() }
            return
        } catch [IO.IOException] {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}
Write-VerificationResult
$configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json

if ($RestartGuest -or $Queue -or $Prepare) {
    $computer = Get-CimInstance Win32_ComputerSystem
    # Verification setup is only safe inside the designated test guest.
    if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
        throw 'Verification setup is restricted to the Hyper-V test guest.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -AfterRestart -OperationId $OperationId"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force
    if ($RestartGuest) { Restart-Computer -Force }
    elseif ($Queue) { Start-ScheduledTask -TaskName $taskName }
    return
}

function Test-Process {
    param([string]$Path, [string[]]$Arguments, [string]$Name)
    $stdout = "C:\shell-test\verify-$Name.out"
    $stderr = "C:\shell-test\verify-$Name.err"
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) { throw "$Name exited with $($process.ExitCode). See $stderr" }
    if ($Name -in @('windows-powershell','pwsh','nu') -and (Get-Item -LiteralPath $stderr).Length) {
        throw "$Name profile wrote errors to $stderr"
    }
    $script:result.Checks += $Name
}

$checksPassed = $false
$failure = $null
try {
    $env:HOME = [Environment]::GetEnvironmentVariable('HOME','User')
    $env:PATH = (Join-Path $env:USERPROFILE 'scoop/shims') + ';' + $env:PATH
    $drive = [Environment]::GetEnvironmentVariable('DEV_DRIVE','User')
    $vhd = Join-Path $env:USERPROFILE $configuration.environments.windows.dev_drive.vhd
    $Ansible=@{Changed=$false;Result=$null}
    & (Join-Path $repository 'ansible/roles/windows/files/dev_drive.ps1') -Path $vhd -Wait 60
    $disk=$Ansible.Result
    Remove-Variable Ansible
    if (-not $disk.attached -or -not $disk.letter) { throw 'The configured Windows VHDX is not attached.' }
    if ($disk.letter -ne $drive) { throw "The actual drive $($disk.letter) differs from DEV_DRIVE=$drive." }
    if ([IO.DriveInfo]::new($drive+'\').DriveFormat -ne 'ReFS') { throw 'The development drive is not ReFS.' }
    $result.Checks += 'Windows development drive'
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks'
    if (-not (Get-ChildItem -LiteralPath $key | Where-Object { $_.GetValue('Path') -eq $vhd })) {
        throw "Not attached at boot: $vhd"
    }
    $lines = [IO.File]::ReadAllLines((Join-Path $env:USERPROFILE '.wslconfig'))
    foreach ($line in 'networkingMode=Mirrored', 'telemetry=false', 'autoMemoryReclaim=Gradual', 'hostAddressLoopback=true') {
        if ($lines -notcontains $line) { throw "Missing $line in .wslconfig" }
    }
    $null = Get-ScheduledTask -TaskName 'WSL Attach Dev VHDX' -ErrorAction Stop
    $developer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if ($developer.AllowDevelopmentWithoutDevLicense -ne 1) { throw 'Developer Mode is disabled.' }
    $result.Checks += 'Windows boot settings'
    Test-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        @('-NoLogo','-NonInteractive','-Command','exit 0') 'windows-powershell'
    $pwsh = Get-AppxPackage -Name Microsoft.PowerShell | Select-Object -First 1
    $pwshCommand = '$ErrorActionPreference=''Stop''; if (-not (Get-Module PSCompletions)) { throw ''PSCompletions is missing.'' }; exit 0'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pwshCommand))
    Test-Process (Join-Path $pwsh.InstallLocation 'pwsh.exe') @('-NoLogo','-NonInteractive','-EncodedCommand', $encoded) 'pwsh'
    Test-Process (Join-Path $env:USERPROFILE 'scoop/apps/nu/current/nu.exe') @('--env-config',(Join-Path $env:APPDATA 'nushell/env.nu'),
        '--config',(Join-Path $env:APPDATA 'nushell/config.nu'),'-c','exit') 'nu'
    & (Join-Path $repository 'tests/clink.ps1') -Root (Join-Path $env:USERPROFILE 'scoop') `
        -Installer (Join-Path $repository 'ansible/roles/windows/files/clink.ps1')
    $result.Checks += 'Clink interactive injection'

    $msysRoot = $configuration.environments.msys2.root.Replace('${DEV_DRIVE}', $drive)
    $msysProbe = @"
set -e
bash -ic 'alias code && command -v oh-my-posh'
zsh -ic 'alias code && command -v oh-my-posh'
fish -ic 'functions code && command -s oh-my-posh'
"@
    [IO.File]::WriteAllText('C:\shell-test\verify-msys2.sh', $msysProbe.Replace("`r",'')+"`n", [Text.UTF8Encoding]::new($false))
    $savedHome = $env:HOME
    $savedMsystem = $env:MSYSTEM
    try {
        $env:HOME = '/home/' + $env:USERNAME
        $env:MSYSTEM = 'UCRT64'
        Test-Process (Join-Path $msysRoot 'usr/bin/bash.exe') @('--login','C:/shell-test/verify-msys2.sh') 'msys2'
    } finally { $env:HOME=$savedHome; $env:MSYSTEM=$savedMsystem }
    $probe = @'
#!/bin/sh
set -eu
if [ -f /etc/debian_version ]; then
    grep -q '/sid' /etc/debian_version
    grep -q '^Suites: testing testing-updates$' /etc/apt/sources.list.d/debian.sources
    grep -q '^Suites: testing-security$' /etc/apt/sources.list.d/debian.sources
fi
for command in jq oh-my-posh git wsl2-ssh-agent zsh fish nu pwsh; do command -v "$command"; done
bash -ic 'alias code && test "$OMP_CACHE_DIR" = "$HOME/.cache" && test "$PNPM_HOME" = "/mnt/wsl/dev$HOME/.local/share/pnpm"'
zsh -ic 'alias code && test "$OMP_CACHE_DIR" = "$HOME/.cache" && test "$PNPM_HOME" = "/mnt/wsl/dev$HOME/.local/share/pnpm"'
fish -ic 'functions code && test "$OMP_CACHE_DIR" = "$HOME/.cache" && test "$PNPM_HOME" = "/mnt/wsl/dev$HOME/.local/share/pnpm"'
pwsh -NoLogo -NonInteractive -Command '$ErrorActionPreference="Stop"; Import-Module PSCompletions; exit 0'
nu --env-config "$HOME/.config/nushell/env.nu" --config "$HOME/.config/nushell/config.nu" -c 'exit 0'
'@
    [IO.File]::WriteAllText('C:\shell-test\verify-shells.sh', $probe.Replace("`r",'')+"`n", [Text.UTF8Encoding]::new($false))
    $systemProbe = @'
#!/bin/sh
set -eu
user=$1
[ "$(id -u "$user")" = 1000 ]
[ "$(id -g "$user")" = 1000 ]
! getent passwd aurbuilder >/dev/null
su "$user" -c 'sudo -n true'
grep -qx 'default=root' /etc/wsl.conf
grep -qx 'systemd=true' /etc/wsl.conf
grep -qx 'appendWindowsPath=false' /etc/wsl.conf
grep -qx 'options="metadata"' /etc/wsl.conf
'@
    [IO.File]::WriteAllText('C:\shell-test\verify-wsl-system.sh', $systemProbe.Replace("`r",'')+"`n",
        [Text.UTF8Encoding]::new($false))
    $wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
    function Wait-WslProfile {
        param([string]$Distribution, [string]$User)
        # A cold-boot logon can reach this probe before the WSL zsh profile has finished initializing.
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $process = Start-Process -FilePath $wsl -ArgumentList @(
                '-d', $Distribution, '-u', $User, '--exec', 'zsh', '-ic', '"alias code"'
            ) -Wait -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput "C:\shell-test\wait-$Distribution-$User.out" `
                -RedirectStandardError "C:\shell-test\wait-$Distribution-$User.err"
            if ($process.ExitCode -eq 0) { return }
            Start-Sleep -Seconds 5
        }
        throw "$Distribution/$User zsh profile did not become ready."
    }
    foreach ($distribution in $configuration.environments.wsl.distributions) {
        foreach ($user in @('root',$env:USERNAME.ToLowerInvariant())) {
            $name = "$distribution-$user"
            Wait-WslProfile $distribution $user
            Test-Process $wsl @('-d',$distribution,'-u',$user,'--cd','~','--exec','sh',
                '/mnt/c/shell-test/verify-shells.sh') $name
        }
        Test-Process $wsl @('-d',$distribution,'-u','root','--exec','sh',
            '/mnt/c/shell-test/verify-wsl-system.sh',$env:USERNAME.ToLowerInvariant()) "$distribution-system"
        Test-Process $wsl @('-d',$distribution,'-u','root','--exec','findmnt','-rn','-M',
            $configuration.environments.wsl.dev_drive.mountpoint,'-t','btrfs') "$distribution-btrfs"
    }
    $terminal = Get-AppxPackage -Name Microsoft.WindowsTerminal | Select-Object -First 1
    $manifest = Get-AppxPackageManifest -Package $terminal
    $application = @($manifest.Package.Applications.Application)[0].Id
    $activation = 'shell:AppsFolder\' + $terminal.PackageFamilyName + '!' + $application
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $activation
    Start-Sleep -Seconds 4
    if (-not (Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) { throw 'Terminal GUI did not start.' }
    $result.Checks += 'Terminal GUI'
    $checksPassed = $true
} catch { $failure = $_.Exception.Message }

if ($AfterRestart) {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $login = Get-ItemProperty -LiteralPath $key
        $result.LoginUser = $env:USERNAME
        $result.ConfiguredLoginUser = $login.DefaultUserName
        if ($computer.Model -eq 'Virtual Machine' -and $computer.Manufacturer -eq 'Microsoft Corporation' -and
            $env:COMPUTERNAME -eq 'SHELLCONFIGTEST') {
            $cleanup = & (Join-Path $repository 'tests/hyperv_logon.ps1') -Action Clear
            foreach ($name in $cleanup.Keys) { $result[$name] = $cleanup[$name] }
            foreach ($name in 'AutoLoginDisabled', 'StoredLogonSecretRemoved', 'RegistryPasswordRemoved') {
                if ($cleanup[$name] -ne $true) { throw "Logon cleanup failed: $name" }
            }
        }
    } catch {
        if ($failure) { $failure = "$failure; $($_.Exception.Message)" } else { $failure = $_.Exception.Message }
    }
}
$result.Success = $checksPassed -and -not $failure
if ($failure) { $result.Error = $failure }
$result.Running = $false
try { Write-VerificationResult } finally {
    if ($AfterRestart) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}
if (-not $result.Success) { exit 1 }
