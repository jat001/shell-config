param([string]$Modes = 'init,full,full,update')

$ErrorActionPreference = 'Stop'
$repository = Join-Path $env:USERPROFILE '.config/shell'
$state = Join-Path $env:LOCALAPPDATA 'shell-ansible'
$cache = 'C:\shell-cache'
$imageCache = Join-Path $cache 'images'
$wslc = Join-Path $env:ProgramFiles 'WSL/wslc.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
[void][IO.Directory]::CreateDirectory($state)
[void][IO.Directory]::CreateDirectory($imageCache)
$variables = @{
    # Only this test guest may detach a disk that is already in use. A normal install refuses that.
    shell_windows_dev_drive_allow_detach = $true
    shell_download_cache = $cache
    shell_scoop_cache = Join-Path $cache 'scoop'
    shell_msys2_cache = Join-Path $cache 'msys2'
    shell_store_cache = Join-Path $cache 'store'
    shell_archive_cache = Join-Path $cache 'archives'
}
[IO.File]::WriteAllText((Join-Path $state 'cache.json'), ($variables | ConvertTo-Json), $utf8)
$env:PATH = (Join-Path $env:ProgramFiles 'WSL') + ';' + $env:PATH

function Invoke-Container {
    param([string[]]$Arguments, [string]$Log)
    $process = Start-Process -FilePath $wslc -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput "C:\shell-test\$Log.out" -RedirectStandardError "C:\shell-test\$Log.err"
    $process.ExitCode
}

function Import-ControllerCache {
    if (-not [IO.File]::Exists($wslc)) { return }
    $seen = @{}
    foreach ($archive in Get-ChildItem -LiteralPath $imageCache -Filter '*.tar' -File | Sort-Object Name -Descending) {
        if ($archive.BaseName -notmatch '^shell-ansible-([0-9a-f]{12})-([0-9]{18})-([0-9a-f]{12})$') { continue }
        $tag = 'shell-ansible:' + $Matches[1]
        if ($seen.ContainsKey($tag)) { continue }
        $seen[$tag] = $true
        if ((Invoke-Container @('image','inspect',$tag) 'image-check') -eq 0) { continue }
        if ((Invoke-Container @('image','load','-i',$archive.FullName) 'image-load') -ne 0) {
            throw 'Cached controller image could not be loaded.'
        }
    }
}

function Export-ControllerCache {
    $marker = Join-Path $state 'controller-image.txt'
    if (-not [IO.File]::Exists($marker) -or -not [IO.File]::Exists($wslc)) { return }
    $tag = [IO.File]::ReadAllText($marker).Trim()
    if ($tag -notmatch '^shell-ansible:([0-9a-f]{12})$') { return }
    $inputHash = $Matches[1]
    if ((Invoke-Container @('image','inspect',$tag) 'image-info') -ne 0) { return }
    $info = @([IO.File]::ReadAllText('C:\shell-test\image-info.out') | ConvertFrom-Json)[0]
    if ($info.Id -notmatch '^sha256:([0-9a-f]{64})$') { throw 'Unexpected controller image ID.' }
    $contentHash = $Matches[1].Substring(0,12)
    if (Get-ChildItem -LiteralPath $imageCache -Filter "shell-ansible-$inputHash-*-$contentHash.tar") { return }
    $name = "shell-ansible-$inputHash-$([DateTime]::UtcNow.Ticks)-$contentHash.tar"
    $archive = Join-Path $imageCache $name
    if ((Invoke-Container @('image','save','-o',($archive+'.part'),$tag) 'image-save') -ne 0) {
        throw 'Controller image could not be cached.'
    }
    [IO.File]::Move($archive+'.part', $archive)
}

$configuration=[IO.File]::ReadAllText((Join-Path $repository 'common.json'))|ConvertFrom-Json
$vhd=Join-Path $env:USERPROFILE $configuration.environments.windows.dev_drive.vhd
if ([IO.File]::Exists($vhd)) {
    $Ansible=@{Changed=$false;Result=$null}
    & (Join-Path $repository 'ansible/roles/windows/files/dev_drive.ps1') -Path $vhd
    $before=@{Disk=$Ansible.Result;File=$vhd;Expected=[Environment]::GetEnvironmentVariable('DEV_DRIVE','User');
        Drives=@([IO.DriveInfo]::GetDrives()|ForEach-Object Name)}
    [IO.File]::WriteAllText('C:\shell-test\before-deployment.json',($before|ConvertTo-Json -Depth 5),$utf8)
    Remove-Variable Ansible
}
$timings = @()
$result = @{ Success = $false }
try {
    Import-ControllerCache
    foreach ($mode in ($Modes -split ',')) {
        if ($mode -notin @('init','full','update')) { throw 'Invalid deployment mode.' }
        $index = $timings.Count
        $log = "C:\shell-test\deploy-$index-$mode.log"
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & (Join-Path $repository 'install.ps1') -Mode $mode -StateDirectory $state -CacheDirectory $cache `
            -AnsibleArgument @('-e','@/state/cache.json') *> $log
        if ($LASTEXITCODE -ne 0) { throw "Deployment mode $mode failed ($LASTEXITCODE)." }
        $timings += @{ Mode=$mode; Seconds=[int]$clock.Elapsed.TotalSeconds; Log=$log }
        [IO.File]::WriteAllText('C:\shell-test\timings.json', ($timings | ConvertTo-Json), $utf8)
        # The second full run is the idempotence check. Any changed= on a recap line fails the guest deployment.
        if ($index -gt 0 -and $mode -eq 'full' -and $timings[$index-1].Mode -eq 'full') {
            $text = [IO.File]::ReadAllText($log) -replace '\x1b\[[0-9;]*m',''
            $recaps = [regex]::Matches($text, '(?m)^\S+\s*:\s*ok=\d+\s+changed=(\d+)')
            if (-not $recaps.Count -or @($recaps | Where-Object { $_.Groups[1].Value -ne '0' }).Count) {
                throw 'Repeated full deployment is not idempotent.'
            }
        }
    }
    $result.Success = $true
} catch {
    $result.Error = $_.Exception.Message
    throw
} finally {
    try { Export-ControllerCache } catch { $result.CacheError = $_.Exception.Message }
    [IO.File]::WriteAllText('C:\shell-test\result.json', ($result | ConvertTo-Json), $utf8)
}

if ($result.Success -and (($Modes -split ',')[-1] -eq 'update')) {
    & (Join-Path $repository 'tests/hyperv_verify.ps1') -RestartGuest
}

if ($result.Success -and (($Modes -split ',')[-1] -eq 'full')) {
    & (Join-Path $repository 'tests/hyperv_verify.ps1') -Queue
}
