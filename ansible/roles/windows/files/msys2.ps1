[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root,
    [string]$Mode,
    [string]$Installer,
    [string[]]$Packages,
    [string]$Cache,
    [string]$Downloader
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Ansible.Changed = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$bash = Join-Path $Root 'usr/bin/bash.exe'
$env:CHERE_INVOKING = '1'
$env:MSYSTEM = 'MSYS'

function Invoke-Msys {
    param([string]$Command, [int[]]$Allowed = @(0))

    $script = $Command + '; status=$?; gpgconf --homedir /etc/pacman.d/gnupg --kill all >/dev/null 2>&1; exit $status'
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $bash -lc $script 2>&1 | Out-String
    if ($LASTEXITCODE -notin $Allowed) {
        throw "MSYS2 command failed ($LASTEXITCODE): $Command`n$output"
    }
    @{ Code = $LASTEXITCODE; Output = $output.Trim() }
}

function Get-Pacman {
    if (-not $Cache) { return 'pacman' }
    $null = [IO.Directory]::CreateDirectory($Cache)
    $path = (& (Join-Path $Root 'usr/bin/cygpath.exe') -u $Cache).Trim()
    "pacman --cachedir '$path'"
}

function Update-System {
    $pacman = Get-Pacman
    $before = (Invoke-Msys 'pacman -Q').Output
    $null = Invoke-Msys "$pacman -Syuu --noconfirm"
    $null = Invoke-Msys "$pacman -Syuu --noconfirm"
    if ((Invoke-Msys 'pacman -Q').Output -ne $before) { $Ansible.Changed = $true }
}

if ($Ansible.CheckMode) {
    if (-not [IO.File]::Exists($bash)) {
        $Ansible.Changed = $Mode -ne 'update'
    } elseif ($Mode -ne 'update') {
        $Ansible.Changed = (Invoke-Msys ('pacman -T ' + ($Packages -join ' ')) @(0, 127)).Code -eq 127
    }
    return
}

if (-not [IO.File]::Exists($bash)) {
    if ($Mode -eq 'update') { throw "MSYS2 is not installed at $Root; run the init mode first." }

    $parent = Split-Path $Root
    $leaf = Split-Path $Root -Leaf
    $extracted = Join-Path $parent 'msys64'
    if ([IO.Directory]::Exists($Root) -and [IO.Directory]::GetFileSystemEntries($Root).Length) {
        throw "MSYS2 root exists but does not contain MSYS2: $Root"
    }
    if ($leaf -ne 'msys64' -and [IO.Directory]::Exists($extracted)) {
        throw "The MSYS2 archive extracts to an existing directory: $extracted"
    }

    $null = [IO.Directory]::CreateDirectory($parent)
    if ([IO.Directory]::Exists($Root)) { [IO.Directory]::Delete($Root) }
    $downloadCache = if ($Cache) { Join-Path $Cache 'installer' } else { Join-Path $env:TEMP 'shell-msys2-cache' }
    $archive = & $Downloader -Url $Installer -Cache $downloadCache
    $process = Start-Process -FilePath $archive -ArgumentList '-y', "-o$parent" -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "MSYS2 archive extraction failed ($($process.ExitCode))." }
    if ($leaf -ne 'msys64') { Rename-Item -LiteralPath $extracted -NewName $leaf }

    $null = Invoke-Msys 'true'
    $null = Invoke-Msys 'pacman-key --init && pacman-key --populate msys2'
    Update-System
    $Ansible.Changed = $true
}

if ($Mode -eq 'update') {
    Update-System
} else {
    $missing = Invoke-Msys ('pacman -T ' + ($Packages -join ' ')) @(0, 127)
    if ($missing.Code -eq 127) {
        Update-System
        $names = $missing.Output -split '\s+' | Where-Object { $_ }
        $null = Invoke-Msys ((Get-Pacman) + ' -S --needed --noconfirm ' + ($names -join ' '))
        $Ansible.Changed = $true
    }
}
