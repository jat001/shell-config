param([Parameter(Mandatory)][string]$Directory)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$result = @{ Success = $false; Started = [DateTime]::UtcNow.ToString('o') }
try {
    $arguments = [Management.Automation.PSSerializer]::Deserialize(
        [IO.File]::ReadAllText((Join-Path $Directory 'arguments.clixml'))
    )
    # Windows PowerShell 5.1 needs a BOM on the temporary executable copy to preserve Unicode.
    $command = Join-Path $Directory 'command.ps1'
    [IO.File]::WriteAllText($command, [IO.File]::ReadAllText((Join-Path $Directory 'script.ps1')),
        [Text.UTF8Encoding]::new($true))
    & $command @arguments
    if (-not $?) { throw 'Guest script reported failure.' }
    $result.Success = $true
} catch {
    $result.Error = $_.Exception.Message
    $result.Stack = $_.ScriptStackTrace
} finally {
    $result.Finished = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $Directory 'result.json'), ($result | ConvertTo-Json), $utf8)
}
if (-not $result.Success) { exit 1 }
