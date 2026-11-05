[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$script:configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'install.ps1'), [ref]$tokens, [ref]$errors
)
if ($errors) { throw ($errors -join "`n") }
foreach ($function in @('Get-WslDisplayName', 'Set-WslStartMenuFolderNames')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $function
        }, $true)
    if (-not $definition) { throw "The $function function is missing." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-start-menu-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    $names = [ordered]@{}
    foreach ($name in $configuration.environments.wsl.distributions) { $names[$name] = Get-WslDisplayName $name }
    $expected = @('Arch Linux', 'Debian Testing', 'Fedora Linux', 'openSUSE Tumbleweed')
    if (($names.Values -join '|') -cne ($expected -join '|')) { throw 'The display name mapping is incorrect.' }
    if ((Get-WslDisplayName 'Custom-WSL') -cne 'Custom-WSL') { throw 'The custom distribution fallback failed.' }

    $programs = Join-Path $temporary 'Programs'
    $populated = Join-Path $programs 'archlinux'
    $null = [IO.Directory]::CreateDirectory($populated)
    $kept = Join-Path $populated 'application.lnk'
    [IO.File]::WriteAllText($kept, 'keep this application shortcut', $utf8)
    $keptHash = (Get-FileHash -LiteralPath $kept).Hash
    $null = Set-WslStartMenuFolderNames -Programs $programs -Names $names -WhatIf
    if ([IO.File]::Exists((Join-Path $populated 'desktop.ini')) -or
        [IO.Directory]::Exists((Join-Path $programs 'Debian'))) { throw 'WhatIf modified the directories.' }
    if (-not (Set-WslStartMenuFolderNames -Programs $programs -Names $names)) { throw 'The first run reported no change.' }

    $shell = New-Object -ComObject Shell.Application
    $stamps = @{}
    foreach ($name in $names.Keys) {
        $path = Join-Path $programs $name
        $ini = Join-Path $path 'desktop.ini'
        $content = "[.ShellClassInfo]`nLocalizedResourceName=$($names[$name])`n"
        if ($utf8.GetString([IO.File]::ReadAllBytes($ini)) -cne $content) { throw "Unexpected metadata: $name" }
        $required = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        if (([IO.File]::GetAttributes($ini) -band $required) -ne $required -or
            -not ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReadOnly)) {
            throw "The Shell metadata attributes are missing: $name"
        }
        if ($shell.Namespace($path).Self.Name -cne $names[$name]) { throw "The Shell display name is incorrect: $name" }
        $stamps[$name] = [IO.File]::GetLastWriteTimeUtc($ini)
    }
    if ((Get-FileHash -LiteralPath $kept).Hash -ne $keptHash) { throw 'An existing application shortcut changed.' }
    if (Set-WslStartMenuFolderNames -Programs $programs -Names $names) { throw 'The second run reported a change.' }
    foreach ($name in $names.Keys) {
        if ([IO.File]::GetLastWriteTimeUtc((Join-Path (Join-Path $programs $name) 'desktop.ini')) -ne $stamps[$name]) {
            throw "The second run rewrote metadata: $name"
        }
    }

    # Attribute repair must not rewrite matching metadata or remove the directory's other attributes.
    $ini = Join-Path $populated 'desktop.ini'
    [IO.File]::SetAttributes($ini, [IO.FileAttributes]::Normal)
    [IO.File]::SetAttributes($populated, [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Archive)
    if (-not (Set-WslStartMenuFolderNames -Programs $programs -Names $names)) { throw 'Attribute repair reported no change.' }
    if (-not ([IO.File]::GetAttributes($populated) -band [IO.FileAttributes]::Archive) -or
        [IO.File]::GetLastWriteTimeUtc($ini) -ne $stamps['archlinux']) { throw 'Attribute repair changed unrelated metadata.' }

    # A conflict late in the group must leave the earlier missing directory and every existing file untouched.
    foreach ($conflict in @('metadata', 'directory-file', 'metadata-directory')) {
        $root = Join-Path $temporary $conflict
        $debian = Join-Path $root 'Debian'
        $null = [IO.Directory]::CreateDirectory($root)
        if ($conflict -eq 'directory-file') {
            [IO.File]::WriteAllText($debian, 'user file', $utf8)
            $original = $debian
        }
        else {
            $null = [IO.Directory]::CreateDirectory($debian)
            $original = Join-Path $debian 'desktop.ini'
            if ($conflict -eq 'metadata-directory') { $null = [IO.Directory]::CreateDirectory($original) }
            else { [IO.File]::WriteAllText($original, '[.ShellClassInfo]' + "`nLocalizedResourceName=My Debian`n", $utf8) }
        }
        $hash = if ([IO.File]::Exists($original)) { (Get-FileHash -LiteralPath $original).Hash } else { '' }
        $attributes = [IO.File]::GetAttributes($debian)
        $rejected = $false
        try { $null = Set-WslStartMenuFolderNames -Programs $root -Names $names } catch { $rejected = $true }
        if (-not $rejected -or [IO.Directory]::Exists((Join-Path $root 'archlinux')) -or
            [IO.File]::GetAttributes($debian) -ne $attributes -or
            ($hash -and (Get-FileHash -LiteralPath $original).Hash -ne $hash)) {
            throw "A conflict was not preserved: $conflict"
        }
    }
    foreach ($invalid in @('', '..', '../outside', 'trailing.')) {
        $rejected = $false
        try { $null = Set-WslStartMenuFolderNames -Programs $programs -Names @{ $invalid = 'invalid' } } catch { $rejected = $true }
        if (-not $rejected) { throw "An invalid directory name was accepted: $invalid" }
    }
    "PowerShell $($PSVersionTable.PSVersion): WSLg folder display names, WhatIf, idempotence, attribute repair and conflict preservation passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
