# Shell 共享配置

Windows、WSL 和 MSYS2 使用同一套 shell 配置。
各 shell 自己的 profile 或 rc 只保留一行加载入口，初始化逻辑和具体设置都在本目录。

## 前提

- 在 Windows 上运行安装器。
- 已安装提供 `wslc.exe` 的 WSL。控制用的 Ansible 跑在 WSL 容器里，Windows 的连接也由第一个 WSL 发行版转发，所以不能一个发行版都不留。
- 开启开发人员模式，否则普通权限创建不了符号链接。
- 默认管理 `common.json` 里列出的 WSL 发行版，当前是 `archlinux` 和 `Debian`，第一项会设为默认发行版。
- MSYS2 默认装到开发盘的 `msys2` 目录。开发盘的盘符不写死，附加之后记在用户环境变量 `DEV_DRIVE` 里。

## 安装和更新

```powershell
& "$HOME/.config/shell/install.ps1" -Mode init
& "$HOME/.config/shell/install.ps1" -Mode full
& "$HOME/.config/shell/install.ps1" -Mode update
```

| 模式 | 做什么 |
|---|---|
| `init` | 第一次使用。打开开发人员模式，准备开发盘，安装 Scoop、MSYS2、终端、shell 和字体等前置软件。不部署 shell 入口。 |
| `full` | `init` 的全部内容，再加上入口、共享链接、用户级 `HOME`、WSL 与 Windows Terminal 设置。 |
| `update` | 同步配置并升级已经由这里管理的软件，跳过一次性初始化。 |

新机器先 `init`，再 `full`。之后改配置或升级软件用 `update`。

只看会改什么、先不改机器：

```powershell
& "$HOME/.config/shell/install.ps1" -WhatIf
```

常用参数：

- `-SkipMsys2`、`-SkipWsl`：跳过对应环境。`-SkipWsl` 仍会留下一个发行版来连接 Windows。
- `-WslDistribution`、`-Msys2Root`：改 WSL 发行版或 MSYS2 位置。
- `-WslDevDriveOnly`：只处理 WSL 共享开发盘。
- `-WindowsHome`：把配置部署到另一个 Windows 用户目录。只有目标就是当前账户时，才会设置这个账户的 `HOME`。
- `-CacheDirectory`：同时指定 WSL 与 Windows 的下载缓存。不指定时用 `%LOCALAPPDATA%\shell-ansible\cache`。中断的下载会再试，已经下完的文件会直接复用。

安装器会在需要时申请一次管理员权限，用来安装 WSL、打开开发人员模式、创建或附加开发盘、注册 WSL 开发盘任务。Scoop、MSYS2 和用户配置在普通权限下进行。安装器不会自动重启电脑。

已经存在、而且内容和入口不一致的配置文件会让这一组停止，原文件保留。空目录、指向别处的链接，以及和发行版模板完全相同的默认 dotfile，会被换成这里的入口。已经用别的方式装好的同名命令不会被接管。

## 日常修改

改完后新开一个对应的 shell。

- 各环境共用的环境变量、PATH 前置目录和外部命令 alias 写在 `common.json`。带参数或管道的命令不要写在这里，写到对应 shell 的 common 文件里。
- zsh 插件只改 `zsh_plugins.txt`。
- 提示符主题在 `oh-my-posh/`。各 shell 通过 PATH 找 `oh-my-posh`，不要在脚本里写死它的路径。
- MSYS2 里的 `docker` 是指向 Windows Docker Desktop CLI 的 alias。Docker 不在默认位置时，只改这个 alias。
- WSL 上 Oh My Posh 和 wsl2-ssh-agent 由每天一次的更新任务维护。看日志：`journalctl -u shell-releases-update.service`。

支持的 shell 是 Bash、zsh、fish、PowerShell、Nushell 和 CMD（通过 Clink）。MSYS2 不部署 PowerShell 和 Nushell 入口。

## 现在的边界

- 引用了还不存在的变量时，shell 初始化会报错，不会静默跳过。
- WSL 共享开发盘没挂上时，数据目录留在本机；挂上之后才会用开发盘上的目录。
- Debian 的 Nushell 包在安装时会写入一份默认的 `env.nu` 和 `config.nu`。内容和当前这个 `nu` 生成的默认文件完全一致时，`full` 会换成这里的入口。改过的文件会让这一组停止，原文件保留。
- 安装器不重复安装已经存在的 WSL 运行时，也不在更新时重做开发人员模式和建盘。
