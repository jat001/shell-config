[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WindowsHome = [Environment]::GetFolderPath('UserProfile'),
    [string]$Msys2Root,
    [string[]]$WslDistribution,
    [switch]$SkipMsys2,
    [switch]$SkipWsl,
    [switch]$WslDevDriveOnly,
    [Parameter(DontShow)]
    [switch]$RegisterWslDevDriveTaskOnly
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Run this installer from Windows PowerShell or PowerShell on Windows.'
}
if ($WslDevDriveOnly -and $SkipWsl) {
    throw '-WslDevDriveOnly cannot be combined with -SkipWsl.'
}

$repository = [IO.Path]::GetFullPath($PSScriptRoot)
$WindowsHome = [IO.Path]::GetFullPath($WindowsHome)
$utf8 = [Text.UTF8Encoding]::new($false)
$plans = [Collections.Generic.List[object]]::new()
$services = [Collections.Generic.List[object]]::new()

function Get-WslDevDriveTaskPlan {
    $configuration = [IO.File]::ReadAllText(
        (Join-Path $repository 'common.json')
    ) | ConvertFrom-Json
    $drive = $configuration.environments.wsl.dev_drive
    if (-not $drive) { return }

    foreach ($key in @('vhd', 'mountpoint', 'filesystem', 'uuid', 'task', 'schtasks')) {
        if (-not $drive.$key) { throw "Missing WSL development drive setting: $key" }
    }
    if ($drive.mountpoint -notmatch '^/[^\s]+/([A-Za-z0-9][A-Za-z0-9._-]*)$') {
        throw 'The WSL development drive mountpoint must be an absolute Linux path.'
    }
    $name = $Matches[1]
    if ($drive.filesystem -notmatch '^[a-z0-9]+$' -or
        $drive.uuid -notmatch '^[0-9a-fA-F-]{36}$' -or
        $drive.task -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' -or
        $drive.options -match '["\r\n]' -or $drive.vhd -match '["\r\n]') {
        throw 'Invalid WSL development drive configuration.'
    }

    $vhd = [IO.Path]::GetFullPath((Join-Path $WindowsHome $drive.vhd))
    if (-not [IO.File]::Exists($vhd)) {
        throw "Configured WSL development VHDX does not exist: $vhd"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $arguments = '--mount --vhd "{0}" --type {1} --name {2}' -f
        $vhd, $drive.filesystem, $name
    if ($drive.options) { $arguments += ' --options "{0}"' -f $drive.options }

    @{
        Name = $drive.task
        Execute = Join-Path $env:SystemRoot 'System32/wsl.exe'
        Arguments = $arguments
        UserId = $identity.User.Value
        Description = 'Shared shell configuration: attach the WSL development VHDX.'
    }
}

function Test-WslDevDriveTask {
    param($Plan)

    $existing = Get-ScheduledTask -TaskName $Plan.Name -TaskPath '\' `
        -ErrorAction SilentlyContinue
    if (-not $existing) { return $true }

    $actions = @($existing.Actions)
    $sameAction = $actions.Count -eq 1 -and
        $actions[0].Execute -eq $Plan.Execute -and
        $actions[0].Arguments -eq $Plan.Arguments
    if ($existing.Description -ne $Plan.Description -and -not $sameAction) {
        throw "An unrelated scheduled task already uses this name: $($Plan.Name)"
    }

    $userId = $existing.Principal.UserId
    if ($userId -notmatch '^S-1-') {
        $account = [Security.Principal.NTAccount]::new($userId)
        $userId = $account.Translate([Security.Principal.SecurityIdentifier]).Value
    }

    -not ($sameAction -and $userId -eq $Plan.UserId -and
        $existing.Principal.RunLevel -eq 'Highest' -and
        $existing.Principal.LogonType -eq 'Interactive' -and
        $existing.Settings.Enabled -and $existing.Settings.AllowDemandStart -and
        -not $existing.Settings.DisallowStartIfOnBatteries -and
        -not $existing.Settings.StopIfGoingOnBatteries -and
        $existing.Settings.MultipleInstances -eq 'IgnoreNew' -and
        $existing.Settings.ExecutionTimeLimit -eq 'PT1M')
}

function Register-WslDevDriveTask {
    param($Plan)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f
            (Join-Path $repository 'install.ps1')
        $arguments += ' -WindowsHome "{0}" -RegisterWslDevDriveTaskOnly' -f $WindowsHome
        $process = Start-Process -FilePath (
            Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        ) -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru -Wait
        if ($process.ExitCode -ne 0) {
            throw "Elevated scheduled task registration failed ($($process.ExitCode))."
        }
        return
    }

    $action = New-ScheduledTaskAction -Execute $Plan.Execute -Argument $Plan.Arguments
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $Plan.UserId `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $null = Register-ScheduledTask -TaskName $Plan.Name -TaskPath '\' `
        -Action $action -Principal $taskPrincipal -Settings $settings `
        -Description $Plan.Description -Force
}

if ($RegisterWslDevDriveTaskOnly) {
    $taskPlan = Get-WslDevDriveTaskPlan
    if ($taskPlan -and (Test-WslDevDriveTask $taskPlan) -and
        $PSCmdlet.ShouldProcess($taskPlan.Name, 'Register WSL development drive task')) {
        Register-WslDevDriveTask $taskPlan
    }
    return
}

$entries = @(
    @{
        Paths = @('.bash_profile', '.profile', '.bashrc')
        Content = '. "$HOME/.config/shell/common.bash"'
    }
    @{
        Paths = @('.blerc')
        Content = '. "$HOME/.config/shell/common.bash" ble'
    }
    @{
        Paths = @('.inputrc')
        Content = '$include ~/.config/shell/common.inputrc'
    }
    @{
        Paths = @('.zprofile')
        Content = '. "$HOME/.config/shell/common.zsh" environment'
    }
    @{
        Paths = @('.zshrc')
        Content = '. "$HOME/.config/shell/common.zsh"'
    }
    @{
        Paths = @('.config/fish/config.fish')
        Content = 'source "$HOME/.config/shell/common.fish"'
    }
    @{
        Paths = @(
            'Documents/PowerShell/Microsoft.PowerShell_profile.ps1'
            'Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1'
        )
        Unix = @('.config/powershell/Microsoft.PowerShell_profile.ps1')
        Msys = $false
        Content = '. "$HOME/.config/shell/common.ps1"'
    }
    @{
        Paths = @('AppData/Roaming/nushell/env.nu')
        Unix = @('.config/nushell/env.nu')
        Msys = $false
        Content = 'source ~/.config/shell/common-env.nu'
    }
    @{
        Paths = @('AppData/Roaming/nushell/config.nu')
        Unix = @('.config/nushell/config.nu')
        Msys = $false
        Content = 'source ~/.config/shell/common.nu'
    }
    @{
        Paths = @('AppData/Local/clink/profile.lua')
        Unix = @()
        Content = 'dofile(os.getenv("HOME") .. "/.config/shell/common.lua")'
    }
)

function Invoke-WslCommand {
    param($Distribution, [string[]]$Arguments, [switch]$AllowFailure)

    $output = & $wsl -d $Distribution --exec @Arguments
    $code = $LASTEXITCODE

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "WSL command failed in $Distribution ($code): $($Arguments[0])"
    }

    @{
        Code = $code
        Output = ($output -join [char]10).Replace([string][char]0, '').TrimEnd()
    }
}

function Get-PathState {
    param($Plan)

    if ($Plan.Distribution) {
        $result = Invoke-WslCommand $Plan.Distribution @(
            'test', '-L', $Plan.Path
        ) -AllowFailure

        if ($result.Code -eq 0) {
            $target = Invoke-WslCommand $Plan.Distribution @(
                'readlink', '--', $Plan.Path
            )
            return @{ Type = 'Link'; Target = $target.Output }
        }

        foreach ($kind in @('Directory', 'File')) {
            $flag = if ($kind -eq 'Directory') { '-d' } else { '-f' }
            $result = Invoke-WslCommand $Plan.Distribution @(
                'test', $flag, $Plan.Path
            ) -AllowFailure

            if ($result.Code -eq 0) {
                return @{ Type = $kind }
            }
        }

        return @{ Type = 'Missing' }
    }

    try {
        $item = Get-Item -LiteralPath $Plan.Path -Force
    } catch [Management.Automation.ItemNotFoundException] {
        return @{ Type = 'Missing' }
    }

    if ($item.LinkType -in @('SymbolicLink', 'Junction')) {
        $target = @($item.Target)[0]

        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $Plan.Path) $target
        }

        return @{
            Type = 'Link'
            Target = [IO.Path]::GetFullPath($target)
            Directory = $item.PSIsContainer
        }
    }

    @{ Type = $(if ($item.PSIsContainer) { 'Directory' } else { 'File' }) }
}

function Get-PlanContent {
    param($Plan)

    if ($Plan.Distribution) {
        $result = Invoke-WslCommand $Plan.Distribution @(
            'cat', '--', $Plan.Path
        )
        $content = $result.Output
    } else {
        $content = [IO.File]::ReadAllText($Plan.Path)
    }

    $content.Replace([string][char]13, '').TrimEnd([char]10)
}

function Test-Plan {
    param($Plan)

    if ($Plan.Type -eq 'Link' -and $Plan.Path -eq $Plan.Target) {
        return $false
    }

    $state = Get-PathState $Plan

    if ($state.Type -eq 'Missing') {
        return $true
    }

    if ($Plan.Kind -eq 'External') {
        if ($state.Type -eq 'Link' -and $state.Target -eq $Plan.Target) {
            return $false
        }
        throw "An existing path occupies a configured link: $($Plan.Path)"
    }

    if ($Plan.Type -eq 'Directory') {
        if ($state.Type -eq 'Directory' -or $state.Directory) {
            return $false
        }
        throw "A file occupies a directory destination: $($Plan.Path)"
    }

    if ($Plan.Type -eq 'File' -or $Plan.Kind -eq 'File') {
        if ($state.Type -eq 'Directory') {
            throw "A directory occupies a file destination: $($Plan.Path)"
        }

        if ($state.Type -eq 'Link' -and $state.Target -eq $Plan.Target) {
            return $false
        }

        if ((Get-PlanContent $Plan) -ne $Plan.Content) {
            throw "Existing file contains other configuration: $($Plan.Path)"
        }

        return $Plan.Type -eq 'Link'
    }

    if ($state.Type -eq 'Link') {
        return $state.Target -ne $Plan.Target
    }

    if ($state.Type -ne 'Directory') {
        throw "A file occupies a directory destination: $($Plan.Path)"
    }

    if ($Plan.Distribution) {
        $result = Invoke-WslCommand $Plan.Distribution @(
            'ls', '-A', '--', $Plan.Path
        )
        $occupied = $result.Output.Length -gt 0
    } else {
        $occupied = [IO.Directory]::GetFileSystemEntries($Plan.Path).Length -gt 0
    }

    if ($occupied) {
        throw "Existing directory is not empty: $($Plan.Path)"
    }

    return $true
}

function Add-LinkPlan {
    param($Path, $Target, $Kind, $Content, $Distribution)

    $plans.Add(@{
        Type = 'Link'
        Path = $Path
        Target = $Target
        Kind = $Kind
        Content = $Content
        Distribution = $Distribution
    })
}

function Add-SharedLayout {
    param($DestinationHome, $SourceHome, $SourceRepository, $Distribution)

    Add-LinkPlan "$DestinationHome/.config/shell" $SourceRepository `
        'Directory' $null $Distribution
    Add-LinkPlan "$DestinationHome/.config/oh-my-posh" `
        "$SourceRepository/oh-my-posh" 'Directory' $null $Distribution
    Add-LinkPlan "$DestinationHome/.zsh_plugins.txt" `
        "$SourceRepository/zsh_plugins.txt" 'File' $pluginContent $Distribution

    foreach ($directory in @('conf.d', 'functions', 'completions')) {
        Add-LinkPlan "$DestinationHome/.config/fish/$directory" `
            "$SourceHome/.config/fish/$directory" 'Directory' $null $Distribution
    }
}

function Add-UnixEntries {
    param($DestinationHome, $SourceHome, $Distribution, [switch]$Msys)

    foreach ($entry in $entries) {
        if ($Msys -and $entry.ContainsKey('Msys') -and -not $entry.Msys) {
            continue
        }

        $paths = @($entry.Paths)
        if ($entry.ContainsKey('Unix')) {
            $paths = @($entry.Unix)
        }

        for ($index = 0; $index -lt $paths.Count; $index++) {
            $source = if ($paths.Count -eq $entry.Paths.Count) {
                $entry.Paths[$index]
            } else {
                $entry.Paths[0]
            }

            Add-LinkPlan "$DestinationHome/$($paths[$index])" `
                "$SourceHome/$source" 'File' $entry.Content $Distribution
        }
    }
}

foreach ($required in @(
    'common.json', 'common.jq', 'zsh_plugins.txt'
    'oh-my-posh/config.omp.json'
    'oh-my-posh/shell-integration.omp.json'
    'oh-my-posh/msys2.omp.json'
    'oh-my-posh/msys2-fish.omp.json'
)) {
    if (-not [IO.File]::Exists((Join-Path $repository $required))) {
        throw "Required repository file is missing: $required"
    }
}

$pluginContent = [IO.File]::ReadAllText(
    (Join-Path $repository 'zsh_plugins.txt')
).Replace([string][char]13, '').TrimEnd([char]10)

foreach ($entry in $entries) {
    foreach ($path in $entry.Paths) {
        $plans.Add(@{
            Type = 'File'
            Path = Join-Path $WindowsHome $path
            Content = $entry.Content
        })
    }
}

foreach ($directory in @('conf.d', 'functions', 'completions')) {
    $plans.Add(@{
        Type = 'Directory'
        Path = "$WindowsHome/.config/fish/$directory"
    })
}

Add-LinkPlan "$WindowsHome/.config/shell" $repository 'Directory'
Add-LinkPlan "$WindowsHome/.config/oh-my-posh" "$repository/oh-my-posh" 'Directory'
Add-LinkPlan "$WindowsHome/.zsh_plugins.txt" "$repository/zsh_plugins.txt" `
    'File' $pluginContent
Add-LinkPlan "$WindowsHome/AppData/Local/clink/clink_settings" `
    "$repository/common.clink_settings" 'File' (
        [IO.File]::ReadAllText((Join-Path $repository 'common.clink_settings')).
            Replace([string][char]13, '').TrimEnd([char]10)
    )

if (-not $SkipMsys2 -and -not $WslDevDriveOnly) {
    if (-not $Msys2Root) {
        $configuration = [IO.File]::ReadAllText(
            (Join-Path $repository 'common.json')
        ) | ConvertFrom-Json
        $Msys2Root = $configuration.environments.msys2.root
        if (-not $Msys2Root) {
            throw 'Set environments.msys2.root or pass -Msys2Root.'
        }
    }

    $getent = Join-Path $Msys2Root 'usr/bin/getent.exe'
    $cygpath = Join-Path $Msys2Root 'usr/bin/cygpath.exe'

    if ([IO.File]::Exists($getent) -and [IO.File]::Exists($cygpath)) {
        $record = & $getent passwd $env:USERNAME
        if ($LASTEXITCODE -ne 0 -or -not $record) {
            throw 'Could not discover the MSYS2 home directory.'
        }

        $msysHome = & $cygpath -w ($record -split ':')[5]
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not convert the MSYS2 home directory.'
        }

        Add-SharedLayout $msysHome $WindowsHome $repository
        Add-UnixEntries $msysHome $WindowsHome -Msys
    } elseif ($Msys2Root) {
        throw "MSYS2 tools were not found under $Msys2Root"
    }
}

if (-not $SkipWsl) {
    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue

    if ($wslCommand) {
        $wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'

        if (-not $WslDistribution) {
            $registered = & $wsl --list --quiet
            if ($LASTEXITCODE -eq 0 -and $registered) {
                $WslDistribution = & $wsl --exec printenv WSL_DISTRO_NAME
                if ($LASTEXITCODE -ne 0) {
                    throw 'Could not discover the default WSL distribution.'
                }
            }
        }

        foreach ($distribution in $WslDistribution) {
            $distribution = $distribution.Replace([string][char]0, '').Trim()
            if (-not $distribution) { continue }

            $homeResult = Invoke-WslCommand $distribution @('printenv', 'HOME')
            $sourceHome = Invoke-WslCommand $distribution @(
                'wslpath', '-a', '-u', $WindowsHome
            )
            $sourceRepository = Invoke-WslCommand $distribution @(
                'wslpath', '-a', '-u', $repository
            )

            if (-not $WslDevDriveOnly) {
                Add-SharedLayout $homeResult.Output $sourceHome.Output `
                    $sourceRepository.Output $distribution
                Add-UnixEntries $homeResult.Output $sourceHome.Output $distribution

                $sharedResult = Invoke-WslCommand $distribution @(
                    'jq', '--arg', 'platform', 'wsl'
                    '--arg', 'home', $homeResult.Output
                    '--arg', 'mode', 'plan'
                    '-f', "$($sourceRepository.Output)/common.jq"
                    "$($sourceRepository.Output)/common.json"
                )
                $shared = $sharedResult.Output | ConvertFrom-Json

                foreach ($link in $shared.links.PSObject.Properties) {
                    if ($link.Name -notmatch '^/' -or $link.Value -notmatch '^/') {
                        throw "Configured link paths must be absolute: $($link.Name)"
                    }

                    $target = Invoke-WslCommand $distribution @(
                        'test', '-e', $link.Value
                    ) -AllowFailure
                    if ($target.Code -ne 0) {
                        throw "Configured link target does not exist: $($link.Value)"
                    }

                    Add-LinkPlan $link.Name $link.Value 'External' $null $distribution
                }
            } else {
                Add-LinkPlan "$($homeResult.Output)/.config/shell" `
                    $sourceRepository.Output 'Directory' $null $distribution
            }

            $unitDirectory = Join-Path $repository 'systemd'
            if (-not [IO.Directory]::Exists($unitDirectory)) { continue }

            $unitExtensions = @('.service', '.socket', '.timer', '.path', '.target')

            foreach ($unit in Get-ChildItem -LiteralPath $unitDirectory -File) {
                if ($unit.Extension -notin $unitExtensions) { continue }
                if ($WslDevDriveOnly -and $unit.Name -ne 'wsl-dev-drive.service') {
                    continue
                }

                $content = [IO.File]::ReadAllText($unit.FullName).
                    Replace([string][char]13, '').TrimEnd([char]10)
                $linkArguments = @(
                    "$($homeResult.Output)/.config/systemd/user/$($unit.Name)"
                    "$($sourceRepository.Output)/systemd/$($unit.Name)"
                    'File'
                    $content
                    $distribution
                )

                Add-LinkPlan @linkArguments

                if ($content -match '(?m)^\[Install\]\s*$' -and
                    $unit.BaseName -notmatch '@$') {
                    $services.Add(@{
                        Distribution = $distribution
                        Name = $unit.Name
                    })
                }
            }
        }
    } elseif ($WslDistribution) {
        throw 'wsl.exe was not found.'
    }
}

if ($WslDevDriveOnly) {
    $plans = @($plans | Where-Object { $_.Distribution })
}

foreach ($plan in $plans) {
    if (-not $plan.Distribution) {
        $plan.Path = [IO.Path]::GetFullPath($plan.Path)
        if ($plan.Target) {
            $plan.Target = [IO.Path]::GetFullPath($plan.Target)
        }
    }
    $plan.Change = Test-Plan $plan
}

$taskPlan = if (-not $SkipWsl -and $WslDistribution) {
    Get-WslDevDriveTaskPlan
}
if ($taskPlan) { $taskPlan.Change = Test-WslDevDriveTask $taskPlan }
if ($WslDevDriveOnly -and -not $taskPlan) {
    throw 'No WSL development drive or target distribution is configured.'
}

$applied = 0

if ($taskPlan -and $taskPlan.Change -and $PSCmdlet.ShouldProcess(
    $taskPlan.Name, 'Register WSL development drive task'
)) {
    Register-WslDevDriveTask $taskPlan
    $applied++
}

foreach ($plan in $plans) {
    if (-not $plan.Change) { continue }

    $label = if ($plan.Distribution) {
        "$($plan.Distribution):$($plan.Path)"
    } else {
        $plan.Path
    }

    if (-not $PSCmdlet.ShouldProcess($label, "Install $($plan.Type)")) {
        continue
    }

    if ($plan.Distribution) {
        $parent = $plan.Path.Substring(0, $plan.Path.LastIndexOf('/'))
        $null = Invoke-WslCommand $plan.Distribution @('mkdir', '-p', '--', $parent)
        $state = Get-PathState $plan

        if ($state.Type -eq 'Directory') {
            $null = Invoke-WslCommand $plan.Distribution @('rmdir', '--', $plan.Path)
        } elseif ($state.Type -ne 'Missing') {
            $null = Invoke-WslCommand $plan.Distribution @('rm', '--', $plan.Path)
        }

        $null = Invoke-WslCommand $plan.Distribution @(
            'ln', '-s', '--', $plan.Target, $plan.Path
        )
    } else {
        $parent = Split-Path $plan.Path
        $null = [IO.Directory]::CreateDirectory($parent)

        if ($plan.Type -eq 'Directory') {
            $null = [IO.Directory]::CreateDirectory($plan.Path)
        } elseif ($plan.Type -eq 'File') {
            [IO.File]::WriteAllText($plan.Path, $plan.Content + [char]10, $utf8)
        } else {
            $state = Get-PathState $plan

            if ($state.Type -eq 'Directory' -or $state.Directory) {
                [IO.Directory]::Delete($plan.Path)
            } elseif ($state.Type -ne 'Missing') {
                [IO.File]::Delete($plan.Path)
            }

            try {
                $null = New-Item -ItemType SymbolicLink -Path $plan.Path `
                    -Target $plan.Target
            } catch {
                if ($state.Type -eq 'File') {
                    [IO.File]::WriteAllText(
                        $plan.Path, $plan.Content + [char]10, $utf8
                    )
                } elseif ($state.Type -eq 'Link') {
                    $null = New-Item -ItemType SymbolicLink -Path $plan.Path `
                        -Target $state.Target
                } elseif ($state.Type -eq 'Directory') {
                    $null = [IO.Directory]::CreateDirectory($plan.Path)
                }
                throw
            }
        }
    }

    $applied++
}

if (-not $WslDevDriveOnly -and
    $WindowsHome -eq [Environment]::GetFolderPath('UserProfile')) {
    $currentHome = [Environment]::GetEnvironmentVariable('HOME', 'User')
    if ($currentHome -ne $WindowsHome -and $PSCmdlet.ShouldProcess(
        'User:HOME', "Set HOME to $WindowsHome"
    )) {
        [Environment]::SetEnvironmentVariable('HOME', $WindowsHome, 'User')
        $env:HOME = $WindowsHome
    }
}

foreach ($group in ($services | Group-Object -Property { $_.Distribution })) {
    $distribution = $group.Name
    $enable = [Collections.Generic.List[string]]::new()
    $restart = [Collections.Generic.List[string]]::new()

    foreach ($service in $group.Group) {
        $name = $service.Name
        $active = Invoke-WslCommand $distribution @(
            'systemctl', '--user', 'is-active', '--quiet', $name
        ) -AllowFailure

        if ($active.Code -ne 0) {
            $enable.Add($name)
            continue
        }

        $enabled = Invoke-WslCommand $distribution @(
            'systemctl', '--user', 'is-enabled', '--quiet', $name
        ) -AllowFailure
        $reload = Invoke-WslCommand $distribution @(
            'systemctl', '--user', 'show', $name
            '-p', 'NeedDaemonReload', '--value'
        )

        if ($enabled.Code -ne 0 -or $reload.Output -eq 'yes') {
            $enable.Add($name)
        }
        if ($reload.Output -eq 'yes') {
            $restart.Add($name)
        }
    }

    if (-not $enable.Count) { continue }

    if ($PSCmdlet.ShouldProcess(
        "$($distribution):$($enable -join ', ')", 'Enable and start user units'
    )) {
        $null = Invoke-WslCommand $distribution @(
            'systemctl', '--user', 'daemon-reload'
        )
        $arguments = @('systemctl', '--user', 'enable', '--now') + $enable.ToArray()
        $null = Invoke-WslCommand $distribution $arguments

        if ($restart.Count) {
            $arguments = @('systemctl', '--user', 'restart') + $restart.ToArray()
            $null = Invoke-WslCommand $distribution $arguments
        }
    }
}

$global:LASTEXITCODE = 0
$pending = @($plans | Where-Object { $_.Change }).Count
if ($taskPlan -and $taskPlan.Change) { $pending++ }
Write-Output "Installed $applied change(s); planned $pending change(s)."
