#!powershell

#AnsibleRequires -CSharpUtil Ansible.Basic

$spec = @{
    options = @{
        items = @{
            type = 'list'
            elements = 'dict'
            required = $true
            options = @{
                path = @{ type = 'str'; required = $true }
                state = @{ type = 'str'; required = $true; choices = 'file', 'directory', 'link' }
                src = @{ type = 'str' }
                content = @{ type = 'str' }
                defaults = @{ type = 'list'; elements = 'str'; default = @() }
                type = @{ type = 'str'; default = 'directory'; choices = 'file', 'directory', 'external' }
            }
        }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$utf8 = [Text.UTF8Encoding]::new($false)

Add-Type -Namespace ShellPaths -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", EntryPoint = "CreateSymbolicLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
[return: MarshalAs(UnmanagedType.U1)]
public static extern bool CreateSymbolicLink(string link, string target, int flags);
'@

function New-SymbolicLink {
    param([string]$Path, [string]$Target, [bool]$Directory)

    # Flag 2 allows the link without elevation when Developer Mode is on. Flag 1 marks a directory link.
    $flags = 2
    if ($Directory) { $flags = $flags -bor 1 }
    if (-not [ShellPaths.Native]::CreateSymbolicLink($Path, $Target, $flags)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}

function Get-PathState {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [Management.Automation.ItemNotFoundException] {
        return @{ Type = 'Missing' }
    }

    if ($item.LinkType -in @('SymbolicLink', 'Junction')) {
        $target = @($item.Target)[0]
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $Path) $target
        }
        return @{
            Type = 'Link'
            Target = [IO.Path]::GetFullPath($target)
            Directory = $item.PSIsContainer
        }
    }

    @{ Type = $(if ($item.PSIsContainer) { 'Directory' } else { 'File' }) }
}

function Read-Content {
    param([string]$Path)

    [IO.File]::ReadAllText($Path).Replace([string][char]13, '').TrimEnd([char]10)
}

function Test-Item {
    param($Item)

    if ($Item.state -eq 'link' -and $Item.path -eq $Item.src) { return @{} }

    $state = Get-PathState $Item.path

    if ($state.Type -eq 'Missing') { return @{ Action = 'create' } }

    if ($Item.type -eq 'external') {
        # Unlike the Linux module, any existing path is a conflict. An empty directory is not replaced.
        if ($state.Type -eq 'Link' -and $state.Target -eq $Item.src) { return @{} }
        return @{ Conflict = 'An existing path occupies a configured link' }
    }

    if ($Item.state -eq 'directory') {
        if ($state.Type -eq 'Directory' -or $state.Directory) { return @{} }
        return @{ Conflict = 'A file occupies a directory destination' }
    }

    if ($Item.state -eq 'file' -or $Item.type -eq 'file') {
        if ($state.Type -eq 'Directory') {
            return @{ Conflict = 'A directory occupies a file destination' }
        }
        if ($state.Type -eq 'Link' -and $state.Target -eq $Item.src) { return @{} }

        try {
            $same = (Read-Content $Item.path) -ceq $Item.content
        } catch {
            $same = $false
        }
        if (-not $same) {
            if ($state.Type -eq 'File' -and $Item.state -eq 'link') {
                $existing = Read-Content $Item.path
                foreach ($default in @($Item.defaults)) {
                    if ($default -and [IO.File]::Exists($default) -and
                        (Read-Content $default) -ceq $existing) {
                        return @{ Action = 'replace'; State = $state }
                    }
                }
            }
            return @{ Conflict = 'Existing file contains other configuration' }
        }
        if ($Item.state -eq 'link') { return @{ Action = 'replace'; State = $state } }
        return @{}
    }

    if ($state.Type -eq 'Link') {
        if ($state.Target -ne $Item.src) { return @{ Action = 'replace'; State = $state } }
        return @{}
    }

    if ($state.Type -ne 'Directory') {
        return @{ Conflict = 'A file occupies a directory destination' }
    }

    if ([IO.Directory]::GetFileSystemEntries($Item.path).Length -gt 0) {
        return @{ Conflict = 'Existing directory is not empty' }
    }

    @{ Action = 'replace'; State = $state }
}

function Install-Item {
    param($Item, $Result)

    $null = [IO.Directory]::CreateDirectory((Split-Path $Item.path))

    if ($Item.state -eq 'directory') {
        $null = [IO.Directory]::CreateDirectory($Item.path)
        return
    }
    if ($Item.state -eq 'file') {
        [IO.File]::WriteAllText($Item.path, $Item.content + [char]10, $utf8)
        return
    }

    $state = $Result.State
    if ($state) {
        if ($state.Type -eq 'Directory' -or $state.Directory) {
            [IO.Directory]::Delete($Item.path)
        } else {
            [IO.File]::Delete($Item.path)
        }
    }

    $directory = $Item.type -eq 'directory' -or
        ($Item.type -eq 'external' -and [IO.Directory]::Exists($Item.src))
    try {
        New-SymbolicLink $Item.path $Item.src $directory
    } catch {
        # The previous object was already removed, so put that exact object back before reporting the failure.
        if ($state.Type -eq 'File') {
            [IO.File]::WriteAllText($Item.path, $Item.content + [char]10, $utf8)
        } elseif ($state.Type -eq 'Link') {
            New-SymbolicLink $Item.path $state.Target ([bool]$state.Directory)
        } elseif ($state.Type -eq 'Directory') {
            $null = [IO.Directory]::CreateDirectory($Item.path)
        }
        throw
    }
}

$planned = [Collections.Generic.List[object]]::new()
$conflicts = [Collections.Generic.List[string]]::new()

foreach ($item in $module.Params.items) {
    $item.path = [IO.Path]::GetFullPath($item.path)
    if ($item.state -eq 'link') {
        if (-not $item.src) { $module.FailJson("Link items require src: $($item.path)") }
        $item.src = [IO.Path]::GetFullPath($item.src)
    }
    if ($null -eq $item.content) { $item.content = '' }

    $result = Test-Item $item
    if ($result.Conflict) {
        $conflicts.Add("$($result.Conflict): $($item.path)")
    } elseif ($result.Action) {
        $planned.Add(@{ Item = $item; Result = $result })
    }
}

if ($conflicts.Count) {
    $module.Result.conflicts = $conflicts.ToArray()
    $module.FailJson($conflicts -join '; ')
}

$module.Result.changes = @(
    foreach ($entry in $planned) {
        @{
            path = $entry.Item.path
            action = $entry.Result.Action
            state = $entry.Item.state
            src = $entry.Item.src
        }
    }
)

if (-not $module.CheckMode) {
    foreach ($entry in $planned) { Install-Item $entry.Item $entry.Result }
}

$module.Result.changed = $planned.Count -gt 0
$module.ExitJson()
