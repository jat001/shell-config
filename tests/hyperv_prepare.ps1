[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('All', 'Host', 'Create', 'Baselines')][string]$Stage = 'All',
    [string]$StateDirectory,
    [string]$Repository,
    [string]$IsoSource,
    [string]$IsoLanguage = (Get-Culture).Name,
    [ValidatePattern('^$|^[A-Fa-f0-9]{64}$')][string]$IsoSha256,
    [string]$Name = 'ShellConfig-Test',
    [string]$UserName = 'ShellTest',
    [ValidateRange(4, 128)][int]$MemoryGiB = 16,
    [ValidateRange(2, 64)][int]$ProcessorCount = 8,
    [ValidateRange(64, 2048)][int]$SystemDiskGiB = 128,
    [ValidateRange(1, 100)][int]$ImageIndex = 1,
    [string]$SwitchName = 'Default Switch',
    [string]$ElevatedRequest
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
if (-not $StateDirectory) {
    $StateDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/shell-ansible-test/hyperv'
}
if ($ElevatedRequest) {
    $request = [IO.File]::ReadAllText($ElevatedRequest) | ConvertFrom-Json
    $Stage = $request.Stage
    $StateDirectory = $request.StateDirectory
    $Repository = $request.Repository
    $Name = $request.Name
    $UserName = $request.UserName
    $MemoryGiB = $request.MemoryGiB
    $ProcessorCount = $request.ProcessorCount
    $SystemDiskGiB = $request.SystemDiskGiB
    $ImageIndex = $request.ImageIndex
    $SwitchName = $request.SwitchName
}
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$Repository = [IO.Path]::GetFullPath($Repository)
$mediaDirectory = Join-Path $StateDirectory 'media'
$cacheDirectory = Join-Path $StateDirectory 'cache/downloads'
$identityPath = Join-Path $StateDirectory 'vm-created.json'
$credentialPath = Join-Path $StateDirectory 'guest-credential.xml'
$resultPath = Join-Path $StateDirectory 'prepare-result.json'
$progressPath = Join-Path $StateDirectory 'prepare-progress.json'
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
    $UserName -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}$') {
    throw 'Invalid test VM or account name.'
}
if ($Stage -notin @('All', 'Host', 'Create', 'Baselines') -or
    $MemoryGiB -lt 4 -or $MemoryGiB -gt 128 -or $ProcessorCount -lt 2 -or $ProcessorCount -gt 64 -or
    $SystemDiskGiB -lt 64 -or $SystemDiskGiB -gt 2048 -or $ImageIndex -lt 1 -or $ImageIndex -gt 100) {
    throw 'Invalid Hyper-V preparation parameters.'
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This Hyper-V test image preparation currently supports x64 hosts and x64 Windows images.'
}
if (-not $PSCmdlet.ShouldProcess($Name, "Prepare Hyper-V test environment ($Stage)")) { return }
$null = [IO.Directory]::CreateDirectory($StateDirectory)

function Write-ProgressFile {
    param([string]$Phase)
    [IO.File]::WriteAllText($progressPath, (@{ Phase = $Phase; Updated = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json), $utf8)
}

function Protect-StateDirectory {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            'S-1-5-18'
            'S-1-5-32-544'
        )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StateDirectory -AclObject $acl
}

function Get-CachedIso {
    $null = [IO.Directory]::CreateDirectory($mediaDirectory)
    if (-not $IsoSource) {
        $candidates = @(Get-ChildItem -LiteralPath $mediaDirectory -Filter '*.iso' -File)
        if ($candidates.Count -gt 1) { throw 'Specify -IsoSource when more than one cached ISO is available.' }
        if ($candidates.Count -eq 1) { $IsoSource = $candidates[0].FullName }
        else { $IsoSource = Get-OfficialIsoUrl $IsoLanguage }
    }
    if ($IsoSource) {
        $uri = $null
        $remote = [uri]::TryCreate($IsoSource, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('https', 'http')
        if ($remote) {
            if ($uri.Scheme -ne 'https') { throw 'Use an HTTPS ISO download URL.' }
            $path = Join-Path $mediaDirectory 'windows.iso'
            $sourceRecord = Join-Path $mediaDirectory 'windows.iso.source.json'
            if ([IO.File]::Exists($path)) {
                if (-not [IO.File]::Exists($sourceRecord) -or
                    ([IO.File]::ReadAllText($sourceRecord) | ConvertFrom-Json).Url -cne $IsoSource) {
                    throw 'The cached ISO belongs to a different source; choose a separate state directory.'
                }
            }
            else {
                & curl.exe --fail --location --retry 3 --continue-at - --output ($path + '.part') $IsoSource
                if ($LASTEXITCODE -ne 0) { throw "Windows ISO download failed ($LASTEXITCODE); the partial file is retained for resume." }
                [IO.File]::Move($path + '.part', $path)
                [IO.File]::WriteAllText($sourceRecord, (@{ Url = $IsoSource } | ConvertTo-Json), $utf8)
            }
        }
        else { $path = [IO.Path]::GetFullPath($IsoSource) }
    }
    if (-not [IO.File]::Exists($path)) { throw "Windows ISO was not found: $path" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $recordPath = $path + '.sha256.json'
    if ($IsoSha256 -and $hash -ine $IsoSha256) { throw 'The Windows ISO does not match -IsoSha256.' }
    if ([IO.File]::Exists($recordPath) -and
        ([IO.File]::ReadAllText($recordPath) | ConvertFrom-Json).Hash -ine $hash) {
        throw 'The Windows ISO changed since it was cached.'
    }
    [IO.File]::WriteAllText($recordPath, (@{ Algorithm = 'SHA256'; Hash = $hash; Path = $path } | ConvertTo-Json), $utf8)
    $path
}

function Get-OfficialIsoUrl {
    param([string]$Language)

    $labels = @{
        'en-US'='English (United States)'; 'en-GB'='English (Great Britain)'
        'zh-CN'='Chinese (Simplified)'; 'zh-TW'='Chinese (Traditional)'
        'fr-FR'='French'; 'de-DE'='German'; 'it-IT'='Italian'; 'ja-JP'='Japanese'
        'ko-KR'='Korean'; 'pt-BR'='Portuguese (Brazil)'; 'es-ES'='Spanish'
    }
    $label = if ($labels.ContainsKey($Language)) { $labels[$Language] } else { $labels['en-US'] }
    $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise'
    $row = [regex]::Matches($page.Content, '(?is)<tr\b[^>]*>.*?</tr>') |
        Where-Object { $_.Value -match ([regex]::Escape($label) + '\s*</th>') } | Select-Object -First 1
    if (-not $row) { throw "The official Windows evaluation download page has no row for $label." }
    $link = [regex]::Match($row.Value, 'href="(https://go\.microsoft\.com/fwlink/[^"<>]+)"')
    if (-not $link.Success) { throw 'The official Windows evaluation ISO link could not be resolved.' }
    [Net.WebUtility]::HtmlDecode($link.Groups[1].Value)
}

function Test-ContainerArchive {
    param([string]$Path)
    $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
    if (-not [IO.File]::Exists($tar)) { return $true }
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $entries = @(& $tar -tf $Path 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        $names = @($entries | ForEach-Object { $_ -replace '^\./', '' })
        return ($names -contains 'manifest.json') -and ($names -contains 'index.json')
    }
    finally { $ErrorActionPreference = $preference }
}

function Wait-Guest {
    param([pscredential]$Credential)
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $connection = $null
        $ready = $false
        try {
            $connection = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
            $ready = Invoke-Command -Session $connection -ScriptBlock {
                (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -eq 'IMAGE_STATE_COMPLETE'
            }
            if ($ready) { return $connection }
        }
        catch { Write-Verbose 'Connection probe failed; retrying.' } finally {
            if ($connection -and -not $ready) { Remove-PSSession $connection }
        }
        Start-Sleep -Seconds 5
    }
    throw 'The guest did not finish Windows setup or become available through PowerShell Direct.'
}

function Wait-Settled {
    param([object]$Connection, [pscredential]$Credential)
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    $stableSince = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $state = $null
        try {
            if (-not $Connection) { $Connection = Wait-Guest $Credential }
            $state = Invoke-Command -Session $Connection -ScriptBlock {
                $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
                $oobe = @(Get-Process -Name CloudExperienceHostBroker -ErrorAction SilentlyContinue).Count
                $lastShutdown = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074 } -MaxEvents 1 `
                    -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TimeCreated
                [pscustomobject]@{ Boot = $boot; Oobe = $oobe; LastShutdown = $lastShutdown }
            }
        }
        catch {
            if ($Connection) { Remove-PSSession $Connection -ErrorAction SilentlyContinue }
            $Connection = $null
            $state = $null
        }
        if ($state) {
            $now = [DateTime]::UtcNow
            $quiet = if ($state.LastShutdown) { ($now - $state.LastShutdown.ToUniversalTime()).TotalMinutes } else { 999 }
            $up = ($now - $state.Boot).TotalMinutes
            # OOBE reboots the guest several times after ImageState becomes COMPLETE.
            if ($state.Oobe -eq 0 -and $up -ge 3 -and $quiet -ge 3) {
                if (-not $stableSince) { $stableSince = $now }
                elseif (($now - $stableSince).TotalMinutes -ge 2) { return $Connection }
            }
            else { $stableSince = $null }
        }
        Start-Sleep -Seconds 10
    }
    throw 'The guest did not settle after Windows setup.'
}

function Save-Baseline {
    param([string]$Baseline)
    if (Get-VMSnapshot -VMName $Name -Name $Baseline -ErrorAction SilentlyContinue) { return }
    Stop-VM -Name $Name
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while ((Get-VM -Name $Name).State -ne 'Off') {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'The test VM did not shut down cleanly.' }
        Start-Sleep -Seconds 2
    }
    Checkpoint-VM -Name $Name -SnapshotName $Baseline
    Start-VM -Name $Name
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $ElevatedRequest) {
    Protect-StateDirectory
    Write-ProgressFile 'Resolve and cache installation media'
    [IO.File]::WriteAllText($resultPath, (@{ Success = $false; Stage = $Stage; Status = 'Preparing' } | ConvertTo-Json), $utf8)
    $iso = if ($Stage -in @('All', 'Create')) { Get-CachedIso } else { $null }
    $msi = if ($Stage -in @('All', 'Baselines')) {
        & (Join-Path $Repository 'ansible/bootstrap/wsl.ps1') -Cache $cacheDirectory -DownloadOnly
    }
    else { $null }
    $request = [ordered]@{
        Stage=$Stage; StateDirectory=$StateDirectory; Repository=$Repository; Name=$Name; UserName=$UserName
        MemoryGiB=$MemoryGiB; ProcessorCount=$ProcessorCount; SystemDiskGiB=$SystemDiskGiB
        ImageIndex=$ImageIndex; SwitchName=$SwitchName; Iso=$iso; WslMsi=$msi
    }
    $requestPath = Join-Path $StateDirectory ('prepare-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json), $utf8)
    $start = @{
        FilePath     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
            '-ElevatedRequest', ('"' + $requestPath + '"'))
        WindowStyle  = 'Hidden'
        Wait         = $true
        PassThru     = $true
    }
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $start.Verb = 'RunAs' }
    $process = Start-Process @start
    if ($process.ExitCode -ne 0) { throw "Hyper-V preparation failed ($($process.ExitCode)); see $resultPath" }
    return [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
}
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Hyper-V preparation requires an administrator process.'
}

$result = @{ Success = $false; Stage = $Stage; Name = $Name }
$connection = $null
try {
    Write-ProgressFile 'Host prerequisites'
    if ($Stage -in @('All', 'Host')) {
        $features = @('Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services',
            'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Management-Clients')
        $states = @($features | ForEach-Object { Get-WindowsOptionalFeature -Online -FeatureName $_ })
        $missing = @($states | Where-Object State -NotIn @('Enabled', 'EnablePending') | ForEach-Object FeatureName)
        $restart = [bool]($states | Where-Object State -EQ 'EnablePending')
        if ($missing.Count) {
            $enabled = Enable-WindowsOptionalFeature -Online -FeatureName $missing -All -NoRestart
            $restart = $restart -or $enabled.RestartNeeded
        }
        $result.RestartNeeded = $restart
        if ($restart) { throw 'Restart Windows, then repeat preparation; the cached downloads will be reused.' }
        Start-Service vmms
    }
    if ($Stage -eq 'Host') {
        $result.Success = $true
        Write-ProgressFile 'Complete'
        return
    }
    Import-Module Hyper-V
    if ([IO.File]::Exists($identityPath) -and
        ([IO.File]::ReadAllText($identityPath) | ConvertFrom-Json).Name -ne $Name) {
        throw 'This state directory belongs to another VM; use a separate state directory.'
    }
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($vm) {
        $identity = if ([IO.File]::Exists($identityPath)) {
            [IO.File]::ReadAllText($identityPath) | ConvertFrom-Json
        }
        $owned = $identity -and $identity.Name -eq $Name -and
        ([string]$vm.Id -eq [string]$identity.Id)
        if ($owned) {
            $owned = @(Get-VMHardDiskDrive -VMName $vm.Name | Where-Object {
                    $_.Path -and -not [IO.File]::Exists([string]$_.Path)
                }).Count -eq 0
        }
        if (-not $owned) {
            # Only a VM whose files live in this state directory is a disposable test VM.
            $configPath = if ($vm.Path) { [IO.Path]::GetFullPath([string]$vm.Path) } else { '' }
            if (-not $configPath.StartsWith(($StateDirectory + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A VM already uses this name outside the test state directory; refusing to replace it.'
            }
            Write-ProgressFile 'Replace the previous test VM'
            $diskPaths = @()
            if ($vm.State -ne 'Off') { Stop-VM -Name $vm.Name -TurnOff -Force -Confirm:$false }
            foreach ($drive in Get-VMHardDiskDrive -VMName $vm.Name) {
                if ($drive.Path) { $diskPaths += [string]$drive.Path }
            }
            Remove-VM -Name $vm.Name -Force -Confirm:$false
            foreach ($diskPath in $diskPaths) {
                if ([IO.File]::Exists($diskPath) -and
                    [IO.Path]::GetFullPath($diskPath).StartsWith(
                        ($StateDirectory + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                    [IO.File]::Delete($diskPath)
                }
            }
            $vm = $null
        }
    }
    if ($Stage -in @('All', 'Create') -and -not $vm) {
        Write-ProgressFile 'Apply Windows image to a new system VHDX'
        $directory = Join-Path $StateDirectory $Name
        $vhd = Join-Path $directory 'system.vhdx'
        if ([IO.File]::Exists($vhd)) {
            # The test disk is disposable, but never pull it out from under another VM.
            $attached = @(Get-VM | ForEach-Object {
                    $candidate = $_
                    Get-VMHardDiskDrive -VMName $candidate.Name | Where-Object {
                        $_.Path -and [IO.Path]::GetFullPath([string]$_.Path) -eq $vhd
                    } | ForEach-Object { $candidate.Name }
                })
            if ($attached.Count) {
                throw "The system VHDX is attached to another VM: $($attached -join ', ')."
            }
            Remove-Item -LiteralPath $vhd -Force
        }
        $null = [IO.Directory]::CreateDirectory($directory)
        $mounted = $false
        $isoMounted = $false
        try {
            $image = Mount-DiskImage -ImagePath $request.Iso -PassThru
            $isoMounted = $true
            $media = ($image | Get-Volume).DriveLetter + ':\'
            $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $media 'setup.exe')
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw 'The Windows installer does not have a valid Microsoft signature.'
            }
            $wim = Join-Path $media 'sources/install.wim'
            $windowsImage = Get-WindowsImage -ImagePath $wim -Index $ImageIndex
            $imageVersion = [version]$windowsImage.Version
            if ($windowsImage.Architecture -ne 9 -or $imageVersion.Major -ne 10 -or
                $imageVersion.Build -lt 22000) { throw 'Choose an x64 Windows 11 image.' }
            $random = New-Object byte[] 24
            $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $generator.GetBytes($random) } finally { $generator.Dispose() }
            $password = [Convert]::ToBase64String($random) + 'aA1!'
            $credential = [pscredential]::new($UserName, (ConvertTo-SecureString $password -AsPlainText -Force))
            $credential | Export-Clixml -LiteralPath $credentialPath
            $null = New-VHD -Path $vhd -SizeBytes ([long]$SystemDiskGiB * 1GB) -Dynamic
            $disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
            $mounted = $true
            if (@($disk).Count -ne 1 -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'RAW' -or
                $disk.Size -ne [long]$SystemDiskGiB * 1GB) { throw 'Refusing to initialize an unexpected system disk.' }
            $disk | Initialize-Disk -PartitionStyle GPT
            $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
            $efi | Format-Volume -FileSystem FAT32 -Confirm:$false | Out-Null
            $null = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
            $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            $os | Format-Volume -FileSystem NTFS -Confirm:$false | Out-Null
            $apply = $os.DriveLetter + ':\'
            $null = Expand-WindowsImage -ImagePath $wim -Index $ImageIndex -ApplyPath $apply
            & (Join-Path $apply 'Windows/System32/bcdboot.exe') (Join-Path $apply 'Windows') /s ($efi.DriveLetter + ':') /f UEFI
            if ($LASTEXITCODE -ne 0) { throw 'Guest EFI boot preparation failed.' }
            $escaped = [Security.SecurityElement]::Escape($password)
            $language = ([string]@($windowsImage.Languages)[0] -split '\s|\(')[0]
            $timeZone = (Get-TimeZone).Id
            $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>ShellConfigTest</ComputerName>
      <TimeZone>$timeZone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$language</InputLocale>
      <SystemLocale>$language</SystemLocale>
      <UILanguage>$language</UILanguage>
      <UserLocale>$language</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$UserName</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$escaped</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
            $panther = Join-Path $apply 'Windows/Panther'
            $null = [IO.Directory]::CreateDirectory($panther)
            [IO.File]::WriteAllText((Join-Path $panther 'Unattend.xml'), $unattend, $utf8)
            $password = $null; $escaped = $null; $unattend = $null
        }
        finally {
            if ($mounted) { Dismount-VHD -Path $vhd }
            if ($isoMounted) { Dismount-DiskImage -ImagePath $request.Iso }
        }
        $switch = Get-VMSwitch -Name $SwitchName
        $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([long]$MemoryGiB * 1GB) `
            -VHDPath $vhd -Path $directory -SwitchName $switch.Name
        Set-VMProcessor -VM $vm -Count $ProcessorCount -ExposeVirtualizationExtensions $true
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
        Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType ProductionOnly
        Set-VMFirmware -VM $vm -EnableSecureBoot On
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
        Enable-VMTPM -VM $vm
        [IO.File]::WriteAllText($identityPath, (@{ Name=$Name; Id=[string]$vm.Id;
                    Image=$windowsImage.ImageName; Credential='guest-credential.xml'; UserName=$UserName
                } | ConvertTo-Json), $utf8)
        Start-VM -VM $vm
    }
    if ($Stage -in @('All', 'Create', 'Baselines')) {
        if (-not $vm) { throw 'Create the test VM before preparing baselines.' }
        $credential = Import-Clixml -LiteralPath $credentialPath
        $vm = Get-VM -Name $Name
        if ($vm.State -eq 'Off') { Start-VM -VM $vm }
        Write-ProgressFile 'Wait for Windows setup and save Clean-Windows'
        $connection = Wait-Guest $credential
        Write-ProgressFile 'Wait for Windows setup to settle'
        $connection = Wait-Settled $connection $credential
        Invoke-Command -Session $connection -ScriptBlock {
            $null = [IO.Directory]::CreateDirectory('C:\shell-test')
            foreach ($path in @('C:\Windows\Panther\Unattend.xml', 'C:\Windows\Panther\Unattend\Unattend.xml')) {
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
        }
        if (-not (Get-VMSnapshot -VMName $Name -Name Clean-Windows -ErrorAction SilentlyContinue)) {
            $alreadyInstalled = Invoke-Command -Session $connection -ScriptBlock {
                [IO.File]::Exists((Join-Path $env:ProgramFiles 'WSL/wslc.exe'))
            }
            if ($alreadyInstalled) { throw 'The guest already has WSL; refusing to label it as Clean-Windows.' }
        }
        Remove-PSSession $connection; $connection = $null
        Save-Baseline 'Clean-Windows'
        $connection = Wait-Guest $credential
        if ($Stage -ne 'Create' -and
            -not (Get-VMSnapshot -VMName $Name -Name WSL-Ready -ErrorAction SilentlyContinue)) {
            Write-ProgressFile 'Install cached WSL runtime in the test guest'
            # Complete VirtualMachinePlatform servicing before the MSI creates WSLService.
            $restartNeeded = Invoke-Command -Session $connection -ScriptBlock {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
                if ($feature.State -in @('Enabled', 'EnablePending')) {
                    return $feature.State -eq 'EnablePending'
                }
                $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
                return [bool]$result.RestartNeeded
            }
            if ($restartNeeded) {
                Write-ProgressFile 'Restart the guest after enabling VirtualMachinePlatform'
                Remove-PSSession $connection; $connection = $null
                Stop-VM -Name $Name
                $deadline = [DateTime]::UtcNow.AddMinutes(5)
                while ((Get-VM -Name $Name).State -ne 'Off') {
                    if ([DateTime]::UtcNow -gt $deadline) { throw 'The test VM did not shut down cleanly.' }
                    Start-Sleep -Seconds 2
                }
                Start-VM -Name $Name
                $connection = Wait-Guest $credential
            }
            $guestRepository = Invoke-Command -Session $connection -ScriptBlock {
                $path = Join-Path $env:USERPROFILE '.config/shell'
                $null = [IO.Directory]::CreateDirectory((Join-Path $path 'ansible/bootstrap'))
                $path
            }
            $guestBootstrap = Join-Path $guestRepository 'ansible/bootstrap/wsl.ps1'
            Copy-Item -LiteralPath (Join-Path $Repository 'ansible/bootstrap/wsl.ps1') -ToSession $connection -Destination $guestBootstrap -Force
            $msiRelative = $request.WslMsi.Substring($cacheDirectory.TrimEnd('\').Length + 1)
            $guestMsi = Join-Path 'C:\shell-cache' $msiRelative
            Invoke-Command -Session $connection -ArgumentList $guestMsi -ScriptBlock {
                param($Path)
                $null = [IO.Directory]::CreateDirectory((Split-Path $Path))
            }
            Copy-Item -LiteralPath $request.WslMsi -ToSession $connection -Destination $guestMsi -Force
            $exitCode = Invoke-Command -Session $connection -ArgumentList $guestBootstrap, $guestMsi -ScriptBlock {
                param($Bootstrap, $Msi)
                $process = Start-Process powershell.exe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Bootstrap + '"'),
                    '-Package', ('"' + $Msi + '"'), '-Log', 'C:\shell-test\wsl-msi.log'
                )
                $process.ExitCode
            }
            if ($exitCode -notin @(0, 3010)) { throw "Guest WSL installation failed ($exitCode)." }
            Remove-PSSession $connection; $connection = $null
            Stop-VM -Name $Name; Start-VM -Name $Name
            $connection = Wait-Guest $credential
            $helloCache = Join-Path $cacheDirectory 'images/hello-world.tar'
            if ([IO.File]::Exists($helloCache) -and -not (Test-ContainerArchive $helloCache)) {
                [IO.File]::Delete($helloCache)
            }
            if (-not [IO.File]::Exists($helloCache)) {
                # Let the host pull and save the image so a fresh cache needs no guest network.
                $hostWslc = Join-Path $env:ProgramFiles 'WSL/wslc.exe'
                if ([IO.File]::Exists($hostWslc)) {
                    Write-ProgressFile 'Cache the hello-world container image'
                    $preference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        for ($attempt = 1; $attempt -le 3; $attempt++) {
                            & $hostWslc run --rm hello-world
                            if ($LASTEXITCODE -eq 0) { break }
                            Start-Sleep -Seconds (5 * $attempt)
                        }
                        if ($LASTEXITCODE -eq 0) {
                            & $hostWslc image save -o $helloCache hello-world
                            if ($LASTEXITCODE -ne 0) { [IO.File]::Delete($helloCache) }
                        }
                    }
                    catch {
                        if ([IO.File]::Exists($helloCache)) { [IO.File]::Delete($helloCache) }
                    }
                    finally { $ErrorActionPreference = $preference }
                    if ([IO.File]::Exists($helloCache) -and -not (Test-ContainerArchive $helloCache)) {
                        [IO.File]::Delete($helloCache)
                    }
                }
            }
            if ([IO.File]::Exists($helloCache)) {
                Copy-Item -LiteralPath $helloCache -ToSession $connection -Destination C:\shell-test\hello-world.tar -Force
            }
            Write-ProgressFile 'Verify nested WSL containers'
            Invoke-Command -Session $connection -ScriptBlock {
                # wslc reports progress on stderr; only the exit code decides success.
                $ErrorActionPreference = 'Continue'
                $wslc = Join-Path $env:ProgramFiles 'WSL/wslc.exe'
                & "$env:SystemRoot\System32\wsl.exe" --version
                if ($LASTEXITCODE -ne 0) { throw 'WSL is not ready after reboot.' }
                if ([IO.File]::Exists('C:\shell-test\hello-world.tar')) {
                    & $wslc image load -i C:\shell-test\hello-world.tar
                    if ($LASTEXITCODE -ne 0) { throw 'The cached hello-world image could not be loaded.' }
                }
                & $wslc run --rm hello-world
                if ($LASTEXITCODE -ne 0) { throw 'Nested WSL container verification failed.' }
                & $wslc image save -o C:\shell-test\hello-world.tar hello-world
                if ($LASTEXITCODE -ne 0) { throw 'The hello-world image could not be cached.' }
            } | Out-Null
            $null = [IO.Directory]::CreateDirectory((Split-Path $helloCache))
            Copy-Item -FromSession $connection -LiteralPath C:\shell-test\hello-world.tar -Destination $helloCache -Force
            Remove-PSSession $connection; $connection = $null
            Save-Baseline 'WSL-Ready'
        }
    }
    $result.Success = $true
    Write-ProgressFile 'Complete'
}
catch {
    $result.Error = $_.Exception.Message
    throw
}
finally {
    if ($connection) { Remove-PSSession $connection }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 4), $utf8)
}
