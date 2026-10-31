param([switch]$AfterRestart, [switch]$RestartGuest, [switch]$Queue)

$ErrorActionPreference = 'Stop'
$repository = Join-Path $env:USERPROFILE '.config/shell'
$configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$result = @{ Success=$false; Checks=@() }
$taskName = 'Shell Config Verify Once'
$script = Join-Path $repository 'tests/hyperv_verify.ps1'

if ($RestartGuest -or $Queue) {
    $computer = Get-CimInstance Win32_ComputerSystem
    # Restart-Computer here is only safe inside the test guest. The same script on the host would reboot the user.
    if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
        throw 'Restart verification is restricted to the Hyper-V test guest.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -AfterRestart"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force
    if ($RestartGuest) { Restart-Computer -Force }
    else { Start-ScheduledTask -TaskName $taskName }
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

try {
    $env:HOME = [Environment]::GetEnvironmentVariable('HOME','User')
    $env:PATH = (Join-Path $env:USERPROFILE 'scoop/shims') + ';' + $env:PATH
    $drive = [Environment]::GetEnvironmentVariable('DEV_DRIVE','User')
    $Ansible=@{Changed=$false;Result=$null}
    & (Join-Path $repository 'ansible/roles/windows/files/dev_drive.ps1') `
        -Path (Join-Path $env:USERPROFILE $configuration.environments.windows.dev_drive.vhd) -Wait 60
    $disk=$Ansible.Result
    Remove-Variable Ansible
    if (-not $disk.attached -or -not $disk.letter) { throw 'The configured Windows VHDX is not attached.' }
    if ($disk.letter -ne $drive) { throw "The actual drive $($disk.letter) differs from DEV_DRIVE=$drive." }
    if ([IO.DriveInfo]::new($drive+'\').DriveFormat -ne 'ReFS') { throw 'The development drive is not ReFS.' }
    $result.Checks += 'Windows development drive'
    Test-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        @('-NoLogo','-NonInteractive','-Command','exit 0') 'windows-powershell'
    $pwsh = Get-AppxPackage -Name Microsoft.PowerShell | Select-Object -First 1
    Test-Process (Join-Path $pwsh.InstallLocation 'pwsh.exe') @('-NoLogo','-NonInteractive','-Command','exit 0') 'pwsh'
    Test-Process (Join-Path $env:USERPROFILE 'scoop/apps/nu/current/nu.exe') @('--env-config',(Join-Path $env:APPDATA 'nushell/env.nu'),
        '--config',(Join-Path $env:APPDATA 'nushell/config.nu'),'-c','exit') 'nu'
    & (Join-Path $repository 'tests/clink.ps1') -Root (Join-Path $env:USERPROFILE 'scoop') `
        -Installer (Join-Path $repository 'ansible/roles/windows/files/clink.ps1')
    $result.Checks += 'Clink interactive injection'

    $msysRoot = $configuration.environments.msys2.root.Replace('${DEV_DRIVE}', $drive)
    $msysProbe = @"
set -e
bash -ic 'alias code; command -v oh-my-posh'
zsh -ic 'alias code; command -v oh-my-posh'
fish -ic 'functions code; command -s oh-my-posh'
"@
    [IO.File]::WriteAllText('C:\shell-test\verify-msys2.sh', $msysProbe.Replace("`r",'')+"`n", [Text.UTF8Encoding]::new($false))
    $savedHome = $env:HOME
    $savedMsystem = $env:MSYSTEM
    try {
        $env:HOME = '/home/' + $env:USERNAME
        $env:MSYSTEM = 'MSYS'
        Test-Process (Join-Path $msysRoot 'usr/bin/bash.exe') @('--login','C:/shell-test/verify-msys2.sh') 'msys2'
    } finally { $env:HOME=$savedHome; $env:MSYSTEM=$savedMsystem }
    $probe = @'
#!/bin/sh
set -eu
for command in jq oh-my-posh zsh fish nu pwsh; do command -v "$command"; done
bash -ic 'alias code; test -n "$OMP_CACHE_DIR"'
zsh -ic 'alias code; test -n "$OMP_CACHE_DIR"'
fish -ic 'functions code; test -n "$OMP_CACHE_DIR"'
pwsh -NoLogo -NonInteractive -Command '$ErrorActionPreference="Stop"; Import-Module PSCompletions; exit 0'
nu --env-config "$HOME/.config/nushell/env.nu" --config "$HOME/.config/nushell/config.nu" -c 'exit 0'
'@
    [IO.File]::WriteAllText('C:\shell-test\verify-shells.sh', $probe.Replace("`r",'')+"`n", [Text.UTF8Encoding]::new($false))
    $wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
    foreach ($distribution in $configuration.environments.wsl.distributions) {
        foreach ($user in @('root',$env:USERNAME.ToLowerInvariant())) {
            $name = "$distribution-$user"
            Test-Process $wsl @('-d',$distribution,'-u',$user,'--cd','~','--exec','sh',
                '/mnt/c/shell-test/verify-shells.sh') $name
        }
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
    $result.Success = $true
} catch { $result.Error=$_.Exception.Message }
finally {
    if ($AfterRestart) {
        $computer = Get-CimInstance Win32_ComputerSystem
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $login = Get-ItemProperty -LiteralPath $key
        $result.LoginUser = $env:USERNAME
        $result.ConfiguredLoginUser = $login.DefaultUserName
        if ($computer.Model -eq 'Virtual Machine' -and $computer.Manufacturer -eq 'Microsoft Corporation' -and
            $env:COMPUTERNAME -eq 'SHELLCONFIGTEST') {
            $cleanup = & (Join-Path $repository 'tests/hyperv_logon.ps1') -Action Clear
            foreach ($name in $cleanup.Keys) { $result[$name] = $cleanup[$name] }
        }
    }
    [IO.File]::WriteAllText('C:\shell-test\verification-result.json', ($result|ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    if ($AfterRestart) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}
