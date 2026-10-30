[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Prepare','Start','Worker','Sync','Run','Collect','Status','Restore','Stop')][string]$Action = 'Start',
    [string]$StateDirectory = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/shell-ansible-test/hyperv'),
    [string]$Repository,
    [ValidateSet('init','full','update')][string[]]$Modes = @('init','full','full','update'),
    [ValidateSet('Clean-Windows','WSL-Ready')][string]$Baseline = 'WSL-Ready',
    [string]$IsoSource,
    [string]$IsoSha256,
    [string]$IsoLanguage = (Get-Culture).Name
)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$Repository = [IO.Path]::GetFullPath($Repository)
if ($Action -eq 'Prepare') {
    & (Join-Path $PSScriptRoot 'hyperv_prepare.ps1') -StateDirectory $StateDirectory -Repository $Repository `
        -IsoSource $IsoSource -IsoSha256 $IsoSha256 -IsoLanguage $IsoLanguage -WhatIf:$WhatIfPreference
    return
}
if (-not $PSCmdlet.ShouldProcess('Hyper-V test environment', $Action)) { return }
$requestPath = Join-Path $StateDirectory 'request.json'
$workerPath = Join-Path $StateDirectory 'worker.json'
$identity = [IO.File]::ReadAllText((Join-Path $StateDirectory 'vm-created.json')) | ConvertFrom-Json
$vmName = $identity.Name
$utf8 = [Text.UTF8Encoding]::new($false)

# Start is the only action that elevates. Later actions only queue a file for that worker.
if ($Action -eq 'Start') {
    if ([IO.File]::Exists($workerPath)) {
        $worker = [IO.File]::ReadAllText($workerPath) | ConvertFrom-Json
        if (Get-Process -Id $worker.Pid -ErrorAction SilentlyContinue) { 'Worker already running.'; return }
    }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),
            '-Action','Worker','-StateDirectory',('"'+$StateDirectory+'"'),'-Repository',('"'+$Repository+'"')
        )
    "Worker starting: $($process.Id)"
    return
}

if ($Action -ne 'Worker') {
    if ([IO.File]::Exists($requestPath)) { throw 'Another operation is queued.' }
    $request = @{ Id=[guid]::NewGuid().ToString(); Action=$Action; Modes=$Modes; Baseline=$Baseline }
    $temporary = $requestPath + '.tmp'
    [IO.File]::WriteAllText($temporary,($request | ConvertTo-Json),$utf8)
    [IO.File]::Move($temporary,$requestPath)
    "Queued $Action : $($request.Id)"
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Worker requires elevation.' }
# The name is not enough. A different VM that reused the name is refused instead of receiving this deployment.
if ([string](Get-VM -Name $vmName).Id -ne $identity.Id) { throw 'Unexpected VM identity.' }
$credential = Import-Clixml (Join-Path $StateDirectory 'guest-credential.xml')
$resultDirectory = Join-Path $StateDirectory 'operations'
[void][IO.Directory]::CreateDirectory($resultDirectory)
[IO.File]::WriteAllText($workerPath,(@{Pid=$PID;VM=$vmName;Expires=(Get-Date).AddHours(2)}|ConvertTo-Json),$utf8)
$deadline = (Get-Date).AddHours(2)
$session = $null
$jobPid = $null

function Connect-Guest {
    if (-not $script:session -or $script:session.State -ne 'Opened') {
        $script:session = New-PSSession -VMName $vmName -Credential $credential
    }
}

function Copy-Logs {
    Connect-Guest
    $destination = Join-Path $StateDirectory 'guest-logs'
    [void][IO.Directory]::CreateDirectory($destination)
    $paths = Invoke-Command -Session $session -ScriptBlock {
        Get-ChildItem C:\shell-test -File -ErrorAction SilentlyContinue |
            Where-Object Extension -In @('.log','.out','.err','.json','.txt','.ps1') |
            ForEach-Object FullName
    }
    foreach ($path in $paths) { Copy-Item -FromSession $session -LiteralPath $path -Destination $destination -Force }
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
            $needed = Invoke-Command -Session $session -ArgumentList $target,$file.Length -ScriptBlock {
                param($Path,$Length)
                if ([IO.File]::Exists($Path) -and (Get-Item -LiteralPath $Path).Length -eq $Length) { return $false }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
                $true
            }
            if ($needed) { Copy-Item -ToSession $session -LiteralPath $file.FullName -Destination $target -Force }
        }
    } else {
        $files = Invoke-Command -Session $session -ScriptBlock {
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
            Copy-Item -FromSession $session -LiteralPath $file.FullName -Destination $target -Force
        }
    }
}
try {
    while ((Get-Date) -lt $deadline) {
        if ([IO.File]::Exists($requestPath)) {
            $request = [IO.File]::ReadAllText($requestPath) | ConvertFrom-Json
            [IO.File]::Delete($requestPath)
            $result = @{Id=$request.Id;Action=$request.Action;Success=$false}
            try {
                if ($request.Id -notmatch '^[0-9a-f-]{36}$') { throw 'Invalid operation ID.' }
                if ([string](Get-VM -Name $vmName).Id -ne $identity.Id) { throw 'VM identity changed.' }
                switch ($request.Action) {
                    'Stop' { $deadline=Get-Date }
                    'Status' {
                        Connect-Guest
                        $health = Invoke-Command -Session $session -ScriptBlock {
                            $verification = if ([IO.File]::Exists('C:\shell-test\verification-result.json')) {
                                [IO.File]::ReadAllText('C:\shell-test\verification-result.json') | ConvertFrom-Json
                            }
                            $task = Get-ScheduledTask -TaskName 'Shell Config Verify Once' -ErrorAction SilentlyContinue
                            @{
                                Computer = $env:COMPUTERNAME
                                Verification = $verification
                                TaskState = [string]$task.State
                                TaskResult = $(if ($task) { (Get-ScheduledTaskInfo $task).LastTaskResult })
                                Processes = @(Get-Process -Name explorer,WindowsTerminal,consent,powershell -ErrorAction SilentlyContinue |
                                    Select-Object Name,Id,SessionId)
                            }
                        }
                        [IO.File]::WriteAllText((Join-Path $StateDirectory 'health.json'),($health|ConvertTo-Json -Depth 8),$utf8)
                    }
                    'Collect' { Copy-Logs; Copy-Cache -Direction FromGuest }
                    'Sync' {
                        Connect-Guest
                        $target = Invoke-Command -Session $session -ScriptBlock {
                            $path=Join-Path $env:USERPROFILE '.config/shell'
                            [void][IO.Directory]::CreateDirectory($path)
                            $path
                        }
                        $files = & git.exe -C $Repository ls-files --cached --others --exclude-standard
                        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate repository files.' }
                        foreach ($relative in $files) {
                            $source = Join-Path $Repository $relative
                            $destination = Join-Path $target ($relative -replace '/', '\')
                            # ArgumentList unwraps a byte array into separate arguments. A string does not.
                            # Copy-Item -ToSession also leaves an existing guest file unchanged.
                            $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
                            Invoke-Command -Session $session -ArgumentList $destination, $encoded -ScriptBlock {
                                param($Path, $Encoded)
                                $parent = Split-Path -Parent $Path
                                if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
                                [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($Encoded))
                            }
                        }
                        $updated = Invoke-Command -Session $session -ScriptBlock {
                            Select-String -LiteralPath (Join-Path $env:USERPROFILE '.config\shell\install.ps1') `
                                -Pattern 'start-sshd.sh' -SimpleMatch -Quiet
                        }
                        if (-not $updated) { throw 'Guest installer was not updated.' }
                        Copy-Cache -Direction ToGuest
                        Invoke-Command -Session $session -ArgumentList $target -ScriptBlock {
                            param($Repository)
                            Copy-Item -LiteralPath (Join-Path $Repository 'tests/hyperv_guest.ps1') -Destination C:\shell-test\run-deployment.ps1 -Force
                        }
                    }
                    'Restore' {
                        # Restoring discards every guest change made after that snapshot, including a deployment in progress.
                        if ($request.Baseline -notin @('Clean-Windows','WSL-Ready')) { throw 'Invalid baseline.' }
                        if ($jobPid) { throw 'Wait for the current deployment to finish.' }
                        if ($session) { Remove-PSSession $session; $session=$null }
                        Stop-VM -Name $vmName
                        Restore-VMSnapshot -VMName $vmName -Name $request.Baseline -Confirm:$false
                        Start-VM -Name $vmName
                    }
                    'Run' {
                        if ($jobPid) { throw 'Deployment is already running.' }
                        if (@($request.Modes | Where-Object { $_ -notin @('init','full','update') }).Count) { throw 'Invalid mode.' }
                        Connect-Guest
                        $jobPid = [int](Invoke-Command -Session $session -ArgumentList ($request.Modes -join ',') -ScriptBlock {
                            param($Modes)
                            $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
                                '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\shell-test\run-deployment.ps1','-Modes',$Modes
                            ) -RedirectStandardOutput C:\shell-test\deploy-run.out -RedirectStandardError C:\shell-test\deploy-run.err
                            $p.Id
                        })
                        $result.Pid=$jobPid
                    }
                    default { throw 'Unsupported operation.' }
                }
                $result.Success=$true
            } catch { $result.Error=$_.Exception.Message }
            [IO.File]::WriteAllText((Join-Path $resultDirectory ($request.Id+'.json')),($result|ConvertTo-Json),$utf8)
        }
        if ($jobPid) {
            try {
                Connect-Guest
                $progress=Invoke-Command -Session $session -ArgumentList $jobPid -ScriptBlock {
                    param($Id)
                    $log=Get-ChildItem C:\shell-test\deploy-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    @{Running=[bool](Get-Process -Id $Id -ErrorAction SilentlyContinue);Log=$log.Name;
                      Tail=@(Get-Content -LiteralPath $log.FullName -Tail 12 | ForEach-Object { $_.ToString() })}
                }
                [IO.File]::WriteAllText((Join-Path $StateDirectory 'progress.json'),($progress|ConvertTo-Json -Depth 4),$utf8)
                if (-not $progress.Running) {
                    $jobPid=$null
                    Copy-Logs
                    Copy-Cache -Direction FromGuest
                }
            } catch { [IO.File]::WriteAllText((Join-Path $StateDirectory 'progress-error.txt'),$_.Exception.Message,$utf8) }
        }
        Start-Sleep -Seconds 3
    }
} finally {
    if ($session) { Remove-PSSession $session }
    if ([IO.File]::Exists($workerPath)) { [IO.File]::Delete($workerPath) }
}
