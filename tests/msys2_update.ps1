param([string]$Repository)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Repository 'ansible/roles/windows/files/msys2.ps1'), [ref]$tokens, [ref]$errors
)
if ($errors) { throw ($errors -join "`n") }
$definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Msys'
    }, $true)
if (-not $definition) { throw 'The MSYS2 command wrapper is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))
$definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-MsysHttpsSources'
    }, $true)
if (-not $definition) { throw 'The MSYS2 repository migration is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-msys-update-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
$bash = Join-Path $temporary 'fake-bash.cmd'
$savedStatus = $env:SHELL_MSYS_TEST_STATUS
$savedMessage = $env:SHELL_MSYS_TEST_MESSAGE
try {
    [IO.File]::WriteAllText($bash, (
            "@echo off`r`necho %SHELL_MSYS_TEST_MESSAGE%`r`nexit /b %SHELL_MSYS_TEST_STATUS%`r`n"
        ), [Text.Encoding]::ASCII)
    $env:SHELL_MSYS_TEST_STATUS = '0'
    $env:SHELL_MSYS_TEST_MESSAGE = 'Successful upgrade'
    if ((Invoke-Msys 'pacman -Syuu --noconfirm').Code -ne 0) { throw 'A successful update failed.' }

    $env:SHELL_MSYS_TEST_STATUS = '1'
    $env:SHELL_MSYS_TEST_MESSAGE = 'To complete this update all MSYS2 processes including this terminal will be closed.'
    if ((Invoke-Msys 'pacman -Syuu --noconfirm' -AllowCoreRestart).Code -ne 1) {
        throw 'The expected core restart was not recognized.'
    }
    foreach ($case in @(
            @{ Status = '1'; Message = $env:SHELL_MSYS_TEST_MESSAGE; Allow = $false },
            @{ Status = '1'; Message = 'Package download failed'; Allow = $true },
            @{ Status = '2'; Message = $env:SHELL_MSYS_TEST_MESSAGE; Allow = $true }
        )) {
        $env:SHELL_MSYS_TEST_STATUS = $case.Status
        $env:SHELL_MSYS_TEST_MESSAGE = $case.Message
        $rejected = $false
        try { $null = Invoke-Msys 'pacman -Syuu --noconfirm' -AllowCoreRestart:$case.Allow } catch {
            if ($_.Exception.Message -notlike 'MSYS2 command failed*') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw 'An unexpected command failure was hidden.' }
    }
    $Root = $temporary
    $null = [IO.Directory]::CreateDirectory((Join-Path $Root 'etc/pacman.d'))
    $mirrorlist = Join-Path $Root 'etc/pacman.d/mirrorlist.mingw'
    $before = "# Server = http://comment.example/`nServer = http://mirror.example/`nServer = https://fallback.example/`n"
    $after = $before.Replace('http://mirror.example/', 'https://mirror.example/')
    [IO.File]::WriteAllText($mirrorlist, $before)
    $Ansible = [pscustomobject]@{ Changed = $false; CheckMode = $true }
    Set-MsysHttpsSources
    if (-not $Ansible.Changed -or [IO.File]::ReadAllText($mirrorlist) -cne $before) {
        throw 'Preview did not report the mirror change without writing it.'
    }
    $Ansible.CheckMode = $false
    $Ansible.Changed = $false
    Set-MsysHttpsSources
    if (-not $Ansible.Changed -or [IO.File]::ReadAllText($mirrorlist) -cne $after) {
        throw 'The mirror migration did not preserve comments and existing HTTPS URLs.'
    }
    $Ansible.Changed = $false
    Set-MsysHttpsSources
    if ($Ansible.Changed) { throw 'The mirror migration changed an already migrated file.' }
    "PowerShell $($PSVersionTable.PSVersion): MSYS2 update and HTTPS mirror checks passed."
}
finally {
    $env:SHELL_MSYS_TEST_STATUS = $savedStatus
    $env:SHELL_MSYS_TEST_MESSAGE = $savedMessage
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
