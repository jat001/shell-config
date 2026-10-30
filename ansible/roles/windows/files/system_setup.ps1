[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
$configuration = $request.Configuration
$homePath = [IO.Path]::GetFullPath($request.Home)
$operations = [Collections.Generic.List[object]]::new()
$developerKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$developerMode = (Get-ItemProperty -LiteralPath $developerKey -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
$windowsDrive = $configuration.environments.windows.dev_drive
$wslDrive = $configuration.environments.wsl.dev_drive
$windowsPath = $null
$wslPath = $null

function Get-DrivePath {
    param([string]$Relative)

    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '["''\r\n]') {
        throw 'A development VHDX path must be relative to the Windows home.'
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $homePath $Relative))
    if (-not $resolved.StartsWith($homePath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A development VHDX path escapes the Windows home.'
    }
    if ($resolved -notlike '*.vhdx') { throw 'A development disk must use a .vhdx file.' }
    $resolved
}

function Read-Drive {
    param([string]$Path)

    # An external script cannot see this local variable. Dot-source it so the disk probe
    # cannot replace the caller's Ansible result with the disk status.
    $Ansible = @{ Changed=$false; Result=$null }
    . (Join-Path $PSScriptRoot 'dev_drive.ps1') -Path $Path -LegacyKey $request.LegacyKey
    $Ansible.Result
}

function Get-PrincipalSid {
    param([string]$Name)

    if ($Name -match '^S-1-') { return $Name }
    ([Security.Principal.NTAccount]::new($Name)).Translate([Security.Principal.SecurityIdentifier]).Value
}

# update never turns Developer Mode on. It is a one-time init step, not something an upgrade should repeat.
if ($request.ManageDeveloperMode -and $request.Mode -ne 'update' -and $developerMode -ne 1) {
    $operations.Add(@{ Kind='DeveloperMode' })
}
if ($request.ManageWindowsDrive -and $windowsDrive) {
    $windowsPath = Get-DrivePath $windowsDrive.vhd
    if (-not [IO.File]::Exists($windowsPath)) {
        $operations.Add(@{ Kind='CreateDrive'; Path=$windowsPath; SizeGiB=$windowsDrive.size_gib; FileSystem='ReFS' })
        $operations.Add(@{ Kind='AttachDrive'; Path=$windowsPath })
    } else {
        $disk = Read-Drive $windowsPath
        if (-not $disk.registered -or -not $disk.attached -or $disk.legacy_registration) {
            $operations.Add(@{ Kind='AttachDrive'; Path=$windowsPath })
        }
    }
}
if ($request.ManageWslDrive -and $wslDrive) {
    $wslPath = Get-DrivePath $wslDrive.vhd
    if (-not [IO.File]::Exists($wslPath)) {
        $operations.Add(@{ Kind='CreateDrive'; Path=$wslPath; SizeGiB=$wslDrive.size_gib; FileSystem=$wslDrive.filesystem })
    }
    if ($wslDrive.task -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' -or
        $wslDrive.mountpoint -notmatch '^/\S+/[A-Za-z0-9][A-Za-z0-9._-]*$' -or
        $wslDrive.filesystem -notmatch '^[a-z0-9]+$' -or
        $wslDrive.options -match '["\r\n]') {
        throw 'Invalid WSL development drive settings.'
    }
    $executable = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $arguments = '--mount --vhd "' + $wslPath + '" --type ' + $wslDrive.filesystem +
        ' --name ' + ($wslDrive.mountpoint -split '/')[-1]
    if ($wslDrive.options) { $arguments += ' --options "' + $wslDrive.options + '"' }
    $description = 'Shared shell configuration: attach the WSL development VHDX.'
    # A standard user cannot open the task service. That is not a missing task, and this
    # account cannot register one; an elevated run owns the registration.
    $wslTaskUnreadable = $false
    try {
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $wslDrive.task -ErrorAction Stop
    } catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
        $task = $null
        $wslTaskUnreadable = $true
    }
    # A task with this name that runs a different program is left in place. Matching arguments can be updated.
    if ($task -and $task.Description -ne $description -and
        ($task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine $executable -or
         $task.Actions[0].Arguments -cne $arguments)) {
        throw "An unrelated scheduled task already uses this name: $($wslDrive.task)"
    }
    $matches = $task -and $task.Description -eq $description -and $task.Actions.Count -eq 1 -and
        $task.Actions[0].Execute -ieq $executable -and $task.Actions[0].Arguments -ceq $arguments -and
        (Get-PrincipalSid $task.Principal.UserId) -eq $request.UserSid -and
        [string]$task.Principal.RunLevel -eq 'Highest' -and [string]$task.Principal.LogonType -eq 'Interactive' -and
        $task.Settings.Enabled -and $task.Settings.AllowDemandStart -and
        -not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries -and
        [string]$task.Settings.MultipleInstances -eq 'IgnoreNew' -and $task.Settings.ExecutionTimeLimit -eq 'PT1M'
    if (-not $wslTaskUnreadable -and -not $matches) {
        $operations.Add(@{ Kind='RegisterTask'; Name=$wslDrive.task; Executable=$executable;
            Arguments=$arguments; Description=$description })
    }
}

if ($Apply -and $operations.Count) {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $WhatIfPreference -and
        -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'System preparation requires an administrator process.'
    }
    foreach ($operation in $operations) {
        if (-not $PSCmdlet.ShouldProcess($operation.Kind, 'Apply planned system preparation')) { continue }
        switch ($operation.Kind) {
            DeveloperMode {
                $null = New-Item -Path $developerKey -Force
                Set-ItemProperty -LiteralPath $developerKey -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
            }
            CreateDrive {
                & (Join-Path $PSScriptRoot 'create_drive.ps1') -Path $operation.Path `
                    -SizeGiB $operation.SizeGiB -FileSystem $operation.FileSystem | Out-Null
            }
            AttachDrive {
                & (Join-Path $PSScriptRoot 'attach_drive.ps1') -Path $operation.Path `
                    -LegacyKey $request.LegacyKey -AllowDetach:([bool]$request.AllowDetach)
            }
            RegisterTask {
                $action = New-ScheduledTaskAction -Execute $operation.Executable -Argument $operation.Arguments
                $principal = New-ScheduledTaskPrincipal -UserId $request.UserSid -LogonType Interactive -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
                $null = Register-ScheduledTask -TaskName $operation.Name -TaskPath '\' -Action $action `
                    -Principal $principal -Settings $settings -Description $operation.Description -Force
            }
            default { throw "Unknown system preparation operation: $($operation.Kind)" }
        }
    }
}

$result = @{
    Pending = @($operations | ForEach-Object { $_.Kind })
    DeveloperMode = (Get-ItemProperty -LiteralPath $developerKey -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
}
$ansibleContext = Get-Variable -Name Ansible -ValueOnly -ErrorAction SilentlyContinue
if ($ansibleContext) {
    $ansibleContext.Changed = $Apply -and $operations.Count -gt 0
    $ansibleContext.Result = $result
}
$result
