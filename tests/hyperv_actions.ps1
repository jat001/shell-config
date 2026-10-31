param([hashtable]$Context, [object]$Request)

$ErrorActionPreference = 'Stop'
$StateDirectory = $Context.StateDirectory
$Repository = $Context.Repository
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-TestVm {
    $identity = [IO.File]::ReadAllText((Join-Path $StateDirectory 'vm-created.json')) | ConvertFrom-Json
    if ($Context.VmId -and $Context.VmId -ne $identity.Id) { throw 'VM identity file changed.' }
    $vm = Get-VM -Name $identity.Name
    if ([string]$vm.Id -ne $identity.Id) { throw 'Unexpected VM identity.' }
    $Context.VmId = $identity.Id
    $Context.VmName = $identity.Name
    $vm
}

function Connect-Guest {
    if (-not $Context.Session -or $Context.Session.State -ne 'Opened') {
        if ($Context.Session) { Remove-PSSession $Context.Session -ErrorAction SilentlyContinue }
        $credential = Import-Clixml (Join-Path $StateDirectory 'guest-credential.xml')
        $Context.Session = New-PSSession -VMName $Context.VmName -Credential $credential
    }
}

function Write-GuestFile {
    param([string]$Path, [byte[]]$Bytes)
    $encoded = [Convert]::ToBase64String($Bytes)
    Invoke-Command -Session $Context.Session -ArgumentList $Path, $encoded -ScriptBlock {
        param($Path, $Encoded)
        $bytes = [Convert]::FromBase64String($Encoded)
        if ([IO.File]::Exists($Path) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -ceq $Encoded) { return }
        $parent = Split-Path -Parent $Path
        if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
}

function Copy-Logs {
    Connect-Guest
    $destination = Join-Path $StateDirectory 'guest-logs'
    [void][IO.Directory]::CreateDirectory($destination)
    $paths = Invoke-Command -Session $Context.Session -ScriptBlock {
        $files = @(Get-ChildItem C:\shell-test -File -ErrorAction SilentlyContinue)
        $files += @(Get-ChildItem C:\shell-test\operations -Recurse -File -ErrorAction SilentlyContinue)
        $files | Where-Object Extension -In @('.log', '.out', '.err', '.json', '.txt') | ForEach-Object FullName
    }
    foreach ($path in $paths) {
        $encoded = Invoke-Command -Session $Context.Session -ArgumentList $path -ScriptBlock {
            param($Path)
            $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); [Convert]::ToBase64String($memory.ToArray()) }
            finally { $stream.Dispose(); $memory.Dispose() }
        }
        $target = Join-Path $destination $path.Substring('C:\shell-test\'.Length)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($encoded))
    }
}

function Copy-Cache {
    param([ValidateSet('ToGuest','FromGuest')][string]$Direction)
    Connect-Guest
    $cache = Join-Path $StateDirectory 'cache/downloads'
    [void][IO.Directory]::CreateDirectory($cache)
    $remote = 'C:\shell-cache'
    if ($Direction -eq 'ToGuest') {
        foreach ($file in Get-ChildItem -LiteralPath $cache -Recurse -File) {
            $relative = $file.FullName.Substring($cache.Length + 1)
            $target = Join-Path $remote $relative
            $needed = Invoke-Command -Session $Context.Session -ArgumentList $target,$file.Length -ScriptBlock {
                param($Path,$Length)
                if ([IO.File]::Exists($Path) -and (Get-Item -LiteralPath $Path).Length -eq $Length) { return $false }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
                $true
            }
            if ($needed) {
                $partial = $target + '.' + [guid]::NewGuid().ToString('N') + '.part'
                Copy-Item -ToSession $Context.Session -LiteralPath $file.FullName -Destination $partial
                Invoke-Command -Session $Context.Session -ArgumentList $partial, $target -ScriptBlock {
                    param($Partial, $Target)
                    Move-Item -LiteralPath $Partial -Destination $Target -Force
                }
            }
        }
    } else {
        $files = Invoke-Command -Session $Context.Session -ScriptBlock {
            Get-ChildItem C:\shell-cache -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object Name -NotLike '*.part' |
                Where-Object {
                    if ($_.Extension -ne '.wsl') { return $true }
                    $stream = [IO.File]::OpenRead($_.FullName)
                    try {
                        $buffer = New-Object byte[] 256
                        $count = $stream.Read($buffer,0,$buffer.Length)
                        $prefix = [Text.Encoding]::UTF8.GetString($buffer,0,$count)
                        $prefix -notmatch '(?is)^\s*(<!doctype\s+html|<html)'
                    } finally { $stream.Dispose() }
                } | Select-Object FullName,Length
        }
        foreach ($file in $files) {
            $target = Join-Path $cache $file.FullName.Substring($remote.Length + 1)
            if ([IO.File]::Exists($target) -and (Get-Item -LiteralPath $target).Length -eq $file.Length) { continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -FromSession $Context.Session -LiteralPath $file.FullName -Destination $target -Force
        }
    }
}

function Set-GuestLogon {
    param([ValidateSet('Enable', 'Clear')][string]$Action)
    Connect-Guest
    $definition = [IO.File]::ReadAllText((Join-Path $Repository 'tests/hyperv_logon.ps1'))
    if ($Action -eq 'Enable') {
        $credential = Import-Clixml (Join-Path $StateDirectory 'guest-credential.xml')
        $parameters = @{
            Action = 'Enable'; UserName = $credential.UserName
            Password = $credential.GetNetworkCredential().Password; Count = $Request.AutoLogonCount
        }
        $Context.AutoLogon = $true
    } else { $parameters = @{ Action = 'Clear' } }
    $result = Invoke-Command -Session $Context.Session -ArgumentList $definition, $parameters -ScriptBlock {
        param($Definition, $Parameters)
        & ([scriptblock]::Create($Definition)) @Parameters
    }
    if ($Action -eq 'Clear') { $Context.AutoLogon = $false }
    [IO.File]::WriteAllText((Join-Path $StateDirectory 'logon.json'), ($result | ConvertTo-Json), $utf8)
    $result
}

function Start-GuestCommand {
    param([string]$Script, [string]$Arguments)
    Connect-Guest
    $directory = 'C:\shell-test\operations\' + $Request.Id
    Write-GuestFile (Join-Path $directory 'script.ps1') ([Convert]::FromBase64String($Script))
    Write-GuestFile (Join-Path $directory 'arguments.clixml') ($utf8.GetBytes($Arguments))
    Write-GuestFile (Join-Path $directory 'run.ps1') (
        [IO.File]::ReadAllBytes((Join-Path $Repository 'tests/hyperv_guest_command.ps1'))
    )
    $process = Invoke-Command -Session $Context.Session -ArgumentList $directory -ScriptBlock {
        param($Directory)
        $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Directory 'run.ps1'),
            '-Directory', $Directory
        ) -RedirectStandardOutput (Join-Path $Directory 'stdout.log') -RedirectStandardError (Join-Path $Directory 'stderr.log')
        @{ Pid = $process.Id; Started = $process.StartTime.ToUniversalTime().ToString('o') }
    }
    $job = @{
        Id = $Request.Id; Type = 'Guest'; Pid = $process.Pid; Started = $process.Started
        ResultPath = Join-Path $directory 'result.json'; Directory = $directory
    }
    $Context.Jobs[$Request.Id] = $job
    $job
}

function Update-Jobs {
    if (-not $Context.Jobs.Count) { return }
    Connect-Guest
    foreach ($id in @($Context.Jobs.Keys)) {
        $job = $Context.Jobs[$id]
        $progress = Invoke-Command -Session $Context.Session -ArgumentList $job -ScriptBlock {
            param($Job)
            $process = Get-Process -Id $Job.Pid -ErrorAction SilentlyContinue
            $running = $process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $Job.Started
            $state = @{ OperationId = $Job.Id; Type = $Job.Type; Running = [bool]$running }
            if ($Job.Type -eq 'Run') {
                $log = Get-ChildItem C:\shell-test\deploy-*.log -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $state.Log = $log.Name
                $state.Tail = if ($log) { @(Get-Content -LiteralPath $log.FullName -Tail 12) } else { @() }
            }
            if (-not $running -and [IO.File]::Exists($Job.ResultPath)) {
                $state.Result = [IO.File]::ReadAllText($Job.ResultPath) | ConvertFrom-Json
                $state.Success = $state.Result.Success -eq $true
            }
            $state
        }
        $path = Join-Path $StateDirectory ('operations/' + $id + '.progress.json')
        [IO.File]::WriteAllText($path, ($progress | ConvertTo-Json -Depth 10), $utf8)
        if ($job.Type -eq 'Run') {
            [IO.File]::WriteAllText((Join-Path $StateDirectory 'progress.json'), ($progress | ConvertTo-Json -Depth 10), $utf8)
        }
        if (-not $progress.Running) {
            $Context.Jobs.Remove($id)
            $timeout = if ($Context.IdleTimeoutMinutes) { $Context.IdleTimeoutMinutes } else { 120 }
            $Context.IdleUntil = (Get-Date).AddMinutes($timeout)
            Copy-Logs
        }
    }
    $errorPath = Join-Path $StateDirectory 'progress-error.txt'
    if ([IO.File]::Exists($errorPath)) { [IO.File]::Delete($errorPath) }
}

if ($Request.Action -in @('Stop', 'Disconnect')) {
    if ($Request.Action -eq 'Stop' -and $Context.Jobs.Count) { throw 'Wait for guest jobs before stopping the worker.' }
    if ($Context.AutoLogon) { $null = Assert-TestVm; $null = Set-GuestLogon Clear }
    $Context.Stop = $true
    return
}
if ($Request.Action -eq 'Prepare') {
    if ($Context.Jobs.Count) { throw 'Wait for guest jobs before preparing the VM.' }
    & (Join-Path $Repository 'tests/hyperv_prepare.ps1') -Stage $Request.PreparationStage `
        -StateDirectory $StateDirectory -Repository $Repository -IsoSource $Request.IsoSource `
        -IsoSha256 $Request.IsoSha256 -IsoLanguage $Request.IsoLanguage
    return
}
if ($Request.Action -eq 'Poll' -and -not $Context.Jobs.Count) { return }
$vm = Assert-TestVm
$result = @{ HandlerHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash }
switch ($Request.Action) {
    'Poll' { Update-Jobs; return }
    'Status' {
        $result.VM = @{ Name = $vm.Name; Id = [string]$vm.Id; State = [string]$vm.State }
        $result.Worker = $Context.Instance
        $result.Jobs = @($Context.Jobs.Values)
        Connect-Guest
        $result.Guest = Invoke-Command -Session $Context.Session -ScriptBlock {
            $verificationPath = 'C:\shell-test\verification-result.json'
            $verification = if ([IO.File]::Exists($verificationPath)) {
                @{ Modified = (Get-Item -LiteralPath $verificationPath).LastWriteTimeUtc.ToString('o')
                    Result = [IO.File]::ReadAllText($verificationPath) | ConvertFrom-Json }
            }
            $taskState = $null
            $taskResult = $null
            try {
                $task = Get-ScheduledTask -TaskName 'Shell Config Verify Once' -ErrorAction Stop
                $taskState = [string]$task.State
                $taskResult = (Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction Stop).LastTaskResult
            } catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
                if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
                # A one-shot verification can unregister itself between the query and the info read.
            }
            $login = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            @{ Computer = $env:COMPUTERNAME; BootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                Verification = $verification; AutoLogonEnabled = $login.AutoAdminLogon -eq '1'
                RegistryPasswordPresent = [bool]$login.DefaultPassword; TaskState = $taskState; TaskResult = $taskResult
                Processes = @(Get-Process explorer, WindowsTerminal, consent, powershell -ErrorAction SilentlyContinue |
                    Select-Object Name, Id, SessionId) }
        }
        [IO.File]::WriteAllText((Join-Path $StateDirectory 'health.json'), ($result | ConvertTo-Json -Depth 10), $utf8)
    }
    'Collect' { Copy-Logs; Copy-Cache -Direction FromGuest }
    'Sync' {
        if ($Context.Jobs.Count) { throw 'Wait for guest jobs before synchronizing source.' }
        Connect-Guest
        $target = Invoke-Command -Session $Context.Session -ScriptBlock {
            $path = Join-Path $env:USERPROFILE '.config/shell'
            [void][IO.Directory]::CreateDirectory($path)
            $path
        }
        $files = & git.exe -C $Repository ls-files --cached --others --exclude-standard
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate repository files.' }
        foreach ($relative in $files) {
            $source = Join-Path $Repository $relative
            if (-not [IO.File]::Exists($source)) { continue }
            Write-GuestFile (Join-Path $target ($relative -replace '/', '\')) ([IO.File]::ReadAllBytes($source))
        }
        Copy-Cache -Direction ToGuest
        Write-GuestFile 'C:\shell-test\run-deployment.ps1' (
            [IO.File]::ReadAllBytes((Join-Path $Repository 'tests/hyperv_guest.ps1'))
        )
    }
    { $_ -in @('Restore', 'ColdBoot') } {
        if ($Context.Jobs.Count) { throw 'Wait for guest jobs before changing VM state.' }
        if ($Context.Session) { Remove-PSSession $Context.Session; $Context.Session = $null }
        if ($vm.State -ne 'Off') { Stop-VM -Name $Context.VmName -TurnOff -Force -Confirm:$false }
        if ($Request.Action -eq 'Restore') {
            if ($Request.Baseline -notin @('Clean-Windows', 'WSL-Ready')) { throw 'Invalid baseline.' }
            Restore-VMSnapshot -VMName $Context.VmName -Name $Request.Baseline -Confirm:$false
        }
        if ((Get-VM -Name $Context.VmName).State -ne 'Running') { Start-VM -Name $Context.VmName }
    }
    'EnableLogon' { $result.Logon = Set-GuestLogon Enable }
    'ClearLogon' { $result.Logon = Set-GuestLogon Clear }
    'Guest' {
        if (-not $Request.Script -or -not $Request.Arguments) { throw 'Guest script payload is missing.' }
        $result.Job = Start-GuestCommand $Request.Script $Request.Arguments
    }
    'Run' {
        if (@($Context.Jobs.Values | Where-Object Type -eq 'Run').Count) { throw 'Deployment is already running.' }
        if (-not $Request.Modes.Count -or @($Request.Modes | Where-Object { $_ -notin @('init', 'full', 'update') }).Count) {
            throw 'Invalid deployment modes.'
        }
        Connect-Guest
        $process = Invoke-Command -Session $Context.Session -ArgumentList ($Request.Modes -join ','), $Request.Id -ScriptBlock {
            param($Modes, $Id)
            [IO.File]::WriteAllText('C:\shell-test\result.json', (@{ OperationId = $Id; Running = $true } | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false))
            $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\shell-test\run-deployment.ps1', '-Modes', $Modes
            ) -RedirectStandardOutput C:\shell-test\deploy-run.out -RedirectStandardError C:\shell-test\deploy-run.err
            @{ Pid = $process.Id; Started = $process.StartTime.ToUniversalTime().ToString('o') }
        }
        $job = @{ Id = $Request.Id; Type = 'Run'; Pid = $process.Pid; Started = $process.Started
            ResultPath = 'C:\shell-test\result.json' }
        $Context.Jobs[$Request.Id] = $job
        $result.Job = $job
        [IO.File]::WriteAllText((Join-Path $StateDirectory 'progress.json'),
            (@{ OperationId = $Request.Id; Running = $true } | ConvertTo-Json), $utf8)
    }
    default { throw 'Unsupported operation.' }
}
$result
