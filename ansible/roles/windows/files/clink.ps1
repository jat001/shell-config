[CmdletBinding(SupportsShouldProcess)]
param([string]$Root)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$directory = Join-Path $Root 'apps/clink/current'
$batch = (Join-Path $directory 'clink.bat').Replace('/', '\')
$expected = '"' + $batch + '" inject --autorun'
$key = 'HKCU:\Software\Microsoft\Command Processor'
$before = (Get-ItemProperty -LiteralPath $key -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
$expanded = [Environment]::ExpandEnvironmentVariables([string]$before)
$pattern = '(?i)(?:^|&)\s*(?:call\s+)?' + [regex]::Escape($expected) + '(?=\s|&|$)'

if ($expanded -match $pattern) { return }

$Ansible.Changed = $true
if ($Ansible.CheckMode) { return }

$architecture = @{
    AMD64 = 'x64'
    ARM64 = 'arm64'
    x86 = 'x86'
}[$env:PROCESSOR_ARCHITECTURE]
if (-not $architecture) { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }

$loader = Join-Path $directory "clink_$architecture.exe"
$output = & $loader autorun install 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Clink autorun install failed ($LASTEXITCODE): $output" }

$after = (Get-ItemProperty -LiteralPath $key -Name AutoRun).AutoRun
if ([Environment]::ExpandEnvironmentVariables($after) -notmatch $pattern) {
    throw 'Clink did not register the expected AutoRun command.'
}
$Ansible.Changed = $after -cne $before
