[CmdletBinding()]
param(
    [string]$Path,
    [int]$Wait,
    [string]$LegacyKey
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

# Storage CIM (Get-DiskImage, Get-Partition) needs administrator rights and enumerates nothing in
# Windows Sandbox, so the attached disk and its volumes are read through Win32 directly.
Add-Type -Namespace Shell -Name DevDrive -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
struct StorageType { public int DeviceId; public Guid VendorId; }

[StructLayout(LayoutKind.Sequential)]
struct OpenParameters {
    public int Version;
    public int GetInfoOnly;
    public int ReadOnly;
    public Guid ResiliencyGuid;
    public Guid SnapshotId;
}

[StructLayout(LayoutKind.Sequential)]
struct DeviceNumber { public int DeviceType; public int Number; public int PartitionNumber; }

[DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
static extern int OpenVirtualDisk(ref StorageType type, string path, int access, int flags,
    ref OpenParameters parameters, out Microsoft.Win32.SafeHandles.SafeFileHandle handle);

[DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
static extern int GetVirtualDiskPhysicalPath(Microsoft.Win32.SafeHandles.SafeFileHandle handle,
    ref int size, System.Text.StringBuilder path);

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, int access, int share,
    IntPtr security, int disposition, int flags, IntPtr template);

[DllImport("kernel32.dll", SetLastError = true)]
static extern bool DeviceIoControl(Microsoft.Win32.SafeHandles.SafeFileHandle handle, int code,
    IntPtr input, int inputSize, out DeviceNumber output, int outputSize, out int returned, IntPtr overlapped);

public static int GetDiskNumber(string path) {
    var type = new StorageType();
    var parameters = new OpenParameters { Version = 2, GetInfoOnly = 1, ReadOnly = 1 };
    Microsoft.Win32.SafeHandles.SafeFileHandle handle;
    int error = OpenVirtualDisk(ref type, path, 0, 0, ref parameters, out handle);
    if (error != 0) { throw new System.ComponentModel.Win32Exception(error); }
    using (handle) {
        var buffer = new System.Text.StringBuilder(260);
        int size = buffer.Capacity * 2;
        if (GetVirtualDiskPhysicalPath(handle, ref size, buffer) != 0) { return -1; }
        var match = System.Text.RegularExpressions.Regex.Match(buffer.ToString(), @"PhysicalDrive(\d+)$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return match.Success ? int.Parse(match.Groups[1].Value) : -1;
    }
}

public static string GetDriveLetter(int disk) {
    foreach (var drive in System.IO.DriveInfo.GetDrives()) {
        string letter = drive.Name.Substring(0, 2);
        using (var handle = CreateFile(@"\\.\" + letter, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (handle.IsInvalid) { continue; }
            DeviceNumber number;
            int returned;
            if (DeviceIoControl(handle, 0x2D1080, IntPtr.Zero, 0, out number,
                    Marshal.SizeOf(typeof(DeviceNumber)), out returned, IntPtr.Zero) &&
                number.DeviceType == 7 && number.Number == disk) {
                return letter;
            }
        }
    }
    return "";
}
'@

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks'
$registered = [bool](Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue |
    Where-Object { $_.GetValue('Path') -eq $Path })

$disk = [Shell.DevDrive]::GetDiskNumber($Path)
$letter = if ($disk -ge 0) { [Shell.DevDrive]::GetDriveLetter($disk) } else { '' }
for ($elapsed = 0; $disk -ge 0 -and -not $letter -and $elapsed -lt $Wait; $elapsed++) {
    Start-Sleep -Seconds 1
    $letter = [Shell.DevDrive]::GetDriveLetter($disk)
}

$Ansible.Result = @{
    legacy_registration = [bool](Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValue('Path') -eq $Path -and $_.PSChildName -eq $LegacyKey })
    registered = $registered
    attached = $disk -ge 0
    letter = [string]"$letter"
}
