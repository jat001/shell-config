[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root,
    [string]$Mode,
    [string]$Installer,
    [string[]]$Packages,
    [string]$Cache,
    [string]$Downloader,
    [bool]$UseCernet = $false
)

$ErrorActionPreference = 'Stop'
# The downloader is a script file. A Restricted policy, as on Windows Sandbox, blocks it.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$ProgressPreference = 'SilentlyContinue'
$Ansible.Changed = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$bash = Join-Path $Root 'usr/bin/bash.exe'
$env:CHERE_INVOKING = '1'
$env:MSYSTEM = 'MSYS'

function Invoke-Msys {
    param([string]$Command, [int[]]$Allowed = @(0), [switch]$AllowCoreRestart)

    # gpgconf is stopped after pacman so the keyring is not left locked, and the saved status is pacman's, not gpgconf's.
    $script = $Command + '; status=$?; gpgconf --homedir /etc/pacman.d/gnupg --kill all >/dev/null 2>&1; exit $status'
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $bash -lc $script 2>&1 | Out-String
    # A committed core upgrade closes this Bash. Only that specific exit may continue in a new process.
    $coreRestart = $AllowCoreRestart -and $LASTEXITCODE -eq 1 -and $output.Contains(
        'To complete this update all MSYS2 processes including this terminal will be closed.'
    )
    if ($LASTEXITCODE -notin $Allowed -and -not $coreRestart) {
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
    $null = Invoke-Msys "LC_ALL=C $pacman -Syuu --noconfirm" -AllowCoreRestart
    $null = Invoke-Msys "LC_ALL=C $pacman -Syuu --noconfirm"
    if ((Invoke-Msys 'pacman -Q').Output -ne $before) { $Ansible.Changed = $true }
}

function Set-MsysHttpsSources {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $plans = [Collections.Generic.List[object]]::new()
    foreach ($name in 'etc/pacman.conf', 'etc/pacman.d/mirrorlist.msys', 'etc/pacman.d/mirrorlist.mingw') {
        $file = Join-Path $Root $name
        if (-not [IO.File]::Exists($file)) { continue }
        $original = [IO.File]::ReadAllText($file, $utf8)
        $updated = $original
        if ($name -ne 'etc/pacman.conf') {
            $block = '(?m)^# BEGIN shell-ansible CERNET\r?\nCacheServer = https://mirrors\.cernet\.edu\.cn/msys2/[^\r\n]+\r?\n# END shell-ansible CERNET(?:\r?\n|$)'
            $updated = $updated -creplace $block, ''
            if ($updated -cmatch '(?m)^# (?:BEGIN|END) shell-ansible CERNET') {
                throw "Unrecognized CERNET block in $file"
            }
            if ($UseCernet) {
                $path = if ($name.EndsWith('.msys')) { 'msys/$arch/' } else { 'mingw/$repo/' }
                $updated = "# BEGIN shell-ansible CERNET`nCacheServer = https://mirrors.cernet.edu.cn/msys2/$path`n# END shell-ansible CERNET`n" + $updated
            }
        }
        $updated = $updated -creplace '(?m)^([ \t]*(?:Server|CacheServer)[ \t]*=[ \t]*)http://', '${1}https://'
        if ($updated -ceq $original) { continue }
        $plans.Add(@{ Path = $file; Content = $updated })
    }
    foreach ($plan in $plans) {
        $Ansible.Changed = $true
        if ($Ansible.CheckMode) { continue }

        $temporary = $plan.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temporary, $plan.Content, $utf8)
            [IO.File]::Replace($temporary, $plan.Path, [NullString]::Value)
        }
        finally { [IO.File]::Delete($temporary) }
    }
}

function Assert-MsysCernetSupport {
    if (-not $UseCernet) { return }
    $probe = "printf '[shell-probe]\nCacheServer = https://mirrors.cernet.edu.cn/\n' | pacman-conf --config /dev/stdin --repo shell-probe CacheServer"
    $output = (Invoke-Msys $probe).Output
    $value = ($output -split '\r?\n')[-1].Trim()
    if ($value -ne 'https://mirrors.cernet.edu.cn/') {
        throw 'This MSYS2 pacman does not support CacheServer.'
    }
}

if ($Ansible.CheckMode) {
    if (-not [IO.File]::Exists($bash)) {
        $Ansible.Changed = $Mode -ne 'update'
    }
    elseif ($Mode -ne 'update') {
        $Ansible.Changed = (Invoke-Msys ('pacman -T ' + ($Packages -join ' ')) @(0, 127)).Code -eq 127
    }
    if ([IO.File]::Exists($bash)) { Assert-MsysCernetSupport }
    Set-MsysHttpsSources
    return
}

$freshInstall = -not [IO.File]::Exists($bash)
if ($freshInstall) {
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
}

if ($freshInstall) { $null = Invoke-Msys 'true' }
Assert-MsysCernetSupport
Set-MsysHttpsSources
if ($freshInstall) {
    $null = Invoke-Msys 'pacman-key --init && pacman-key --populate msys2'
    Update-System
    $Ansible.Changed = $true
}

if ($Mode -eq 'update') {
    Update-System
}
else {
    $missing = Invoke-Msys ('pacman -T ' + ($Packages -join ' ')) @(0, 127)
    if ($missing.Code -eq 127) {
        Update-System
        $names = $missing.Output -split '\s+' | Where-Object { $_ }
        $null = Invoke-Msys ((Get-Pacman) + ' -S --needed --noconfirm ' + ($names -join ' '))
        $Ansible.Changed = $true
    }
}
