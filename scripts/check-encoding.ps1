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
        $Path = @(& git ls-files)
    }

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $failed = $false
    foreach ($file in $Path) {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $bytes = [IO.File]::ReadAllBytes($resolved)
        if ($bytes.Length -eq 0 -or $bytes -contains 0) {
            continue
        }

        $bom = ''
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bom = 'UTF-8 BOM'
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $bom = 'UTF-16 LE BOM'
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $bom = 'UTF-16 BE BOM'
        }
        if ($bom) {
            '{0}: {1}' -f $file, $bom
            $failed = $true
            continue
        }

        try {
            $null = $utf8.GetString($bytes)
        }
        catch {
            '{0}: not valid UTF-8' -f $file
            $failed = $true
            continue
        }
        # LF is enforced by .gitattributes on add; only BOM and encoding are checked here.
    }
    if ($failed) {
        exit 1
    }
}
finally {
    Pop-Location
}
