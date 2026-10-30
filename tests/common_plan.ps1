$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$jq = (Get-Command jq -ErrorAction SilentlyContinue).Source
if (-not $jq) { throw 'jq is required to test the shared plan.' }
$filter = Join-Path $repository 'common.jq'
$data = Join-Path $repository 'common.json'
$planHome = '/home/shell'
$windowsHome = '/mnt/c/Users/shell'

function Invoke-Jq {
    param([string]$Arguments, [hashtable]$Environment)

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $jq
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @('MSYSTEM', 'WSL_DISTRO_NAME', 'WSL_INTEROP', 'XDG_RUNTIME_DIR')) {
        $start.EnvironmentVariables[$name] = ''
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $start.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }
    $process = [Diagnostics.Process]::Start($start)
    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "jq failed ($($process.ExitCode)): $errorOutput" }
    $output
}

function Get-Plan {
    param([string]$Mounts, [switch]$OmitMounts)

    $arguments = "-r --arg platform wsl --arg home $planHome --arg windows_home $windowsHome"
    if (-not $OmitMounts) { $arguments += " --arg mounts `"$Mounts`"" }
    $arguments += " --arg mode plan -f `"$filter`" `"$data`""
    Invoke-Jq $arguments @{ XDG_RUNTIME_DIR = '/run/user/1000' } | ConvertFrom-Json
}

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # An empty native argument disappears, so --arg consumes the filter and jq -n prints null.
    $dropped = & $jq -n --arg v '' '$v'
    if ($dropped -ne 'null') { throw "An empty native argument was preserved: $dropped" }
}

$omitted = Get-Plan -OmitMounts
$empty = Get-Plan -Mounts ''
foreach ($plan in @($omitted, $empty)) {
    if ($plan.environment.XDG_DATA_HOME -ne "$planHome/.local/share") {
        throw "Unmounted data directory: $($plan.environment.XDG_DATA_HOME)"
    }
    if ($plan.environment.XDG_CACHE_HOME -ne "$planHome/.cache") {
        throw "Unmounted cache directory: $($plan.environment.XDG_CACHE_HOME)"
    }
    if ($plan.environment.PSObject.Properties.Name -contains 'DEV_DRIVE') {
        throw 'DEV_DRIVE is set although the drive is not mounted.'
    }
}

$ext4 = Get-Plan -Mounts '/dev/sdx /mnt/wsl/dev ext4 rw 0 0'
if ($ext4.environment.XDG_CACHE_HOME -ne "$planHome/.cache") {
    throw "A different filesystem was treated as the development drive: $($ext4.environment.XDG_CACHE_HOME)"
}

$mounted = Get-Plan -Mounts '/dev/sdx /mnt/wsl/dev btrfs rw 0 0'
if ($mounted.environment.XDG_STATE_HOME -ne "/mnt/wsl/dev$planHome/.local/state") {
    throw "Mounted state directory: $($mounted.environment.XDG_STATE_HOME)"
}
if ($mounted.environment.PNPM_HOME -ne "/mnt/wsl/dev$planHome/.local/share/pnpm") {
    throw "Mounted pnpm directory: $($mounted.environment.PNPM_HOME)"
}
if ($mounted.environment.OMP_CACHE_DIR -ne "$planHome/.cache") {
    throw "Prompt cache followed the development drive: $($mounted.environment.OMP_CACHE_DIR)"
}

$linux = (Invoke-Jq "-r --arg platform Linux --arg home $planHome --arg mode platform -f `"$filter`" `"$data`"" @{
    WSL_DISTRO_NAME = ''; WSL_INTEROP = ''; MSYSTEM = ''
}).Trim()
if ($linux) { throw "Empty WSL variables selected platform '$linux'." }

$wsl = (Invoke-Jq "-r --arg platform Linux --arg home $planHome --arg mode platform -f `"$filter`" `"$data`"" @{
    WSL_DISTRO_NAME = 'Debian'; WSL_INTEROP = ''; MSYSTEM = ''
}).Trim()
if ($wsl -ne 'wsl') { throw "WSL was not detected: '$wsl'." }

$mingw = (Invoke-Jq "-r --arg platform MINGW64_NT --arg home $planHome --arg mode platform -f `"$filter`" `"$data`"" @{
    MSYSTEM = ''; WSL_DISTRO_NAME = ''; WSL_INTEROP = ''
}).Trim()
if ($mingw) { throw "An empty MSYSTEM selected platform '$mingw'." }

$msys = (Invoke-Jq "-r --arg platform MINGW64_NT --arg home $planHome --arg mode platform -f `"$filter`" `"$data`"" @{
    MSYSTEM = 'UCRT64'; WSL_DISTRO_NAME = ''; WSL_INTEROP = ''
}).Trim()
if ($msys -ne 'msys2') { throw "MSYS2 was not detected: '$msys'." }

"PowerShell $($PSVersionTable.PSVersion): empty arguments, unmounted drive, and platform detection passed."
