# Shell 共享配置

实际配置保存在 `C:\Users\Jat\.config\shell`。
Windows、WSL 和 MSYS2 按运行环境加载同一套配置。
各 shell 的 profile/rc 只保留加载入口，初始化逻辑和具体设置集中在本目录。

## Git 与安装

仓库根目录是 `C:\Users\Jat\.config\shell`，不是整个 `.config`。
仓库保存共用脚本、zsh 插件清单、OMP 主题、安装脚本和维护说明。
`.gitignore` 只忽略本地配置、备份和临时文件，新增配置源码会被 Git 正常发现。
历史、运行缓存和生成文件保存在仓库之外。

OMP 实际文件位于仓库中的 `oh-my-posh/`。
Windows 的 `~/.config/oh-my-posh` 是指向该目录的目录符号链接；
WSL/MSYS2 的同名目录直接链接到仓库中的主题目录。
运行时仍使用 `$HOME/.config/oh-my-posh`，主题的相对继承路径保持不变。

在 Windows PowerShell 5.1 或 PowerShell 7 中预览安装：

```powershell
& "$HOME/.config/shell/install.ps1" -WhatIf
```

确认预览内容后运行：

```powershell
& "$HOME/.config/shell/install.ps1"
```

默认布置当前 Windows 用户、发现到的 Scoop MSYS2，以及默认 WSL 发行版。
MSYS2 主目录从账户数据库读取，WSL 主目录和发行版名从运行环境读取；
不固定 Windows 用户名、MSYS2 HOME 或 WSL 发行版名称。
其他安装位置和多个 WSL 发行版可显式指定：

```powershell
$installation = @{
    Msys2Root = 'D:\msys64'
    WslDistribution = @('archlinux', 'Ubuntu')
}

& "$HOME/.config/shell/install.ps1" @installation
```

`-SkipMsys2`、`-SkipWsl` 用于跳过对应环境。
`-WindowsHome` 可指定配置部署的 Windows 用户主目录；
只有目标为当前账户主目录时，脚本才设置该账户的用户级 `HOME`。
Windows 目录和文件链接均使用 SymbolicLink；
创建这些链接需要 Windows 开发人员模式或相应权限。

安装前会检查全部目标。已有的相同入口和链接保持原样；
内容不同的入口文件或非空的普通目录会导致停止，保留其中的配置。
脚本不递归删除目录，也不生成备份文件；可重复运行。
Windows 的 rc/profile 保持一行实际入口，WSL/MSYS2 链接到它们。
这些运行入口不逐份提交，生成规则集中在 `install.ps1`。

`zsh_plugins.txt` 是版本管理中的实际插件清单。
各环境的 `~/.zsh_plugins.txt` 链接到它，修改插件时编辑仓库中的文件。
Nushell alias、OMP 自动加载脚本、zsh 补全和插件缓存由运行时生成。
历史、日志、下载的插件仓库和构建产物均不提交。

安装前需准备下文列出的 shell 和主要依赖。
安装脚本负责配置部署，不安装软件包或设置 Windows Terminal profiles、Clink 注入。
个人化安装路径目前保留在 `common.json` 和 MSYS2 主题映射中；
部署到其他 Windows 用户或 MSYS2 安装位置时应核对并调整这些路径。

## 维护原则

- 所有平台共用的环境变量和外部命令 alias，集中定义在 `common.json`。
- 各 shell 的历史、按键、补全、提示符和插件初始化，写在对应的 common 文件中。
- 平台识别规则集中在 `common.jq`；各 shell 负责传入自身的平台信息。
- 只保留改变实际行为的设置；删除默认值前，先核对对应平台的实际默认行为。
- 配置文件使用 UTF-8、无 BOM、LF。脚本中的长行拆开，配置块之间保留空行。
- 脚本中不添加说明性注释，维护说明写在本文件。

## 文件分工

| 文件 | 用途 |
|---|---|
| `install.ps1` | 生成 Windows 入口、部署 WSL/MSYS2 链接，支持预览和重复运行。 |
| `zsh_plugins.txt` | zsh 插件清单源码；各环境的标准清单路径链接到此文件。 |
| `systemd/wsl2-ssh-agent.service` | 上游用户服务副本，直接移除了 root 条件。 |
| `common.json` | 共享数据：环境变量、PATH 前置目录和外部命令 alias。 |
| `common.jq` | 平台识别、变量展开，以及 Bash/zsh、fish、PowerShell、Nushell、Clink 的配置转换。 |
| `common.sh` | Bash/zsh 共用的环境加载、初始化文件查找，以及提示符主题选择。 |
| `common.bash` | Bash 交互初始化、历史设置、Oh My Posh 和 ble.sh 配置。传入 `ble` 时只设置 ble.sh。 |
| `common.zsh` | zsh 历史、按键、补全、Oh My Posh 和插件。传入 `environment` 时只加载共享环境。 |
| `common.fish` | fish 的环境加载、前缀历史搜索、按键和 Oh My Posh 初始化。 |
| `common.ps1` | Windows PowerShell 5.1、Windows/WSL PowerShell 7 的环境、PSReadLine、PSCompletions 和提示符。 |
| `common-env.nu` | Nushell 环境加载和 alias 文件生成。 |
| `common.nu` | Nushell 平台检查、生成的 alias 文件加载，以及 Oh My Posh 初始化。 |
| `common.lua` | CMD/Clink 主题位置发现、初始化、UTF-8 代码页、Windows PATH 排序和共享 alias 加载。 |
| `common.clink_settings` | Clink 的提示符选择、主题路径和历史共享设置。 |
| `common.inputrc` | Bash/Clink 的 Readline 铃声设置，以及上下键前缀历史搜索。 |

## 加载入口与共享链接

下面的 `~` 表示对应环境的用户主目录：

| 环境 | 当前主目录 |
|---|---|
| Windows | `C:\Users\Jat` |
| WSL archlinux | `/root` |
| MSYS2 | `/home/Jat`，对应 `C:\Users\Jat\scoop\persist\msys2\home\Jat` |

| 入口文件 | 内容 |
|---|---|
| `~/.bash_profile`、`~/.profile`、`~/.bashrc` | `. "$HOME/.config/shell/common.bash"` |
| `~/.blerc` | `. "$HOME/.config/shell/common.bash" ble` |
| `~/.inputrc` | `$include ~/.config/shell/common.inputrc` |
| `~/.zprofile` | `. "$HOME/.config/shell/common.zsh" environment` |
| `~/.zshrc` | `. "$HOME/.config/shell/common.zsh"` |
| `~/.config/fish/config.fish` | `source "$HOME/.config/shell/common.fish"` |
| Windows 的两个 PowerShell profile，以及 WSL PowerShell profile | `. "$HOME/.config/shell/common.ps1"` |
| Nushell 的 `env.nu` | `source ~/.config/shell/common-env.nu` |
| Nushell 的 `config.nu` | `source ~/.config/shell/common.nu` |
| `%LOCALAPPDATA%\clink\profile.lua` | `dofile(os.getenv("HOME") .. "/.config/shell/common.lua")` |

Windows PowerShell profile 分别位于：

- `C:\Users\Jat\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- `C:\Users\Jat\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`

Windows Nushell 入口位于 `C:\Users\Jat\AppData\Roaming\nushell`。
WSL 对应的入口位于 `~/.config/nushell/`，PowerShell 入口位于
`~/.config/powershell/Microsoft.PowerShell_profile.ps1`，均链接到 Windows 的实际入口文件。

共享目录的链接关系：

实际文件所在的 `C:\Users\Jat\.config\shell` 是普通目录。
MSYS2 的共享目录使用 Windows directory symbolic link（目录符号链接）；
WSL 的共享目录使用 Linux/POSIX 符号链接。
这里的 Windows 配置链接类型为 `SymbolicLink`，不是 directory junction。

- WSL 的 `~/.config/shell` → `/mnt/c/Users/Jat/.config/shell`。
- MSYS2 的 `~/.config/shell` → `C:\Users\Jat\.config\shell`。
- Clink 的 `C:\Users\Jat\AppData\Local\clink\clink_settings` →
  `C:\Users\Jat\.config\shell\common.clink_settings`。

Nushell 直接从 `~/.config/shell/` 加载 common 文件；
其配置目录中无需再为 `common.nu` 和 `common-env.nu` 建立链接。

## 平台识别

`common.jq` 的 `platform` 模式接收运行平台信息，返回
`windows`、`wsl`、`msys2`，或不输出结果。

| 输入平台 | 必须满足的条件 | 使用的配置 |
|---|---|---|
| `windows` / `Windows_NT` | Windows 原生运行时 | `environments.windows` |
| `Linux` / `linux` | `WSL_DISTRO_NAME` 或 `WSL_INTEROP` 非空 | `environments.wsl` |
| `MSYS*` / `CYGWIN*` / `MINGW*` | `MSYSTEM` 非空 | `environments.msys2` |
| 其他平台，或缺少上述标识 | 跳过本套配置的初始化 | 无 |

Bash、zsh 和 fish 使用 `uname -s` 提供平台信息。
PowerShell、Nushell 和 Clink 使用各自运行时的平台信息。
Windows 原生程序使用 Windows 配置，继承的 WSL/MSYS2 标识不会改变分类。

MSYS2 子进程可能在变量缺失时自动补回 `MSYSTEM`。
Bash/zsh/fish 的转换器调用会显式传递当前的 `MSYSTEM`、
`WSL_DISTRO_NAME` 和 `WSL_INTEROP`，包括空值，保证检测以调用 shell 的环境为准。

MSYS2 的 PATH 前置目录在 `common.json` 中集中定义：
先加入 `${MSYSTEM_PREFIX}/bin`，再加入 `/ucrt64/bin`。
当前 subsystem 的程序优先；MSYS 会话也能访问已安装的 UCRT64 程序。
UCRT64 下两项相同，生成器会自动去重。
Oh My Posh 直接通过 PATH 查找，脚本中不指定它的二进制路径。

## 修改共享数据

`common.json` 的 `common` 对象用于所有受支持环境；
`environments.windows`、`environments.wsl`、`environments.msys2` 用于环境差异。

| 字段 | 内容 |
|---|---|
| `environment` | 环境变量名称与字符串值。 |
| `path_prepend` | 加到 PATH 前面的目录列表。生成时删除空目录项和重复项。 |
| `aliases` | alias 名称与外部命令名称或可执行文件路径。 |
| `links` | 符号链接路径与目标路径；目前由安装脚本部署 WSL 条目。 |

同名的环境变量和 alias 由环境专属定义覆盖共享定义；
PATH 前置目录按共享定义、环境专属定义的顺序合并。

字符串可以引用 `${HOME}`、`${PNPM_HOME}` 等变量。
`HOME` 来自当前 shell；其他引用来自继承的环境及已展开的环境变量。
引用不存在的变量会报错，添加相互引用的变量时需要注意展开顺序。

`aliases` 用于外部命令名称或路径。带参数、管道或复杂逻辑的命令，
应写成对应 shell 的 common 文件中的函数。

`links` 与 `aliases` 独立，只有安装脚本创建文件系统链接。
链接路径和目标可以引用共享变量；现有相同链接不变，其他同名路径会报冲突。
当前 WSL 的 `links` 将 `${HOME}/.local/bin/git.exe` 链接到 Scoop Windows Git。
Oh My Posh 在 Windows 挂载盘上通过该链接调用 `git.exe`；该命令目录已在 PATH 中，
无需加入 Windows Git 安装目录。普通 `git` 继续调用 Linux Git。
修改 `links` 后重新运行安装脚本；修改 `aliases` 后重新加载 shell 配置。

Windows 外部命令 alias 的绝对路径在生成时规范为反斜杠。
以 `${HOME}/` 开头的 alias，在 Nushell 中保留 HOME 和 `path join` 表达式。
例如，当前 Windows `code` alias 会生成：

```nu
alias code = ^($env.HOME | path join "scoop" "apps" "vscode" "current" "bin" "code.cmd")
```

Nushell 的 `common-aliases.nu` 写入当前的 `$nu.default-config-dir`，
由 `common-env.nu` 自动生成，并保持 LF。
修改 alias 时编辑 `common.json`，生成文件会在下次初始化时更新。

## HOME 与路径写法

- Bash、zsh、fish、PowerShell 的运行时路径使用 `$HOME`。
- Nushell 的运行时路径使用 `$env.HOME`，需要组合路径时使用 `path join`。
- Readline 的 `$include` 不展开 `$HOME`，入口使用 `~`。
- Nushell 的 `source` 需要在解析时确定路径，不能使用运行时的 `$env.HOME`；
  入口使用可直接解析的 `~/.config/shell/...`。

## 安装位置与插件清单

Bash/zsh 的初始化文件查找使用标准数据目录：
先检查 `XDG_DATA_DIRS`（默认 `/usr/local/share:/usr/share`），
再检查 `XDG_DATA_HOME`（默认 `$HOME/.local/share`）。
按照可读文件或目录是否实际存在进行选择，发行版和安装方式不参与路径选择。

- ble.sh 支持数据目录下的 `blesh/ble.sh`、`blesh/out/ble.sh`、
  `ble.sh/ble.sh`、`ble.sh/out/ble.sh`。
- Antidote 支持 `antidote/antidote.zsh`、`zsh-antidote/antidote.zsh`、
  `zsh/site-functions/antidote.zsh`。
- 非标准安装位置可以在 `common.json` 的环境变量中设置
  `BLESH_FILE` 或 `ANTIDOTE_FILE`，直接指定初始化文件。
- `ZSH_PLUGIN_FILE` 可以指定其他插件清单；默认使用
  `${ZDOTDIR:-$HOME}/.zsh_plugins.txt`。

新增 zsh 插件时，只需修改插件清单，不需要为每个插件增加加载分支。
`owner/repo` 条目会按仓库名查找数据目录下的
`zsh/plugins/<name>`、`<name>`、`zsh/<name>`；
带 `path:` 注解时，还会确认对应子路径存在。
对 `kind:fpath` 条目，还会查询当前可用包管理器的文件清单。
若系统包已将补全定义放入现有 `$fpath` 目录，直接使用该目录，
不再通过 Antidote 下载同一份定义；仓库的 `path:src` 会按系统包布局处理。
本地路径、URL、`using:`、`preset:` 和其他注解继续由 Antidote 解析。

将补全插件放在语法高亮插件之前。
当前高亮条目使用 `pre:_shell_init_completion`，在加载高亮前完成补全初始化。
没有该条目时，加载器会在清单加载后完成补全初始化。
`ZSH_AUTOSUGGEST_*` 等变量是插件效果设置，不是插件加载白名单。

解析后的整份清单与加载脚本位于 `${XDG_CACHE_HOME:-$HOME/.cache}/zsh/`：
`plugins.txt`、`plugins.zsh`、`plugins.context`。
清单、实际安装目录、Antidote 安装或配置变化时重新生成；普通启动复用缓存。
Antidote 仓库缓存的位置由 `antidote home` 查询，以管理器实际配置为准。

`jq` 通过 PATH 查找。生成插件缓存时使用已解析的 Git 程序所在目录前置 PATH，
保证 Git 子进程优先找到同一安装中的依赖，不固定为 `/usr/bin:/bin`。

## WSL SSH agent

WSL 使用 AUR 的 `wsl2-ssh-agent-bin`，程序由 pacman 管理。
包中只有预编译二进制，因此仓库保存从
[上游](https://github.com/mame/wsl2-ssh-agent/blob/main/extras/systemd/user/wsl2-ssh-agent.service)
复制的 `systemd/wsl2-ssh-agent.service`。
为支持当前默认 root 用户，直接删除了原文件的 `ConditionUser=!root`；
没有另设 drop-in。

先安装 bin 包，再执行安装脚本。
安装脚本遍历仓库 `systemd/` 下的用户单元文件，链接到各 WSL 用户的
`~/.config/systemd/user/`。支持 service、socket、timer、path、target；
带 `[Install]` 的普通单元会被启用并启动，静态单元只部署，
`name@.service` 这类模板也只部署，实例由使用者指定。
新增单元只需添加对应文件，脚本不写死服务名、数量或程序路径。
单元运行所需程序由包管理器安装；启动失败时脚本直接报告错误。
共享环境只设置 `SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/wsl2-ssh-agent.sock`，
各 shell 不再启动 agent。

查看和管理服务：

```sh
systemctl --user status wsl2-ssh-agent.service
systemctl --user restart wsl2-ssh-agent.service
journalctl --user -u wsl2-ssh-agent.service
```

## ble.sh 历史搜索退出

Ctrl-R 进入增量搜索。Esc 退出搜索并保留当前匹配，继续编辑；不会直接执行命令。
Ctrl-G 取消搜索，恢复进入搜索前的命令行。
增量搜索模式下，Enter 默认退出搜索并保留匹配，Ctrl-J 退出并执行匹配。

Esc 在搜索模式中同时绑定 `C-[` 和 `ESC` 两种终端表示。
`decode_isolated_esc` 保持默认的 `auto`；搜索模式有绑定时识别独立 Esc，
其他模式继续使用原有 Meta 前缀行为。

Bash 的 `keyseq-timeout` 设为 1 毫秒，缩短独立 Esc 的识别等待时间。
此设置集中在 `common.bash` 的 ble.sh 初始化分支中。

## 提示符、历史与依赖

Oh My Posh 主题的实际文件保存在 `C:\Users\Jat\.config\shell\oh-my-posh`，
WSL/MSYS2 的对应目录链接到这里。主题文件分工如下：

| 主题 | 使用场景 |
|---|---|
| `config.omp.json` | Catppuccin Mocha 基础主题；WSL fish、Windows/WSL Nushell、CMD/Clink 使用。 |
| `shell-integration.omp.json` | Windows/WSL PowerShell，以及 WSL Bash/zsh。 |
| `msys2.omp.json` | MSYS2 Bash/zsh；包含 MSYS2 主目录映射。 |
| `msys2-fish.omp.json` | MSYS2 fish；保留主目录映射，关闭 Oh My Posh 的重复 shell integration。 |

fish 使用自身的 shell integration，避免与 Oh My Posh 重复发送标记。
Bash、zsh、fish、PowerShell 和 Clink 的上下键前缀历史搜索及光标行为，
由对应的 common 文件设置。Bash、zsh、fish 和 Clink 配置了历史共享。
zsh 的历史文件为 `$HOME/.zsh_history`，内存和保存上限均为 10000 条。
历史、缓存和生成文件按各环境的主目录保存。

主要依赖：

- 共享转换：jq。
- 提示符：Oh My Posh。各 shell 通过 PATH 查找 `oh-my-posh`。
- Bash：ble.sh。按照实际存在的安装文件查找，也支持 Git 构建后的文件。
- zsh：zsh-autosuggestions、zsh-completions、zsh-syntax-highlighting。
  每个交互式会话都加载 Antidote。插件清单源码是仓库的 `zsh_plugins.txt`；
  标准路径 `~/.zsh_plugins.txt` 链接到它，
  可添加仓库、本地目录及 Antidote 注解。加载器按仓库名称查找同名安装目录，
  优先使用实际存在的本地安装；其他条目交给 Antidote。zsh-completions 使用稳定版 0.36.0。
- PowerShell：PSReadLine、PSCompletions。
- CMD：Clink。由 `clink.getprompts("oh-my-posh")` 查找当前安装中的提示符文件，
  将解析结果放到当前进程的 CLINK_CUSTOMPROMPT 中；主题配置使用主目录相对路径。

WSL/MSYS2 新增 shell 依赖按 pacman、yay（可用时）、插件管理器、Git 的顺序查找。
只有前面的方式都没有对应包时，才直接从 Git 安装。

修改配置后，新开一个对应的 shell 会话。
Nushell 会先生成 alias 文件，再加载交互配置。
验证 ble.sh 时需要真正的交互会话；带 `-c` 的 Bash 会被 ble.sh 跳过初始化。
fish 的默认按键模式在进入交互提示符时初始化，应在真实交互会话中检查按键。
