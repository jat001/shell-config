[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Command,
    [string]$Description
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $true
if ($Ansible.CheckMode) { return }

$log = Join-Path $env:TEMP ('shell-elevated-{0}.log' -f [guid]::NewGuid())
$script = @"
`$ErrorActionPreference = 'Stop'
try {
$Command
} catch {
    `$_ | Out-String | Set-Content -LiteralPath '$log' -Encoding UTF8
    exit 1
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

try {
    $process = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
} catch {
    throw "Administrator approval was not granted for: $Description"
}
if ($process.ExitCode -ne 0) {
    $detail = if (Test-Path -LiteralPath $log) { Get-Content -Raw -LiteralPath $log }
    throw "The elevated step failed ($Description): $detail"
}
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
