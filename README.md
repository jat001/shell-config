# Shell 共享配置

Windows、WSL 和 MSYS2 用同一套配置。
各 shell 的 profile 或 rc 只留一行入口，初始化和具体设置都在这个目录。

## 前提

在 Windows 上运行安装器。
需要能提供 `wslc.exe` 的 WSL。Ansible 跑在 WSL 容器里，连 Windows 也走第一个发行版，所以不能一个发行版都不留。
要开开发人员模式，否则普通权限建不了符号链接。
发行版列表在 `common.json`，当前是 `archlinux` 和 `Debian`。第一项会设成默认发行版。
MSYS2 默认装到开发盘的 `msys2`。盘符不写死，挂上之后记在用户环境变量 `DEV_DRIVE`。

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
`-WslDistribution`、`-Msys2Root` 改发行版或 MSYS2 位置。
`-WslDevDriveOnly` 只处理 WSL 共享开发盘。
`-WindowsHome` 把配置部署到另一个 Windows 用户目录。目标就是当前账户时，才设置这个账户的 `HOME`。
`-CacheDirectory` 指定 WSL 和 Windows 的下载缓存，默认 `%LOCALAPPDATA%\shell-ansible\cache`。下完的文件下次直接用。下载中断会再试。

安装 WSL、打开开发人员模式、创建或附加开发盘、注册开发盘任务时，会申请一次管理员权限。
Scoop、MSYS2 和用户配置在普通权限下进行。安装器不重启电脑。

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
Debian 装 Nushell 时会写下 `env.nu` 和 `config.nu`。
和这台机器上的 `nu` 生成的默认文件一样，`full` 会换成入口。改过的文件让这一组停下。
