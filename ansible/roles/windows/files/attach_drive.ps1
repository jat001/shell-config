[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Path, [string]$LegacyKey, [switch]$AllowDetach)

$ErrorActionPreference = 'Stop'
$Path = [IO.Path]::GetFullPath($Path)
if (-not [IO.File]::Exists($Path) -or $Path -notlike '*.vhdx') { throw 'Expected an existing VHDX.' }
if (-not $PSCmdlet.ShouldProcess($Path,'Attach the VHDX now and at Windows startup')) { return }

Add-Type -Namespace Shell -Name BootAttach -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
struct Storage { public int Device; public Guid Vendor; }
[StructLayout(LayoutKind.Sequential)]
struct OpenParameters {
    public int Version; public int Info; public int ReadOnly;
    public Guid Resiliency; public Guid Snapshot;
}
[StructLayout(LayoutKind.Sequential)]
struct AttachParameters { public int Version; public int Reserved; }
[StructLayout(LayoutKind.Sequential, Pack=4)]
struct Privileges { public int Count; public long Luid; public int Attributes; }

[DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
[DllImport("advapi32.dll", SetLastError=true)]
static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
[DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
static extern bool LookupPrivilegeValue(string system, string name, out long luid);
[DllImport("advapi32.dll", SetLastError=true)]
static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref Privileges values,
    int size, IntPtr previous, IntPtr returned);
[DllImport("virtdisk.dll", CharSet=CharSet.Unicode)]
static extern int OpenVirtualDisk(ref Storage type, string path, int access, int flags,
    ref OpenParameters parameters, out Microsoft.Win32.SafeHandles.SafeFileHandle handle);
[DllImport("virtdisk.dll")]
static extern int AttachVirtualDisk(Microsoft.Win32.SafeHandles.SafeFileHandle handle,
    IntPtr security, int flags, int provider, ref AttachParameters parameters, IntPtr overlapped);

public static void Attach(string path) {
    IntPtr token;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    try {
        long luid;
        if (!LookupPrivilegeValue(null, "SeManageVolumePrivilege", out luid)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        var privilege = new Privileges { Count=1, Luid=luid, Attributes=2 };
        if (!AdjustTokenPrivileges(token, false, ref privilege, 0, IntPtr.Zero, IntPtr.Zero) ||
            Marshal.GetLastWin32Error() == 1300) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    } finally { CloseHandle(token); }
    var type = new Storage();
    var open = new OpenParameters { Version=2 };
    Microsoft.Win32.SafeHandles.SafeFileHandle handle;
    int error = OpenVirtualDisk(ref type, path, 0, 0, ref open, out handle);
    if (error != 0) { throw new System.ComponentModel.Win32Exception(error); }
    using (handle) {
        var attach = new AttachParameters { Version=1 };
        error = AttachVirtualDisk(handle, IntPtr.Zero, 0x404, 0, ref attach, IntPtr.Zero);
        if (error != 0) { throw new System.ComponentModel.Win32Exception(error); }
    }
}
'@

$key='HKLM:\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks'
$legacy=@(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue | Where-Object {
    $_.GetValue('Path') -eq $Path -and $_.PSChildName -eq $LegacyKey -and
    @($_.GetValueNames()).Count -eq 1
})
$detached = $false
try {
    if ($AllowDetach -and $legacy.Count) {
        Dismount-DiskImage -ImagePath $Path
        $detached = $true
    }
    foreach($entry in $legacy){ Remove-Item -LiteralPath $entry.PSPath }
    [Shell.BootAttach]::Attach($Path)
} catch {
    foreach($entry in $legacy){
        $restored=New-Item -Path (Join-Path $key $entry.PSChildName) -Force
        $null=New-ItemProperty -LiteralPath $restored.PSPath -Name Path -Value $Path -PropertyType String -Force
    }
    if ($detached) { Mount-DiskImage -ImagePath $Path | Out-Null }
    throw
}
