$ErrorActionPreference = 'Stop'

$root = Split-Path $MyInvocation.MyCommand.Path
$settings = Get-Content -Raw -LiteralPath (Join-Path $root 'settings.json') | ConvertFrom-Json
$password = ConvertTo-SecureString $settings.Password -AsPlainText -Force

if (-not (Get-LocalUser -Name $settings.User -ErrorAction SilentlyContinue)) {
    $null = New-LocalUser -Name $settings.User -Password $password -PasswordNeverExpires -AccountNeverExpires
}
Set-LocalUser -Name $settings.User -Password $password
Set-LocalUser -Name $settings.AdminUser -Password $password
$members = Get-LocalGroupMember -SID 'S-1-5-32-580' | ForEach-Object { $_.Name -replace '^.*\\', '' }
if ($members -notcontains $settings.User) { Add-LocalGroupMember -SID 'S-1-5-32-580' -Member $settings.User }

Add-Type -Namespace Native -Name Profile -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode)]
public static extern int CreateProfile(string sid, string name, System.Text.StringBuilder path, uint size);
'@

foreach ($user in @($settings.User, $settings.AdminUser)) {
    $profilePath = "C:\Users\$user"
    if (-not (Test-Path $profilePath)) {
        $sid = (Get-LocalUser -Name $user).SID.Value
        $path = [Text.StringBuilder]::new(260)
        $result = [Native.Profile]::CreateProfile($sid, $user, $path, 260)
        if ($result -ne 0) { throw "CreateProfile failed for ${user}: $result" }
        $profilePath = $path.ToString()
    }

    $config = Join-Path $profilePath '.config'
    $null = New-Item -ItemType Directory -Force $config
    if (-not (Test-Path (Join-Path $config 'shell'))) {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $config 'shell') -Target 'C:\shell-repo'
    }
    $vhd = Join-Path $profilePath 'AppData\Local\wsl\dev.vhdx'
    $null = New-Item -ItemType Directory -Force (Split-Path $vhd)
    if (-not (Test-Path $vhd)) { $null = New-Item -ItemType File $vhd }

    $credentialFile = Join-Path $env:TEMP "shell-test-$user.xml"
    [pscredential]::new(".\$user", $password) | Export-Clixml -LiteralPath $credentialFile
    try {
        $bootstrap = @{
            ClientCertificate = Join-Path $root "winrm-$user.pem"
            ServerCertificate = Join-Path $root 'winrm-server.pem'
            User = $user
            Name = $settings.Address
            Address = '*'
            CredentialFile = $credentialFile
            FullToken = $user -eq $settings.AdminUser
        }
        & (Join-Path $root 'winrm.ps1') @bootstrap
    } finally {
        Remove-Item -LiteralPath $credentialFile -Force -ErrorAction SilentlyContinue
    }
}

[Environment]::SetEnvironmentVariable('SCOOP_CACHE', 'C:\shell-cache\scoop', 'Machine')
$gitConfig = @'
[url "file:///C:/shell-cache/git/"]
	insteadOf = https://github.com/ScoopInstaller/
[safe]
	directory = *
'@
[IO.File]::WriteAllText("C:\Users\$($settings.AdminUser)\.gitconfig", $gitConfig.Replace("`r", '') + "`n",
    [Text.UTF8Encoding]::new($false))

New-NetFirewallRule -DisplayName 'Shell test WinRM' -Direction Inbound -Protocol TCP `
    -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue | Out-Null
Set-Content -LiteralPath (Join-Path $root 'ready') -Value 'ready'
