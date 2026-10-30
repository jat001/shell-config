$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '../install.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$resolver = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-Wslc'
}, $true)
if (-not $resolver) { throw 'The WSL container executable resolver is missing.' }
. ([scriptblock]::Create($resolver.Extent.Text))
$wslc = Get-Wslc
if (-not $wslc) { throw 'The installed WSL container executable could not be resolved.' }
$savedPath = $env:PATH
try {
    # A stale process PATH is the case Get-Wslc exists for. System32 alone must still resolve the registered binary.
    $env:PATH = Join-Path $env:SystemRoot 'System32'
    if ((Get-Wslc) -ine $wslc) { throw 'WSL cannot be resolved when the process PATH is stale.' }
} finally { $env:PATH = $savedPath }

$wrapper = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Wslc'
}, $true)
if (-not $wrapper) { throw 'The WSL container wrapper is missing.' }
Invoke-Expression $wrapper.Extent.Text

$image = 'shell-config-missing-' + [guid]::NewGuid().ToString('N')
Invoke-Wslc -AllowFailure image inspect $image *> $null
if ($LASTEXITCODE -eq 0) { throw 'A nonexistent image should not resolve.' }
$failed = $false
try { Invoke-Wslc image inspect $image *> $null } catch { $failed = $true }
if (-not $failed) { throw 'Native failure was not reported.' }
$version = Invoke-Wslc --version
if ($LASTEXITCODE -ne 0 -or -not $version) { throw 'A successful native command failed.' }
"PowerShell $($PSVersionTable.PSVersion): native stderr and explicit exit handling passed."
