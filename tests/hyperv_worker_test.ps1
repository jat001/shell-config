[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'StateDirectory is read by the dot-sourced Assert-TestVm helper.')]
param([string]$Repository)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-hyperv-worker-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory((Join-Path $temporary 'tests'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors -join "`n") }
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if (-not $definition) { throw "Missing test function: $Name" }
    $definition
}

try {
    $client = Join-Path $Repository 'tests/hyperv.ps1'
    $actions = Join-Path $Repository 'tests/hyperv_actions.ps1'
    . ([scriptblock]::Create((Get-TestFunction $client 'Invoke-HypervOperation').Extent.Text))
    $Context = @{ Repository = $temporary; Instance = 'same-worker' }
    $handler = Join-Path $temporary 'tests/hyperv_actions.ps1'
    foreach ($version in @('first', 'second')) {
        [IO.File]::WriteAllText($handler, "param(`$Context, `$Request)`n'$version'", $utf8)
        if ((Invoke-HypervOperation $Context @{}) -ne $version) { throw 'The operation handler was cached.' }
    }
    [IO.File]::WriteAllText($handler, 'param(', $utf8)
    $rejected = $false
    try { $null = Invoke-HypervOperation $Context @{} } catch { $rejected = $true }
    if (-not $rejected) { throw 'An invalid handler was accepted.' }
    [IO.File]::WriteAllText($handler, "param(`$Context, `$Request)`n'repaired'", $utf8)
    if ((Invoke-HypervOperation $Context @{}) -ne 'repaired') { throw 'The repaired handler could not run.' }

    . ([scriptblock]::Create((Get-TestFunction $client 'Write-WorkerRecord').Extent.Text))
    $workerPath = Join-Path $temporary 'worker-state.json'
    $recordContext = @{ Instance = 'atomic'; Repository = $temporary; Jobs = @{}; IdleUntil = (Get-Date).AddMinutes(2) }
    foreach ($iteration in 1..3) {
        Write-WorkerRecord $recordContext
        $record = [IO.File]::ReadAllText($workerPath) | ConvertFrom-Json
        if ($record.Instance -ne 'atomic') { throw 'Repeated worker state publication failed.' }
    }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $recordReader = [IO.File]::Open($workerPath, 'Open', 'Read', $share)
    try { Write-WorkerRecord $recordContext } finally { $recordReader.Dispose() }
    . ([scriptblock]::Create((Get-TestFunction $client 'Get-HypervWorker').Extent.Text))
    if (-not (Get-HypervWorker $workerPath)) { throw 'A concurrently published worker record was not recognized.' }
    # The actual guest log reader must coexist with an open writer.
    $definition = Get-TestFunction $actions 'Copy-Logs'
    $reader = $definition.Find({
            param($node)
            $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
            $node.Extent.Text.Contains('$stream.CopyTo($memory)')
        }, $true).ScriptBlock.GetScriptBlock()
    $log = Join-Path $temporary 'active.log'
    $writer = [IO.File]::Open($log, 'Create', 'Write', 'ReadWrite')
    try {
        $bytes = $utf8.GetBytes(('active log / UTF-8: ' + [char]0x4E2D + [char]0x6587))
        $writer.Write($bytes, 0, $bytes.Length)
        $writer.Flush()
        $encoded = & $reader $log
        if ($encoded -cne [Convert]::ToBase64String($bytes)) { throw 'The active log was not read correctly.' }
    }
    finally { $writer.Dispose() }

    $definition = Get-TestFunction $actions 'Write-GuestFile'
    $write = $definition.Find({
            param($node)
            $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
            $node.Extent.Text.Contains('[IO.File]::WriteAllBytes')
        }, $true).ScriptBlock.GetScriptBlock()
    $readLock = [IO.File]::Open($log, 'Open', 'Read', 'Read')
    try { & $write $log $encoded } finally { $readLock.Dispose() }
    $replacement = [Convert]::ToBase64String($utf8.GetBytes('new content'))
    & $write $log $replacement
    if ([IO.File]::ReadAllText($log) -cne 'new content') { throw 'The guest file was not replaced.' }

    . ([scriptblock]::Create((Get-TestFunction $actions 'Assert-TestVm').Extent.Text))
    $StateDirectory = $temporary
    $Context = @{}
    $vmId = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText((Join-Path $temporary 'vm-created.json'),
        (@{ Name = 'fixture'; Id = $vmId; Image = ( -join [char[]]@(0x4F01, 0x4E1A, 0x8BC4, 0x4F30, 0x7248)) } | ConvertTo-Json), $utf8)
    function Get-VM { param([string]$Name) [pscustomobject]@{ Name = $Name; Id = $vmId } }
    $null = Assert-TestVm
    if ($Context.VmId -ne $vmId) { throw 'The UTF-8 VM identity was not read.' }
    $Context.VmId = [guid]::NewGuid().ToString()
    $rejected = $false
    try { $null = Assert-TestVm } catch { $rejected = $true }
    if (-not $rejected) { throw 'A changed VM identity was accepted.' }

    # Start twice through the real client; a fake process launcher must be called only once.
    $fake = [pscustomobject]@{
        Id = $PID; ProcessName = 'powershell'; StartTime = (Get-Date).AddMinutes(-1); HasExited = $false
    }
    $fake | Add-Member ScriptMethod Refresh {}
    $launches = [Collections.Generic.List[object]]::new()
    function Get-Process { param([int]$Id, [string]$ErrorAction) if ($Id -eq $PID) { $fake } }
    function Start-Process {
        param($FilePath, $WindowStyle, [switch]$PassThru, $ArgumentList, $Verb)
        $launches.Add($ArgumentList)
        [IO.File]::WriteAllText((Join-Path $temporary 'worker.json'), (@{
                    Pid = $PID; Instance = 'fixture-worker'; Started = $fake.StartTime.ToUniversalTime().ToString('o')
                } | ConvertTo-Json), $utf8)
        $fake
    }
    $null = & $client -Action Start -StateDirectory $temporary -Repository $Repository
    $null = & $client -Action Start -StateDirectory $temporary -Repository $Repository
    if ($launches.Count -ne 1) { throw 'Repeated Start requested another administrator process.' }

    $runner = Join-Path $Repository 'tests/hyperv_guest_command.ps1'
    $job = Join-Path $temporary 'job'
    [void][IO.Directory]::CreateDirectory($job)
    $parameters = @{ Text = ('spaces and ' + [char]0x4E2D + [char]0x6587); Values = @('a b', '', 'c'); Enabled = $true }
    [IO.File]::WriteAllText((Join-Path $job 'arguments.clixml'),
        [Management.Automation.PSSerializer]::Serialize($parameters), $utf8)
    [IO.File]::WriteAllText((Join-Path $job 'script.ps1'), @'
param([string]$Text, [string[]]$Values, [bool]$Enabled)
if ($Text -ne ('spaces and ' + [char]0x4E2D + [char]0x6587) -or $Values.Count -ne 3 -or $Values[1] -ne '' -or -not $Enabled) {
    throw 'Guest arguments were changed.'
}
'@, $utf8)
    $engine = (Microsoft.PowerShell.Management\Get-Process -Id $PID).Path
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -Directory $job *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Structured guest arguments failed.' }
    [IO.File]::WriteAllText((Join-Path $job 'arguments.clixml'),
        [Management.Automation.PSSerializer]::Serialize(@{}), $utf8)
    [IO.File]::WriteAllText((Join-Path $job 'script.ps1'), 'exit 7', $utf8)
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -Directory $job *> $null
    if ($LASTEXITCODE -ne 1) { throw 'A guest script exit was reported as success.' }
    [IO.File]::WriteAllText((Join-Path $job 'script.ps1'), @'
& $env:ComSpec /d /c 'exit 7'
if ($LASTEXITCODE -ne 7) { throw 'Expected failure did not occur.' }
'Expected native failure was handled.'
'@, $utf8)
    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner -Directory $job *> $null
    if ($LASTEXITCODE -ne 0) { throw 'A handled native error failed the guest script.' }
    $cases = @(
        @{ Parameters = @{}; Expected = 'init,full,full,update' }
        @{ Parameters = @{ Profile = 'full' }; Expected = 'init,full,full,update' }
        @{ Parameters = @{ Profile = 'fast' }; Expected = 'init,full' }
        @{ Parameters = @{ Profile = 'standard' }; Expected = 'init,full,full' }
        @{ Parameters = @{ Modes = @('full', 'update') }; Expected = 'full,update' }
    )
    $requestPath = Join-Path $temporary 'request.json'
    foreach ($case in $cases) {
        $parameters = @{ Action = 'Run'; StateDirectory = $temporary; Repository = $Repository }
        foreach ($entry in $case.Parameters.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
        & $client @parameters | Out-Null
        if (-not [IO.File]::Exists($requestPath)) { throw 'A Run request was not queued.' }
        $request = [IO.File]::ReadAllText($requestPath) | ConvertFrom-Json
        if (($request.Modes -join ',') -cne $case.Expected) { throw "Unexpected queued modes: $($request.Modes -join ',')" }
        [IO.File]::Delete($requestPath)
    }
    $rejected = $false
    try { & $client -Action Run -Profile full -Modes full, update -StateDirectory $temporary -Repository $Repository } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw 'Hyper-V accepted both Profile and Modes.' }
    if ([IO.File]::Exists($requestPath)) { throw 'A conflicting Hyper-V request was queued.' }
    $rejected = $false
    try { & (Join-Path $Repository 'tests/run.ps1') -Profile fast -Step init -StateDirectory $temporary } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw 'The test runner accepted both Profile and Step.' }
    if ($launches.Count -ne 1) { throw 'Profile tests requested another administrator process.' }

    $runner = Join-Path $Repository 'tests/run.ps1'
    . ([scriptblock]::Create((Get-TestFunction $runner 'Assert-Unchanged').Extent.Text))
    $clean = @(
        'arch : ok=1 changed=0 unreachable=0 failed=0',
        'debian : ok=1 changed=0 unreachable=0 failed=0'
    )
    Assert-Unchanged $clean 'clean fixture' -ExpectedHost @('arch', 'debian')
    foreach ($sample in @('', $clean[0], ($clean -join "`n").Replace('changed=0', 'changed=1'))) {
        $rejected = $false
        try { Assert-Unchanged @($sample) 'invalid fixture' -ExpectedHost @('arch', 'debian') } catch { $rejected = $true }
        if (-not $rejected) { throw "An invalid recap was accepted: $sample" }
    }

    . ([scriptblock]::Create((Get-TestFunction $actions 'Update-Jobs').Extent.Text))
    function Connect-Guest {}
    function Copy-Logs {}
    $StateDirectory = $temporary
    [void][IO.Directory]::CreateDirectory((Join-Path $temporary 'operations'))
    $job = @{ Id = 'missing-result'; Type = 'Guest'; ResultPath = 'missing.json' }
    $Context = @{ Jobs = @{ 'missing-result' = $job }; IdleTimeoutMinutes = 120 }
    function Invoke-Command {
        param($Session, $ArgumentList, $ScriptBlock)
        [pscustomobject]@{
            OperationId = $ArgumentList.Id; Type = $ArgumentList.Type; Running = $false
            Result = $null; ResultMissing = $true; Verification = $null
            Success = $null; Error = $null; Phase = $null
        }
    }
    Update-Jobs
    $progress = [IO.File]::ReadAllText((Join-Path $temporary 'operations/missing-result.progress.json')) | ConvertFrom-Json
    if ($progress.Success -ne $false -or $progress.Error -notlike '*Result file is missing*') {
        throw 'A missing guest result was not an explicit failure.'
    }

    $id = 'verification-gate'
    $job = @{ Id = $id; Type = 'Run'; ResultPath = 'result.json'; Verify = $true; ColdBoot = $false; VerificationSince = $null }
    $Context = @{ Jobs = @{ $id = $job }; IdleTimeoutMinutes = 120 }
    $script:verification = $null
    function Invoke-Command {
        param($Session, $ArgumentList, $ScriptBlock)
        [pscustomobject]@{
            OperationId = $ArgumentList.Id; Type = 'Run'; Running = $false
            Result = [pscustomobject]@{ Success = $true }; ResultMissing = $false
            Verification = $script:verification; Success = $null; Error = $null; Phase = $null
        }
    }
    Update-Jobs
    $progressPath = Join-Path $temporary "operations/$id.progress.json"
    $progress = [IO.File]::ReadAllText($progressPath) | ConvertFrom-Json
    if (-not $progress.Running -or -not $Context.Jobs.Count) { throw 'Deployment completed before verification.' }
    $script:verification = [pscustomobject]@{ OperationId = 'old-operation'; Running = $false; Success = $true }
    Update-Jobs
    $progress = [IO.File]::ReadAllText($progressPath) | ConvertFrom-Json
    if (-not $progress.Running -or -not $Context.Jobs.Count) { throw 'A stale verification result was accepted.' }
    $script:verification = [pscustomobject]@{ OperationId = $id; Running = $false; Success = $true }
    Update-Jobs
    $progress = [IO.File]::ReadAllText($progressPath) | ConvertFrom-Json
    if (-not $progress.Success -or $Context.Jobs.Count) { throw 'A fresh verification result did not complete the job.' }

    $id = 'corrupt-verification'
    $job = @{ Id = $id; Type = 'Run'; ResultPath = 'result.json'; Verify = $true; ColdBoot = $false; VerificationSince = $null }
    $Context = @{ Jobs = @{ $id = $job }; IdleTimeoutMinutes = 120 }
    function Invoke-Command {
        param($Session, $ArgumentList, $ScriptBlock)
        [pscustomobject]@{
            OperationId = $ArgumentList.Id; Type = 'Run'; Running = $false
            Result = [pscustomobject]@{ Success = $true }; ResultMissing = $false; ResultError = $null
            Verification = $null; VerificationError = 'Invalid JSON'; Success = $null; Error = $null; Phase = $null
        }
    }
    Update-Jobs
    $progress = [IO.File]::ReadAllText((Join-Path $temporary "operations/$id.progress.json")) | ConvertFrom-Json
    if ($progress.Success -ne $false -or $progress.Error -notlike '*Could not read the verification result*') {
        throw 'A corrupt verification result was not an explicit failure.'
    }

    $verifyScript = Join-Path $Repository 'tests/hyperv_verify.ps1'
    . ([scriptblock]::Create((Get-TestFunction $verifyScript 'Write-VerificationResult').Extent.Text))
    $script:resultPath = Join-Path $temporary 'atomic-verification.json'
    $script:utf8 = [Text.UTF8Encoding]::new($false)
    $script:result = @{ OperationId = 'atomic'; Success = $true; Running = $false }
    foreach ($iteration in 1..20) {
        $script:result.Iteration = $iteration
        Write-VerificationResult
        $record = [IO.File]::ReadAllText($script:resultPath) | ConvertFrom-Json
        if ($record.OperationId -ne 'atomic' -or $record.Iteration -ne $iteration) {
            throw 'Atomic verification publication produced an invalid result.'
        }
    }
    "PowerShell $($PSVersionTable.PSVersion): worker reuse, handler reload/recovery, VM identity, file IO, guest jobs and profiles passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
