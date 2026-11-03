[CmdletBinding()]
param(
    [switch]$Check,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
Push-Location $repository
try {
    if (-not $Path) {
        $Path = @(& git ls-files '*.ps1')
    }

    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is missing. Run scripts/setup-dev.ps1 first.'
    }
    Import-Module PSScriptAnalyzer

    $module = Split-Path (Get-Module PSScriptAnalyzer).Path
    $default = Import-PowerShellDataFile (Join-Path $module 'Settings/CodeFormatting.psd1')
    # The default formatter preserves existing trailing whitespace (PSScriptAnalyzer #1992).
    $settings = @{
        IncludeRules = @($default.IncludeRules) + 'PSAvoidTrailingWhitespace'
        Rules        = $default.Rules + @{
            PSAvoidTrailingWhitespace = @{ Enable = $true }
        }
    }

    $utf8 = [Text.UTF8Encoding]::new($false)
    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $text = [IO.File]::ReadAllText($resolved)
        $formatted = (Invoke-Formatter -ScriptDefinition $text -Settings $settings) -replace "`r`n", "`n"
        if ($formatted -cne ($text -replace "`r`n", "`n")) {
            if ($Check) {
                "Would reformat: $file"
                $failed = $true
            }
            else {
                [IO.File]::WriteAllText($resolved, $formatted, $utf8)
            }
        }
    }
    if ($failed) {
        exit 1
    }
}
finally {
    Pop-Location
}
