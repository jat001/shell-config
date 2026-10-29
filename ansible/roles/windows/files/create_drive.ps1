[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateRange(50, 65536)][int]$SizeGiB,
    [Parameter(Mandatory)][ValidateSet('ReFS', 'btrfs')][string]$FileSystem,
    [string]$Distribution
)

$ErrorActionPreference = 'Stop'
$ansibleContext = Get-Variable -Name Ansible -ValueOnly -ErrorAction SilentlyContinue
if ($ansibleContext) { $ansibleContext.Changed = $false }
$Path = [IO.Path]::GetFullPath($Path)
if ([IO.File]::Exists($Path)) { return }
if ([IO.Directory]::Exists($Path)) { throw "A directory occupies the VHDX path: $Path" }
if ($Path -notlike '*.vhdx' -or $Path -match '["\r\n]') { throw 'Invalid VHDX path.' }
if ($ansibleContext) {
    $ansibleContext.Changed = $true
    if ($ansibleContext.CheckMode) { return }
}
if (-not $PSCmdlet.ShouldProcess($Path, "Create $SizeGiB GiB dynamic $FileSystem development disk")) { return }

[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
$temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([guid]::NewGuid().ToString() + '.new.vhdx')
$diskpart = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.diskpart.txt')
$attached = $false
$wsl = Join-Path $env:SystemRoot 'System32/wsl.exe'
$env:WSL_UTF8 = '1'

function Invoke-DiskPart {
    param([string[]]$Commands)
    [IO.File]::WriteAllLines($diskpart, $Commands, [Text.UTF8Encoding]::new($false))
    $output = & diskpart.exe /s $diskpart 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "DiskPart failed: $output" }
    Write-Verbose $output
}

function Invoke-Linux {
    param([string]$Script, [string[]]$Arguments = @())
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '^[A-Za-z0-9/_-]+$') { throw 'Invalid disk preparation argument.' }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r", '')))
    $command = "echo $encoded | base64 -d | sh -s -- " + ($Arguments -join ' ')
    $output = & $wsl -d $Distribution -u root --exec sh -c $command
    if ($LASTEXITCODE -ne 0) { throw "WSL disk preparation failed ($LASTEXITCODE): $($output -join ' ')" }
    ($output -join "`n").Trim()
}

try {
    if ($FileSystem -eq 'btrfs') {
        if (-not $Distribution) {
            $Distribution = (& $wsl --exec printenv WSL_DISTRO_NAME | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $Distribution) { throw 'No WSL distribution is available.' }
        }
        $null = Invoke-Linux @'
set -eu
if ! command -v mkfs.btrfs >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends btrfs-progs >&2
    elif command -v pacman >/dev/null; then
        pacman -Syu --needed --noconfirm btrfs-progs >&2
    else
        echo 'Install btrfs-progs before provisioning the shared disk.' >&2
        exit 1
    fi
fi
command -v mkfs.btrfs >/dev/null
'@
        $before = @((Invoke-Linux 'lsblk -dnro NAME') -split "`n")
    }

    Invoke-DiskPart @("create vdisk file=`"$temporary`" maximum=$($SizeGiB * 1024) type=expandable")
    if (-not [IO.File]::Exists($temporary)) { throw 'DiskPart did not create the VHDX.' }

    if ($FileSystem -eq 'ReFS') {
        $disk = Mount-DiskImage -ImagePath $temporary -PassThru | Get-Disk
        $attached = $true
        if (-not $disk -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'RAW') {
            throw 'The new VHDX did not resolve to a single empty data disk.'
        }
        if ($disk.Size -ne [long]$SizeGiB * 1GB) { throw 'Unexpected virtual disk capacity.' }
        $partition = $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -UseMaximumSize -AssignDriveLetter
        $null = $partition | Format-Volume -DevDrive -NewFileSystemLabel Dev -Confirm:$false
        Dismount-DiskImage -ImagePath $temporary
        $attached = $false
    } else {
        & $wsl --mount --vhd $temporary --bare
        if ($LASTEXITCODE -ne 0) { throw 'Could not attach the new VHDX to WSL.' }
        $attached = $true
        $after = @( (Invoke-Linux 'lsblk -dnro NAME') -split "`n")
        $new = @($after | Where-Object { $_ -notin $before })
        if ($new.Count -ne 1 -or $new[0] -notmatch '^sd[a-z]+$') {
            throw 'Could not identify exactly one newly attached WSL data disk.'
        }
        $device = '/dev/' + $new[0]
        $script = @'
set -eu
device=$1
expected=$2
test "$(blockdev --getsize64 "$device")" = "$expected"
test "$(lsblk -nr -o NAME "$device" | wc -l)" -eq 1
test -z "$(lsblk -nr -o MOUNTPOINTS,FSTYPE "$device" | tr -d '[:space:]')"
test -z "$(wipefs --noheadings --output TYPE "$device")"
mkfs.btrfs -L dev "$device"
blkid -s UUID -o value "$device"
'@
        Invoke-Linux $script @($device, [string]([long]$SizeGiB * 1GB))
        & $wsl --unmount $temporary
        if ($LASTEXITCODE -ne 0) { throw 'Could not detach the newly formatted VHDX.' }
        $attached = $false
    }
    [IO.File]::Move($temporary, $Path)
} finally {
    if ($attached) {
        if ($FileSystem -eq 'btrfs') { & $wsl --unmount $temporary }
        else { Dismount-DiskImage -ImagePath $temporary -ErrorAction Continue }
    }
    if ([IO.File]::Exists($diskpart)) { [IO.File]::Delete($diskpart) }
}
