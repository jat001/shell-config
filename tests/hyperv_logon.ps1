[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Clear')][string]$Action = 'Clear',
    [string]$UserName,
    [string]$Password,
    [ValidateRange(1, 10)][int]$Count = 2
)

$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Model -ne 'Virtual Machine' -or $computer.Manufacturer -ne 'Microsoft Corporation' -or
    $env:COMPUTERNAME -ne 'SHELLCONFIGTEST') {
    throw 'Test login changes are restricted to the ShellConfigTest guest.'
}
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "$Action temporary test logon")) { return }

function Clear-TestLogonSecret {
    if ('ShellTest.LogonSecret' -as [type]) { [ShellTest.LogonSecret]::Clear(); return }
    Add-Type -Namespace ShellTest -Name LogonSecret -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
struct Attributes {
    public int Length; public IntPtr Root; public IntPtr Name;
    public uint Flags; public IntPtr Security; public IntPtr Quality;
}
[StructLayout(LayoutKind.Sequential)]
struct UnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
[DllImport("advapi32.dll")]
static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr policy);
[DllImport("advapi32.dll")]
static extern uint LsaStorePrivateData(IntPtr policy, ref UnicodeString key, IntPtr value);
[DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
[DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
public static void Clear() {
    var attributes = new Attributes();
    attributes.Length = Marshal.SizeOf(typeof(Attributes));
    IntPtr policy;
    uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policy);
    if (status != 0) { throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(status)); }
    IntPtr text = Marshal.StringToHGlobalUni("DefaultPassword");
    try {
        var key = new UnicodeString { Length=30, MaximumLength=32, Buffer=text };
        status = LsaStorePrivateData(policy, ref key, IntPtr.Zero);
        uint error = LsaNtStatusToWinError(status);
        if (error != 0 && error != 2) { throw new System.ComponentModel.Win32Exception((int)error); }
    } finally { Marshal.FreeHGlobal(text); LsaClose(policy); }
}
'@
    [ShellTest.LogonSecret]::Clear()
}
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if ($Action -eq 'Enable') {
    if (-not $UserName -or -not $Password) { throw 'Test account credentials are required.' }
    Set-ItemProperty -LiteralPath $key -Name DefaultUserName -Value $UserName
    Set-ItemProperty -LiteralPath $key -Name DefaultDomainName -Value $env:COMPUTERNAME
    Set-ItemProperty -LiteralPath $key -Name DefaultPassword -Value $Password
    Set-ItemProperty -LiteralPath $key -Name AutoLogonCount -Value $Count -Type DWord
    Set-ItemProperty -LiteralPath $key -Name AutoAdminLogon -Value '1'
    @{ AutoLoginEnabled = $true; Count = $Count }
} else {
    Set-ItemProperty -LiteralPath $key -Name AutoAdminLogon -Value '0'
    Set-ItemProperty -LiteralPath $key -Name AutoLogonCount -Value 0 -Type DWord
    Remove-ItemProperty -LiteralPath $key -Name DefaultPassword -ErrorAction SilentlyContinue
    Clear-TestLogonSecret
    @{ AutoLoginDisabled = $true; StoredLogonSecretRemoved = $true
        RegistryPasswordRemoved = -not [bool](Get-ItemProperty -LiteralPath $key).DefaultPassword }
}
