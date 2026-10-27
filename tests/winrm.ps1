param(
    [Parameter(Mandatory)]
    [string]$ClientCertificate,
    [Parameter(Mandatory)]
    [string]$ServerCertificate,
    [Parameter(Mandatory)]
    [string]$User,
    [string[]]$Name = @('host.wslc.internal'),
    [string]$Address = 'IP:127.0.0.1',
    [int]$Port = 5986,
    [string]$CredentialFile,
    [switch]$FullToken
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)

if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

if ($FullToken) {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
}
Set-Item -Path WSMan:\localhost\Service\Auth\Certificate -Value $true

$alternative = ($Name | ForEach-Object {
    if ($_ -as [ipaddress]) { "ipaddress=$_" } else { "dns=$_" }
}) -join '&'
$subject = "CN=$($Name[0])"
$friendly = "shell-ansible-winrm $alternative"
$server = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(30) -and
    $_.FriendlyName -eq $friendly
} | Select-Object -First 1
if (-not $server) {
    $server = New-SelfSignedCertificate -Subject $subject -FriendlyName $friendly `
        -TextExtension @("2.5.29.17={text}$alternative", '2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(5)
}
$pem = [Convert]::ToBase64String($server.RawData, 'InsertLineBreaks').Replace("`r", '')
[IO.File]::WriteAllText(
    $ServerCertificate,
    "-----BEGIN CERTIFICATE-----`n$pem`n-----END CERTIFICATE-----`n",
    $utf8
)

$selector = @{ Address = $Address; Transport = 'HTTPS' }
try {
    $listener = Get-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $selector
} catch {
    $listener = $null
}
$values = @{ Hostname = $Name[0]; CertificateThumbprint = $server.Thumbprint; Port = $Port }
if (-not $listener) {
    $null = New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $selector -ValueSet $values
} elseif ($listener.CertificateThumbprint -ne $server.Thumbprint -or $listener.Port -ne $Port -or
    $listener.Hostname -ne $Name[0]) {
    $null = Set-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $selector -ValueSet $values
}

$client = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ClientCertificate)
foreach ($storeName in @('Root', 'TrustedPeople')) {
    $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
    $store.Open('ReadWrite')
    try {
        if (-not ($store.Certificates | Where-Object Thumbprint -eq $client.Thumbprint)) {
            $store.Add($client)
        }
    } finally {
        $store.Close()
    }
}

$mapping = @(Get-WSManInstance -ResourceURI winrm/config/service/certmapping -Enumerate |
    Where-Object { $_.Issuer -eq $client.Thumbprint -and $_.Subject -eq "$User@localhost" })
if (-not $mapping) {
    if (-not $CredentialFile) { throw "A credential is required to map the client certificate for $User." }
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $null = New-Item -Path WSMan:\localhost\ClientCertificate -Subject "$User@localhost" -URI '*' `
        -Issuer $client.Thumbprint -Credential $credential -Force
}
