param([string]$Root, [string]$Installer)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Command Processor'
$registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Command Processor', $true)
if (-not $registry) { throw 'Clink AutoRun registry key is missing.' }
$original = $registry.GetValue('AutoRun', $null, 'DoNotExpandEnvironmentNames')
$kind = $registry.GetValueKind('AutoRun')
$batch = (Join-Path $Root 'apps/clink/current/clink.bat').Replace('/', '\')
$expected = '"' + $batch + '" inject --autorun'
if ([Environment]::ExpandEnvironmentVariables($original).IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'Clink autorun was not deployed.'
}

$marker = 'set SHELL_CLINK_TEST=preserved'
$process = $null

try {
    $registry.SetValue('AutoRun', $marker, 'String')
    $Ansible = @{ Changed = $false; CheckMode = $true }
    & $Installer -Root $Root
    if (-not $Ansible.Changed -or $registry.GetValue('AutoRun') -cne $marker) {
        throw 'Clink check mode did not report a change without writing.'
    }

    $Ansible.CheckMode = $false
    & $Installer -Root $Root
    $installed = $registry.GetValue('AutoRun')
    if (-not $Ansible.Changed -or $installed -cne "$marker&$expected") {
        throw 'Clink installation did not preserve the other AutoRun command.'
    }

    & $Installer -Root $Root
    if ($Ansible.Changed -or $registry.GetValue('AutoRun') -cne $installed) {
        throw 'Clink autorun deployment is not idempotent.'
    }

    $custom = "$installed --quiet"
    $registry.SetValue('AutoRun', $custom, 'String')
    & $Installer -Root $Root
    if ($Ansible.Changed -or $registry.GetValue('AutoRun') -cne $custom) {
        throw 'Existing Clink options were changed.'
    }

    $env:HOME = [Environment]::GetEnvironmentVariable('HOME', 'User')
    $env:PATH = (Join-Path $Root 'shims') + ';' + $env:PATH
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/q', '/k' -WindowStyle Hidden -PassThru
    $module = $null
    for ($attempt = 0; $attempt -lt 40 -and -not $module; $attempt++) {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw 'The interactive CMD exited before Clink loaded.' }
        $module = @((Get-Process -Id $process.Id).Modules |
            Where-Object ModuleName -Like 'clink_dll_*.dll')
    }
    if (-not $module) { throw 'The interactive CMD did not load Clink automatically.' }
    'Clink preview, AutoRun preservation, idempotence, custom options and interactive injection passed.'
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $registry.SetValue('AutoRun', $original, $kind)
    $registry.Close()
}
