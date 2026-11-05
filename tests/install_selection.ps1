[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$script:configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$configured = @($configuration.environments.wsl.distributions)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'install.ps1'), [ref]$tokens, [ref]$errors
)
if ($errors) { throw ($errors -join "`n") }
foreach ($function in @('Get-WslDisplayName', 'Resolve-WslDistributionSelection', 'Initialize-WslDistributions')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $function
        }, $true)
    if (-not $definition) { throw "The $function function is missing." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Every install, cache and registry operation below is a test double; no WSL executable is started.
$script:wsl = 'Invoke-SelectionTestWsl'
$script:commands = [Collections.Generic.List[object]]::new()
$script:downloads = [Collections.Generic.List[string]]::new()
$script:oobe = [Collections.Generic.List[string]]::new()
$script:registered = [Collections.Generic.List[string]]::new()
$script:defaultDistribution = 'Unselected'
$script:exitCode = 0
$script:progressPrinted = $false

function Get-CachedDistribution {
    param([string]$Name)
    $script:downloads.Add($Name)
    if ($Name -eq 'FedoraLinux-45') { 'C:\test-cache\fedora.wsl' }
}

function Get-WslRegistration {
    foreach ($name in $script:registered) {
        [pscustomobject]@{ DistributionName = $name; PSChildName = "mock-$name"; PSPath = "mock:$name" }
    }
}

function Get-ItemProperty {
    [pscustomobject]@{ DefaultDistribution = "mock-$script:defaultDistribution" }
}

function Set-ItemProperty {
    param([string]$LiteralPath, [string]$Name, [int]$Value)
    if ($LiteralPath -notlike 'mock:*' -or $Name -ne 'RunOOBE' -or $Value -ne 0) { throw 'Unexpected registry update.' }
    $script:oobe.Add($LiteralPath)
}

function Invoke-SelectionTestWsl {
    $command = @($args | ForEach-Object { [string]$_ })
    $script:commands.Add($command)
    $global:LASTEXITCODE = $script:exitCode
    if ($script:exitCode) { return }
    if ($command[0] -eq '--install') {
        $index = [array]::IndexOf($command, '--name')
        if ($index -lt 0) { $index = [array]::IndexOf($command, '--distribution') }
        if ($index -lt 0 -or $command -notcontains '--no-launch') { throw 'Invalid install arguments.' }
        $script:registered.Add($command[$index + 1])
        if (-not $script:progressPrinted) {
            'Native install progress must not become a distribution name.'
            $script:progressPrinted = $true
        }
    }
    elseif ($command[0] -eq '--set-default') { $script:defaultDistribution = $command[1] }
    else { throw "Unexpected WSL command: $($command -join ' ')" }
}

function Reset-SelectionTest {
    param([string[]]$Registered = @('Unselected'))
    $script:commands.Clear()
    $script:downloads.Clear()
    $script:oobe.Clear()
    $script:registered.Clear()
    foreach ($name in $Registered) { $script:registered.Add($name) }
    $script:defaultDistribution = 'Unselected'
    $script:exitCode = 0
}

$all = @(Resolve-WslDistributionSelection -Distribution $configured -Available $configured)
if (($all -join '|') -cne ($configured -join '|')) { throw 'The default selection is not all four distributions in order.' }
for ($mask = 1; $mask -lt 16; $mask++) {
    $expected = @(for ($index = 0; $index -lt $configured.Count; $index++) {
            if ($mask -band (1 -shl $index)) { $configured[$index] }
        })
    $requested = @($expected | Sort-Object -Descending | ForEach-Object { $_.ToUpperInvariant(); $_ })
    $selected = @(Resolve-WslDistributionSelection -Distribution $requested -Available $configured)
    if (($selected -join '|') -cne ($expected -join '|')) { throw "Subset $mask was not normalized correctly." }
    Reset-SelectionTest
    $active = @(Initialize-WslDistributions -Distribution $selected -Registered @($script:registered))
    if (($active -join '|') -cne ($expected -join '|') -or
        ($script:downloads -join '|') -cne ($expected -join '|') -or
        $script:oobe.Count -ne $expected.Count -or $script:defaultDistribution -cne $expected[0]) {
        throw "Subset $mask installed or selected the wrong distributions."
    }
    if ($selected -contains 'FedoraLinux-45') {
        $cached = @($script:commands | Where-Object { $_ -contains '--from-file' })
        if ($cached.Count -ne 1 -or $cached[0] -notcontains 'C:\test-cache\fedora.wsl') { throw 'The cached image was not used.' }
    }
    $script:commands.Clear()
    $script:downloads.Clear()
    $script:oobe.Clear()
    $repeated = @(Initialize-WslDistributions -Distribution $selected -Registered @($script:registered))
    if (($repeated -join '|') -cne ($expected -join '|') -or $script:commands.Count -or
        $script:downloads.Count -or $script:oobe.Count) { throw "Subset $mask was not idempotent." }
}

foreach ($invalid in @(@(), @(''), @(' '), @('Debian', ''), @('unknown'), @('docker-desktop'))) {
    $rejected = $false
    try { $null = Resolve-WslDistributionSelection -Distribution $invalid -Available $configured } catch { $rejected = $true }
    if (-not $rejected) { throw 'An empty or unknown distribution selection was accepted.' }
}
$custom = @(Resolve-WslDistributionSelection -Distribution @(' custom ') -Available ($configured + 'Custom'))
if ($custom.Count -ne 1 -or $custom[0] -cne 'Custom') { throw 'An already registered custom distribution was not preserved.' }

Reset-SelectionTest -Registered @('archlinux', 'Unselected')
$active = @(Initialize-WslDistributions -Distribution @('archlinux', 'Debian') -Registered @($script:registered) -WhatIf)
if (($active -join '|') -cne 'archlinux' -or $script:commands.Count -or $script:downloads.Count -or $script:oobe.Count) {
    throw 'WhatIf installed or changed a distribution.'
}
Reset-SelectionTest
$script:exitCode = 42
$rejected = $false
try { $null = Initialize-WslDistributions -Distribution @('Debian') -Registered @($script:registered) } catch { $rejected = $true }
if (-not $rejected -or $script:oobe.Count -or $script:commands.Count -ne 1) { throw 'An install failure was ignored.' }
Reset-SelectionTest
$rejected = $false
try { $null = Initialize-WslDistributions -Distribution @() -Registered @($script:registered) } catch { $rejected = $true }
if (-not $rejected -or $script:commands.Count) { throw 'Installation continued without a selected transport distribution.' }

"PowerShell $($PSVersionTable.PSVersion): all 15 WSL subsets, minimum selection, default distribution, cache, WhatIf and failures passed."
