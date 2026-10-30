[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path,
    [string]$Settings
)

# Sets the given section keys (JSON, in file order) in an INI file and leaves every other line as it is.
# A CR in the file is itself a change: the rewrite is LF, which is what WSL and .wslconfig consumers read.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$Settings_ = $Settings | ConvertFrom-Json

$lines = [Collections.Generic.List[string]]::new()
if ([IO.File]::Exists($Path)) {
    $Ansible.Changed = [IO.File]::ReadAllText($Path).Contains("`r")
    foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) }
}

foreach ($section in $Settings_.PSObject.Properties.Name) {
    $start = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ieq "[$section]") { $start = $index; break }
    }
    if ($start -lt 0) {
        if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$section]")
        $start = $lines.Count - 1
    }
    $end = $start + 1
    while ($end -lt $lines.Count -and $lines[$end].Trim() -notmatch '^\[.*\]$') { $end++ }

    foreach ($key in $Settings_.$section.PSObject.Properties.Name) {
        $wanted = "$key=$($Settings_.$section.$key)"
        $found = $false
        for ($index = $start + 1; $index -lt $end; $index++) {
            if ($lines[$index] -match '^\s*([^=#;]+?)\s*=' -and $Matches[1] -ieq $key) {
                if ($lines[$index].Trim() -ne $wanted) { $lines[$index] = $wanted; $Ansible.Changed = $true }
                $found = $true
                break
            }
        }
        if (-not $found) {
            $insert = $end
            while ($insert -gt $start + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
            $lines.Insert($insert, $wanted)
            $end++
            $Ansible.Changed = $true
        }
    }
}

if ($Ansible.Changed -and -not $Ansible.CheckMode) {
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}
