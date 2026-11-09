# Shell 共享配置

Windows、WSL 和 MSYS2 用同一套配置。
各 shell 的 profile 或 rc 只留一行入口，初始化和具体设置都在这个目录。

## 前提

在 Windows 上运行安装器。
需要能提供 `wslc.exe` 的 WSL。Ansible 跑在 WSL 容器里，连 Windows 也走第一个发行版，所以不能一个发行版都不留。
要开开发人员模式，否则普通权限建不了符号链接。
发行版列表在 `common.json`，按字母序为 Arch Linux、Debian Testing、Fedora Linux 和 openSUSE Tumbleweed。默认全装，也可用 `-WslDistribution` 选择其中一个或多个；所选项按字母序排列，第一项会设成默认发行版并承载 Windows 连接。
对应的 WSL 注册名是 `archlinux`、`Debian`、`FedoraLinux-45` 和 `openSUSE-Tumbleweed`；友好名称单独配置在 `distribution_names`。
Debian Testing 是展示名称；普通安装仍使用 `Debian` 镜像的 stable，隔离回归使用 testing。
安装器从 Microsoft 的 WSL 发行版索引 `DistributionInfo.json` 获取 Fedora Linux 45 的镜像地址和 SHA256。
Fedora Linux 45 默认 Python 3.15，当前 ansible-core 2.22 直接支持，不需要另装解释器。
MSYS2 默认装到开发盘的 `msys2`。盘符不写死，挂上之后记在用户环境变量 `DEV_DRIVE`。

部署在刷新软件包索引前，将 APT、pacman（含 MSYS2）、Zypper 和 DNF 源里的 HTTP 地址切换为 HTTPS。Fedora Linux 官方 metalink 也只请求 HTTPS 镜像。精简 Debian Testing 缺少 CA 证书包时，首次 APT 刷新临时使用控制容器的 CA 证书。

加 `-UseCernet` 使用教育网联合镜像站。Arch Linux（含 Arch Linux CN）和 MSYS2 用原生 `CacheServer` 优先下载 CERNET 的包，数据库使用原来的官方服务器；Debian Testing 用 CERNET 的 APT mirrorlist，安全源带 `official_index=1`；Fedora Linux 和 openSUSE Tumbleweed 用 CERNET 的 RPM mirrorlist。镜像选择和下载回退由 CERNET 与包管理器处理。普通 Debian Testing 源、Fedora Linux 和 openSUSE Tumbleweed 的索引来自候选镜像；Debian Testing 安全源优先读取官方索引，官方不可达时 APT 仍可能尝试镜像索引。

`-UseCernet` 作用于本次所选发行版和启用的 MSYS2。每次调用按本次参数配置，省略开关会恢复本项目管理的 CERNET 配置到官方源；`-SkipWsl` 保留传输发行版的镜像选择。可用 `install.ps1 -Mode full -UseCernet -WhatIf` 预览。隔离回归也支持 `tests/run.ps1 -UseCernet`。

Arch Linux CN 首次用主站引导并导入 keyring，随后安装 `archlinuxcn-mirrorlist-git`，切换到 `Include = /etc/pacman.d/archlinuxcn-mirrorlist`。列表尚未选定服务器时启用官方主站，CERNET 的 `CacheServer` 配置在仓库段中管理。

## 安装和更新

```powershell
& "$HOME/.config/shell/install.ps1" -Mode init
& "$HOME/.config/shell/install.ps1" -Mode full
& "$HOME/.config/shell/install.ps1" -Mode update
```

`init` 给第一次使用：开发人员模式、开发盘、Scoop、MSYS2、终端、shell 和字体。不部署 shell 入口。
`full` 再加上入口、共享链接、用户级 `HOME`、WSL 和 Windows Terminal。
`update` 同步配置，并升级已经由这里管理的软件。开发人员模式和建盘不重做，装过的 WSL 运行时也不重装。

新机器先 `init`，再 `full`。之后改配置或升级软件用 `update`。

只预览、不改机器：

```powershell
& "$HOME/.config/shell/install.ps1" -WhatIf
```

`-SkipMsys2`、`-SkipWsl` 跳过对应环境。`-SkipWsl` 仍留下一个发行版来连 Windows。
`-WslDistribution` 指定要安装和配置的发行版，最少一个。缺少的所选发行版会安装，已有的直接使用；未选中的已安装发行版保留。也可以指定已注册的自定义发行版。
MSYS2 默认安装和配置，传 `-SkipMsys2` 可以跳过，`-Msys2Root` 修改安装位置。安装器不增加选择提示。

例如，只装 Debian Testing 和 Fedora Linux，并跳过 MSYS2：

```powershell
& "$HOME/.config/shell/install.ps1" -Mode full -WslDistribution Debian,FedoraLinux-45 -SkipMsys2
```

只装一个发行版并保留默认 MSYS2 安装：

```powershell
& "$HOME/.config/shell/install.ps1" -Mode full -WslDistribution Debian
```

普通部署中，显式传空列表（例如 `-WslDistribution @()`）、空名称或未知名称会在准备 WSL 和构建容器前报错。每次调用指定本次要处理的列表；不传时恢复默认全选。
`-WslDevDriveOnly` 只处理 WSL 共享开发盘。
`-WslStartMenuOnly` 只同步已注册发行版的开始菜单快捷方式和 WSLg 目录显示名称、图标，不构建控制容器或运行 playbook。
WSLg 目录保留实际注册名，通过 `desktop.ini` 显示友好名称，并复用注册目录的 `shortcut.ico`。已有的 `docker-desktop` 目录显示为 Docker Desktop，图标取自现有 Docker Desktop 快捷方式；Docker 的启动快捷方式仍由 Docker 管理。
上一版生成的纯名称 `desktop.ini` 可以原子升级；其他不同内容的 `desktop.ini` 或占用目录的文件、链接会使整组检查失败。
`-WindowsHome` 把配置部署到另一个 Windows 用户目录。目标就是当前账户时，才设置这个账户的 `HOME`。
`-CacheDirectory` 指定 WSL 和 Windows 的下载缓存，默认 `%LOCALAPPDATA%\shell-ansible\cache`。下完的文件下次直接用。下载中断会再试。

已安装好依赖后，只同步语言和时区：

```powershell
& "$HOME/.config/shell/install.ps1" -Mode full -AnsibleArgument @('--tags', 'regional', '-e', 'shell_regional_only=true')
```

安装 WSL、打开开发人员模式、创建或附加开发盘、注册开发盘任务、调整不同的系统时区时，会申请一次管理员权限。
Scoop、MSYS2 和用户配置在普通权限下进行。安装器不重启电脑。

部署读取运行安装器的 Windows 宿主机时区和当前用户区域格式。Windows 目标同步这两项；各 WSL 目标使用对应的 IANA 时区，生成并启用对应的 UTF-8 `LANG`。MSYS2 沿用 Windows 设置。
非英语环境还会在 `/etc/locale.gen` 启用并生成 `en_US.UTF-8`，但默认 `LANG` 仍是宿主机 locale。
Debian Testing 的 locales postinst 可能把缺失的官方 locale 以注释补到文件末尾；部署固定启用第一处匹配，不会误启用这些末尾注释，重复启用项只保留一条。
Fedora Linux 的 locale 由 `glibc-langpack-*` 提供，同样没有 `/etc/locale.gen`；部署按语言安装对应语言包，并检查目标 locale 已在 `locale -a` 中。
openSUSE Tumbleweed 的 locale 由 `glibc-locale` 预先编译，没有 `/etc/locale.gen`，也不运行 `locale-gen`；部署检查目标 locale 已在 `locale -a` 中。
MSYS2 的时区和 `LANG` 由现有 profile 自动继承 Windows；`LC_ALL` 也通过同一套 `locale -uU` 结果自动设置，不维护单独的 locale profile。宿主机进程已显式设置 `LC_ALL` 时优先沿用，否则使用 Windows Culture 对应的 UTF-8 locale。
WSL 除写入系统 locale 文件外，还在 common shell 中显式导出 `LC_ALL`，确保直接运行 `wsl.exe`、登录 shell、fish、PowerShell 和 Nushell 都能取得它。
这里不同步 Windows 显示语言、输入法列表或非 Unicode 程序的系统区域，也不删除目标上已有的其他 locale。为其他 `-WindowsHome` 部署时不修改当前账户的区域格式。
Windows 时区名通过仓库内的 CLDR 映射转换；未收录的时区或不能明确转换的 Culture 会在部署前报错。
Arch Linux 官方容器若排除了目标 locale 的源文件，部署会添加对应的 pacman 提取例外并重装 `glibc` 恢复它；源文件已存在时不重装。

安装前先检查一整组入口和链接。
相同的留下。内容和入口不同的普通文件，或非空目录，这一组停下，原文件不动。
空目录、指向别处的链接，以及和发行版模板相同的默认 dotfile，换成这里的入口。
别的方式已经装好的同名命令不动。

## 日常修改

改完后新开一个对应的 shell。

环境变量、PATH 前置目录和外部命令 alias 写在 `common.json`。
带参数或管道的命令写到对应 shell 的 common 文件。
zsh 插件只改 `zsh_plugins.txt`。
提示符主题在 `oh-my-posh/`。从 PATH 找 `oh-my-posh`，脚本里不写死路径。
MSYS2 里的 `docker` 指向 Windows Docker Desktop CLI。不在默认位置时改这个 alias。
WSL 上的 Oh My Posh 和 wsl2-ssh-agent 每天更新一次。日志：`journalctl -u shell-releases-update.service`。

Bash、zsh、fish、PowerShell、Nushell，CMD 用 Clink。
MSYS2 不放 PowerShell 和 Nushell 的入口。

引用了还不存在的变量，初始化会报错。
WSL 共享开发盘没挂上时，数据目录留在本机。挂上之后才用盘上的目录。
Debian Testing 装 Nushell 时会写下 `env.nu` 和 `config.nu`。
和这台机器上的 `nu` 生成的默认文件一样，`full` 会换成入口。改过的文件让这一组停下。

## 开发检查

克隆后在新机器上跑一次：

```powershell
pwsh -NoProfile -File scripts/setup-dev.ps1
```

脚本用 Scoop 安装 uv、lefthook、shellcheck、shfmt、ruff、jq、lua 和 nu，再用 uv 安装 yamllint，从 PowerShell Gallery 安装 PSScriptAnalyzer；还会在默认 WSL 发行版里用 pacman、apt 或 zypper 安装 ansible-lint、fish、zsh 和所需 collections。最后执行 `lefthook install`。之后 `git commit` 会自动检查暂存的文件。

- PowerShell：PSScriptAnalyzer 自动格式化并重新暂存，再做静态检查，规则见 `.psscriptanalyzer.psd1`
- Python：Ruff 自动格式化并重新暂存，再做静态检查
- Shell（sh/bash）：shfmt 自动格式化并重新暂存，shellcheck 只检查
- Zsh / Fish：语法检查，本地通过默认 WSL 发行版运行
- YAML：yamllint
- JSON：`.json` 按严格 JSON 校验；带注释的文件必须用 `.jsonc` 扩展名
- Nushell：`nu-check` 语法检查
- jq：执行 `common.jq` 校验
- Lua：`luac -p` 语法检查
- Ansible：ansible-lint，通过默认 WSL 发行版运行
- 编码：UTF-8 无 BOM。LF 由 `.gitattributes` 保证

只跑本地钩子：`lefthook run pre-commit --all-files`。跳过某次提交的检查：`git commit --no-verify`。
CI 在 `.github/workflows/checks.yml` 跑同一套检查，也包括 ansible-lint。

