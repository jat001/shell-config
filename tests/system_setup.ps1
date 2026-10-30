param([string]$Repository)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-system-test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
$homePath = Join-Path $temporary 'home'
$null = [IO.Directory]::CreateDirectory($homePath)
$scriptPath = Join-Path $temporary 'system_setup.ps1'
$requestPath = Join-Path $temporary 'request.json'
Copy-Item -LiteralPath (Join-Path $Repository 'ansible/roles/windows/files/system_setup.ps1') -Destination $scriptPath
$utf8 = [Text.UTF8Encoding]::new($false)
$request = @{
    Configuration = @{ environments = @{
        windows = @{ dev_drive = @{ vhd='windows.vhdx'; size_gib=1024 } }
        wsl = @{ dev_drive = @{ vhd='linux.vhdx'; size_gib=1024; filesystem='btrfs';
            task='Shell Test Drive'; mountpoint='/mnt/wsl/dev'; options='compress=zstd:1' } }
    } }
    Home=$homePath; Mode='full'; UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    LegacyKey='{00000000-0000-0000-0000-000000000000}'
    ManageDeveloperMode=$true; ManageWindowsDrive=$true; ManageWslDrive=$true; AllowDetach=$false
}
$global:ShellSystemTestDeveloperMode = 0
$global:ShellSystemTestTask = $null
# These functions hide the real cmdlets for the child script. They are visible because the child runs in a child scope.
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$ErrorAction)
    if ($LiteralPath -notlike 'HKLM:*AppModelUnlock') { throw 'Unexpected registry read.' }
    [pscustomobject]@{ AllowDevelopmentWithoutDevLicense=$global:ShellSystemTestDeveloperMode }
}
function Get-ScheduledTask {
    param([string]$TaskPath, [string]$TaskName, [string]$ErrorAction)
    $global:ShellSystemTestTask
}
function Write-Request {
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 10), $utf8)
}
function Invoke-Plan {
    Write-Request
    $Ansible = @{ Changed=$false; Result=$null }
    $plan = & $scriptPath -RequestPath $requestPath
    if ($null -ne $plan) { return @($plan)[-1] }
    $Ansible.Result
}

try {
    $plan = Invoke-Plan
    $expected = @('DeveloperMode', 'CreateDrive', 'AttachDrive', 'CreateDrive', 'RegisterTask')
    if (($plan.Pending -join ',') -cne ($expected -join ',')) { throw 'First deployment did not aggregate all system changes.' }
    $Ansible = @{ Changed=$false; Result=$null }
    $null = & $scriptPath -RequestPath $requestPath -Apply -WhatIf
    if ([IO.File]::Exists((Join-Path $homePath 'windows.vhdx')) -or
        [IO.File]::Exists((Join-Path $homePath 'linux.vhdx'))) { throw 'Preview created a disk.' }

    [IO.File]::WriteAllText((Join-Path $temporary 'dev_drive.ps1'), @'
param([string]$Path, [string]$LegacyKey)
$Ansible.Result = @{ registered=$true; attached=$true; legacy_registration=$false; letter='Z:' }
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $homePath 'windows.vhdx'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $homePath 'linux.vhdx'), 'fixture')
    $global:ShellSystemTestDeveloperMode = 1
    $global:ShellSystemTestTask = [pscustomobject]@{
        Description='Shared shell configuration: attach the WSL development VHDX.'
        Actions=@([pscustomobject]@{ Execute=(Join-Path $env:SystemRoot 'System32\wsl.exe');
            Arguments=('--mount --vhd "' + (Join-Path $homePath 'linux.vhdx') + '" --type btrfs --name dev --options "compress=zstd:1"') })
        Principal=[pscustomobject]@{ UserId=$request.UserSid; RunLevel='Highest'; LogonType='Interactive' }
        Settings=[pscustomobject]@{ Enabled=$true; AllowDemandStart=$true; DisallowStartIfOnBatteries=$false;
            StopIfGoingOnBatteries=$false; MultipleInstances='IgnoreNew'; ExecutionTimeLimit='PT1M' }
    }
    if ((Invoke-Plan).Pending.Count) { throw 'An already configured machine requested another elevation.' }

    $request.Mode = 'update'
    $global:ShellSystemTestDeveloperMode = 0
    if ((Invoke-Plan).Pending.Count) { throw 'Update requested one-time Developer Mode initialization.' }

    $global:ShellSystemTestTask.Description = 'Unrelated task'
    $global:ShellSystemTestTask.Actions[0].Arguments = 'different arguments'
    $rejected = $false
    try { $null = Invoke-Plan } catch {
        if ($_.Exception.Message -notlike '*unrelated scheduled task*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'An unrelated scheduled task was accepted.' }

    $request.ManageWslDrive = $false
    $request.Configuration.environments.windows.dev_drive.vhd = '../outside.vhdx'
    $rejected = $false
    try { $null = Invoke-Plan } catch {
        if ($_.Exception.Message -notlike '*escapes the Windows home*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'A VHDX outside the configured Windows home was accepted.' }
    "PowerShell $($PSVersionTable.PSVersion): batched system plan, idempotency, preview and conflict checks passed."
} finally {
    Remove-Variable ShellSystemTestDeveloperMode, ShellSystemTestTask -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
