$ErrorActionPreference = 'Stop'

$root = Split-Path $MyInvocation.MyCommand.Path
$settings = Get-Content -Raw -LiteralPath (Join-Path $root 'settings.json') | ConvertFrom-Json
$user = 'WDAGUtilityAccount'

$password = ConvertTo-SecureString $settings.Password -AsPlainText -Force
Set-LocalUser -Name $user -Password $password
$credentialFile = Join-Path $env:TEMP 'shell-test-credential.xml'
[pscredential]::new(".\$user", $password) | Export-Clixml -LiteralPath $credentialFile

try {
    & (Join-Path $root 'winrm.ps1') -ClientCertificate (Join-Path $root 'winrm-client.pem') `
        -ServerCertificate (Join-Path $root 'winrm-server.pem') -User $user `
        -Name $settings.Address -Address '*' -CredentialFile $credentialFile
} finally {
    Remove-Item -LiteralPath $credentialFile -Force -ErrorAction SilentlyContinue
}

$vhd = "C:\Users\$user\AppData\Local\wsl\dev.vhdx"
$null = New-Item -ItemType Directory -Force (Split-Path $vhd)
if (-not (Test-Path $vhd)) { $null = New-Item -ItemType File $vhd }

New-NetFirewallRule -DisplayName 'Shell test WinRM' -Direction Inbound -Protocol TCP `
    -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Set-Content -LiteralPath (Join-Path $root 'ready') -Value (Get-Service WinRM).Status
