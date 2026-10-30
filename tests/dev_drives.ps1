param(
    [string]$Directory = (Join-Path $env:TEMP ('shell-dev-drives-' + [guid]::NewGuid())),
    [ValidateRange(50, 65536)][int]$SizeGiB = 50,
    [string]$Distribution
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run these disk provisioning tests from an elevated PowerShell session.'
}
$Directory = [IO.Path]::GetFullPath($Directory)
if (Test-Path -LiteralPath $Directory) { throw 'Choose a new test directory.' }
$creator = Join-Path $PSScriptRoot '../ansible/roles/windows/files/create_drive.ps1'
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$mountName = 'shell-test-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$linux = if ($Distribution) { @('-d',$Distribution) } else { @() }

foreach ($filesystem in 'ReFS','btrfs') {
    $path = Join-Path $Directory "$filesystem.vhdx"
    $directoryExisted = Test-Path -LiteralPath $Directory
    # WhatIf has to be first. A later success must not hide a preview that already created the disk.
    & $creator -Path $path -FileSystem $filesystem -SizeGiB $SizeGiB -Distribution $Distribution -WhatIf
    if ([IO.File]::Exists($path) -or (-not $directoryExisted -and (Test-Path -LiteralPath $Directory))) {
        throw 'Preview created a filesystem entry.'
    }
    & $creator -Path $path -FileSystem $filesystem -SizeGiB $SizeGiB -Distribution $Distribution
    if (-not [IO.File]::Exists($path)) { throw 'No VHDX was published.' }

    if ($filesystem -eq 'ReFS') {
        $disk = Mount-DiskImage -ImagePath $path -PassThru
        try {
            $volume = $disk | Get-Disk | Get-Partition | Get-Volume | Where-Object DriveLetter
            if ($volume.FileSystemType -ne 'ReFS') { throw 'Expected ReFS.' }
            & fsutil.exe devdrv query ($volume.DriveLetter + ':')
            if ($LASTEXITCODE -ne 0) { throw 'The volume is not a Dev Drive.' }
        } finally { Dismount-DiskImage -ImagePath $path | Out-Null }
    } else {
        & $wsl --mount --vhd $path --type btrfs --name $mountName --options compress=zstd:1
        if ($LASTEXITCODE -ne 0) { throw 'Btrfs mount failed.' }
        try {
            & $wsl @linux -u root --exec touch "/mnt/wsl/$mountName/.write-test"
            if ($LASTEXITCODE -ne 0) { throw 'Btrfs is not writable.' }
            & $wsl @linux -u root --exec rm "/mnt/wsl/$mountName/.write-test"
            if ($LASTEXITCODE -ne 0) { throw 'Btrfs test-file cleanup failed.' }
        } finally { & $wsl --unmount $path }
    }

    $hash = (Get-FileHash -LiteralPath $path).Hash
    & $creator -Path $path -FileSystem $filesystem -SizeGiB $SizeGiB -Distribution $Distribution
    if ((Get-FileHash -LiteralPath $path).Hash -ne $hash) { throw 'Existing VHDX was modified.' }
    "$filesystem provisioning, mount and repeat passed: $path"
}
