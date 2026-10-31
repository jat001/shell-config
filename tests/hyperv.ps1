[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Prepare', 'Start', 'Worker', 'Sync', 'Run', 'Guest', 'Collect', 'Status',
        'Restore', 'ColdBoot', 'EnableLogon', 'ClearLogon', 'Stop')]
    [string]$Action = 'Start',
    [string]$StateDirectory = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/shell-ansible-test/hyperv'),
    [string]$Repository,
    [ValidateSet('init', 'full', 'update')][string[]]$Modes = @('init', 'full', 'full', 'update'),
    [ValidateSet('Clean-Windows', 'WSL-Ready')][string]$Baseline = 'WSL-Ready',
    [string]$ScriptPath,
    [hashtable]$ScriptArguments = @{},
    [ValidateRange(1, 10)][int]$AutoLogonCount = 2,
    [ValidateRange(1, 480)][int]$IdleTimeoutMinutes = 120,
    [ValidateSet('All', 'Host', 'Create', 'Baselines')][string]$PreparationStage = 'All',
    [string]$IsoSource,
    [string]$IsoSha256,
    [string]$IsoLanguage = (Get-Culture).Name
)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$Repository = [IO.Path]::GetFullPath($Repository)
$workerPath = Join-Path $StateDirectory 'worker.json'
$handlerPath = Join-Path $Repository 'tests/hyperv_actions.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-HypervWorker {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $stream = $null
        $reader = $null
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($Path, 'Open', 'Read', $share)
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            $record = $reader.ReadToEnd() | ConvertFrom-Json
            break
        } catch [IO.IOException] {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 25
        } finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
    }
    $process = Get-Process -Id $record.Pid -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -notin @('powershell', 'pwsh')) { return }
    if (-not $record.Instance -or -not $record.Started) {
        throw 'The old worker is still running. Stop it before starting this version.'
    }
    $started = ([DateTimeOffset]$record.Started).UtcDateTime.ToString('o')
    if ($process.StartTime.ToUniversalTime().ToString('o') -ne $started) { return }
    $record
}

function Invoke-HypervOperation {
    param([hashtable]$Context, [object]$Request)
    # A fresh script scope on every call lets a repaired handler run without another UAC.
    & (Join-Path $Context.Repository 'tests/hyperv_actions.ps1') -Context $Context -Request $Request
}

function Write-WorkerRecord {
    param([hashtable]$Context)
    $record = @{
        Pid = $PID
        Started = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        Instance = $Context.Instance
        Repository = $Context.Repository
        Expires = $Context.IdleUntil.ToString('o')
        Jobs = @($Context.Jobs.Keys)
    }
    $temporary = $workerPath + '.' + $Context.Instance + '.tmp'
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), $utf8)
    if ([IO.File]::Exists($workerPath)) { [IO.File]::Replace($temporary, $workerPath, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $workerPath) }
}

if (-not $PSCmdlet.ShouldProcess('Hyper-V test environment', $Action)) { return }

if ($Action -eq 'Start') {
    if (Get-HypervWorker $workerPath) { 'Worker already running.'; return }
    # Catch syntax and UTF-8/JSON problems before asking Windows to elevate.
    foreach ($path in @($PSCommandPath, $handlerPath,
        (Join-Path $Repository 'tests/hyperv_guest_command.ps1'),
        (Join-Path $Repository 'tests/hyperv_logon.ps1'))) {
        if (-not [IO.File]::Exists($path)) { throw "Required test script is missing: $path" }
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors -join "`n") }
    }
    $identityPath = Join-Path $StateDirectory 'vm-created.json'
    if ([IO.File]::Exists($identityPath)) { $null = [IO.File]::ReadAllText($identityPath) | ConvertFrom-Json }
    $null = [IO.Directory]::CreateDirectory($StateDirectory)
    # Serialize simultaneous Start calls, including the time spent waiting for consent.
    $startLock = [IO.File]::Open((Join-Path $StateDirectory 'worker-start.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        if (Get-HypervWorker $workerPath) { 'Worker already running.'; return }
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
            '-Action', 'Worker', '-StateDirectory', ('"' + $StateDirectory + '"'),
            '-Repository', ('"' + $Repository + '"'), '-IdleTimeoutMinutes', $IdleTimeoutMinutes
        )
        $start = @{
            FilePath = "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe"
            WindowStyle = 'Hidden'
            PassThru = $true
            ArgumentList = $arguments
        }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $start.Verb = 'RunAs' }
        $process = Start-Process @start
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
            $record = Get-HypervWorker $workerPath
            if ($record -and $record.Pid -eq $process.Id) { "Worker ready: $($process.Id)"; return }
            Start-Sleep -Milliseconds 200
            $process.Refresh()
        }
        throw 'Worker did not become ready. See worker-error.json; do not start another diagnostic worker.'
    } finally { $startLock.Dispose() }
}

if ($Action -ne 'Worker') {
    $worker = Get-HypervWorker $workerPath
    if (-not $worker) { throw 'Start the test worker once with -Action Start before queuing operations.' }
    $requestPath = Join-Path $StateDirectory 'request.json'
    if ([IO.File]::Exists($requestPath)) { throw 'Another operation is queued.' }
    $request = @{
        Id = [guid]::NewGuid().ToString()
        Worker = $worker.Instance
        Action = $Action
        Modes = $Modes
        Baseline = $Baseline
        AutoLogonCount = $AutoLogonCount
        PreparationStage = $PreparationStage
        IsoSource = $IsoSource
        IsoSha256 = $IsoSha256
        IsoLanguage = $IsoLanguage
    }
    if ($Action -eq 'Guest') {
        if (-not $ScriptPath -or [IO.Path]::GetExtension($ScriptPath) -ine '.ps1') {
            throw 'Guest requires an existing PowerShell -ScriptPath.'
        }
        $source = (Get-Item -LiteralPath $ScriptPath).FullName
        $request.Script = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        $request.Arguments = [Management.Automation.PSSerializer]::Serialize($ScriptArguments)
        $request.Source = $source
    }
    $temporary = Join-Path $StateDirectory ('request-' + $request.Id + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($request | ConvertTo-Json -Depth 8), $utf8)
        [IO.File]::Move($temporary, $requestPath)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    "Queued $Action : $($request.Id)"
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Worker requires elevation.' }
$lock = [IO.File]::Open((Join-Path $StateDirectory 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$context = @{
    Repository = $Repository; StateDirectory = $StateDirectory
    Instance = [guid]::NewGuid().ToString(); Session = $null; Jobs = @{}
    IdleUntil = (Get-Date).AddMinutes($IdleTimeoutMinutes); IdleTimeoutMinutes = $IdleTimeoutMinutes
    Stop = $false; AutoLogon = $false
}
$resultDirectory = Join-Path $StateDirectory 'operations'
$null = [IO.Directory]::CreateDirectory($resultDirectory)
try {
    Write-WorkerRecord $context
    while (-not $context.Stop -and ((Get-Date) -lt $context.IdleUntil -or $context.Jobs.Count)) {
        $requestPath = Join-Path $StateDirectory 'request.json'
        if ([IO.File]::Exists($requestPath)) {
            $result = $null
            try {
                $request = [IO.File]::ReadAllText($requestPath) | ConvertFrom-Json
                [IO.File]::Delete($requestPath)
                if ($request.Id -notmatch '^[0-9a-f-]{36}$' -or $request.Worker -ne $context.Instance) {
                    throw 'The request does not belong to this worker.'
                }
                $result = @{ Id = $request.Id; Action = $request.Action; Success = $false }
                $context.IdleUntil = (Get-Date).AddMinutes($IdleTimeoutMinutes)
                $result.Result = Invoke-HypervOperation $context $request
                $result.Success = $true
            } catch {
                if ($result) { $result.Error = $_.Exception.Message; $result.Stack = $_.ScriptStackTrace }
                else {
                    [IO.File]::WriteAllText((Join-Path $StateDirectory 'worker-error.json'),
                        (@{ Error = $_.Exception.Message } | ConvertTo-Json), $utf8)
                }
            }
            if ($result) {
                [IO.File]::WriteAllText((Join-Path $resultDirectory ($request.Id + '.json')),
                    ($result | ConvertTo-Json -Depth 12), $utf8)
            }
            Write-WorkerRecord $context
        }
        if ($context.Jobs.Count) {
            try { $null = Invoke-HypervOperation $context ([pscustomobject]@{ Action = 'Poll' }) }
            catch {
                [IO.File]::WriteAllText((Join-Path $StateDirectory 'progress-error.txt'), $_.Exception.Message, $utf8)
            }
        }
        Start-Sleep -Milliseconds 500
    }
} catch {
    [IO.File]::WriteAllText((Join-Path $StateDirectory 'worker-error.json'),
        (@{ Error = $_.Exception.Message; Stack = $_.ScriptStackTrace } | ConvertTo-Json), $utf8)
    throw
} finally {
    try { $null = Invoke-HypervOperation $context ([pscustomobject]@{ Action = 'Disconnect' }) }
    catch {
        [IO.File]::WriteAllText((Join-Path $StateDirectory 'worker-error.json'),
            (@{ Error = $_.Exception.Message } | ConvertTo-Json), $utf8)
    }
    if ($context.Session) { Remove-PSSession $context.Session -ErrorAction SilentlyContinue }
    if ([IO.File]::Exists($workerPath)) { [IO.File]::Delete($workerPath) }
    $lock.Dispose()
}
