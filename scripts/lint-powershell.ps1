[CmdletBinding()]
param(
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

    $settings = Import-PowerShellDataFile (Join-Path $repository '.psscriptanalyzer.psd1')
    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $results = Invoke-ScriptAnalyzer -Path $resolved -Settings $settings -Severity Warning, Error
        foreach ($result in $results) {
            '{0}:{1}: [{2}] {3}' -f $file, $result.Line, $result.RuleName, $result.Message
            $failed = $true
        }
    }
    if ($failed) {
        exit 1
    }
}
finally {
    Pop-Location
}
