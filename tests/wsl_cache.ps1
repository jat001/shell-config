param(
    [Parameter(Mandatory)][string]$CacheDirectory,
    [string[]]$Distribution = @('archlinux', 'Debian', 'FedoraLinux-45', 'openSUSE-Tumbleweed'),
    [string]$Repository
)

$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path $PSScriptRoot }
$repository = [IO.Path]::GetFullPath($Repository)
# The extracted installer helpers read this configuration from the script scope.
$script:configuration = [IO.File]::ReadAllText((Join-Path $repository 'common.json')) | ConvertFrom-Json
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$bootstrap = Join-Path $repository 'ansible/bootstrap/wsl.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw "Windows PowerShell was not found: $windowsPowerShell" }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'install.ps1'), [ref]$tokens, [ref]$errors
)
if ($errors) { throw ($errors -join "`n") }
foreach ($function in @('Get-WslDisplayName', 'Get-CachedDistribution')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $function
        }, $true)
    if (-not $definition) { throw "The $function function is missing." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# DownloadOnly stops before the elevated install. This test must not enable the Windows feature or install the MSI.
$package = & $bootstrap -Cache $CacheDirectory -DownloadOnly
$stamp = (Get-Item -LiteralPath $package).LastWriteTimeUtc.Ticks
$reused = & $bootstrap -Cache $CacheDirectory -DownloadOnly
if ($reused -ne $package -or (Get-Item -LiteralPath $reused).LastWriteTimeUtc.Ticks -ne $stamp) {
    throw 'The WSL runtime MSI was not reused.'
}
foreach ($name in $Distribution) {
    $display = Get-WslDisplayName $name
    $image = Get-CachedDistribution $name
    if (-not $image) { throw "No cached image was returned for $display." }
    $stamp = (Get-Item -LiteralPath $image).LastWriteTimeUtc.Ticks
    $reused = Get-CachedDistribution $name
    if ($reused -ne $image -or (Get-Item -LiteralPath $image).LastWriteTimeUtc.Ticks -ne $stamp) {
        throw "The cached $display image was not reused."
    }
    "${display}: verified and reused $image"
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shell-wsl-cache-' + [guid]::NewGuid().ToString('N'))
$originalCache = $CacheDirectory
try {
    $relative = $package.Substring($CacheDirectory.TrimEnd('\').Length + 1)
    $invalidPackage = Join-Path $temporary $relative
    $null = [IO.Directory]::CreateDirectory((Split-Path $invalidPackage))
    [IO.File]::WriteAllText($invalidPackage, 'invalid MSI')
    $rejected = $false
    try { & $bootstrap -Cache $temporary -DownloadOnly | Out-Null } catch {
        if ($_.Exception.Message -notlike '*valid Microsoft signature*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'An unsigned runtime package was accepted.' }

    $image = Get-CachedDistribution $Distribution[0]
    $relative = $image.Substring($CacheDirectory.TrimEnd('\').Length + 1)
    $invalidImage = Join-Path $temporary $relative
    $null = [IO.Directory]::CreateDirectory((Split-Path $invalidImage))
    [IO.File]::WriteAllText($invalidImage, '<!DOCTYPE html><title>I Challenge Thee</title>')
    $CacheDirectory = $temporary
    $rejected = $false
    try { Get-CachedDistribution $Distribution[0] | Out-Null } catch {
        if ($_.Exception.Message -notlike '*does not match its published SHA256*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'An HTML page was accepted as a distribution.' }
}
finally {
    $CacheDirectory = $originalCache
    $resolved = [IO.Path]::GetFullPath($temporary)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
"PowerShell $($PSVersionTable.PSVersion): WSL cache reuse and invalid-package rejection passed."
