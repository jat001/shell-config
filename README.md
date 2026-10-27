# Shell 共享配置

实际配置保存在 `C:\Users\Jat\.config\shell`。
Windows、WSL 和 MSYS2 按运行环境加载同一套配置。
各 shell 的 profile/rc 只保留加载入口，初始化逻辑和具体设置集中在本目录。

## Git 与安装

仓库根目录是 `C:\Users\Jat\.config\shell`，不是整个 `.config`。
仓库保存共用脚本、zsh 插件清单、OMP 主题、Ansible 安装配置和维护说明。
`.gitignore` 只忽略本地配置、备份和临时文件，新增配置源码会被 Git 正常发现。
历史、运行缓存和生成文件保存在仓库之外。

OMP 实际文件位于仓库中的 `oh-my-posh/`。
Windows 的 `~/.config/oh-my-posh` 是指向该目录的目录符号链接；
WSL/MSYS2 的同名目录直接链接到仓库中的主题目录。
运行时仍使用 `$HOME/.config/oh-my-posh`，主题的相对继承路径保持不变。

安装和更新由 `ansible/` 下的 Ansible playbook 完成。
`install.ps1` 只负责启动：准备连接，再用 `wslc` 构建并运行 Ansible 控制容器，
把仓库只读挂载到容器的 `/work`。容器经各 WSL 发行版内的专用 sshd 管理 WSL，
并经同一条连接借助 WSL interop 以当前用户的普通权限管理 Windows 和 MSYS2。

安装分三种模式，`-Mode` 默认为 `full`：

| 模式 | 内容 |
|---|---|
| `init` | 初始化：开启开发人员模式，安装 Scoop、MSYS2、Python 等前置程序，以及下文列出的 shell 和依赖；不部署配置。 |
| `full` | 全量安装：`init` 的全部内容，加上入口文件、共享链接、用户级 `HOME`、systemd 用户单元和开发盘任务。 |
| `update` | 增量更新：重新同步配置，只报告实际变化；升级已安装的受管软件，跳过一次性初始化步骤。 |

各主机并行执行，互不等待。新机器先运行 `init`，再运行 `full`：
WSL 的 `links` 条目指向 Scoop 安装的程序，需要先由 `init` 装好。
之后修改配置或升级软件时运行 `update`：

```powershell
& "$HOME/.config/shell/install.ps1" -Mode init
& "$HOME/.config/shell/install.ps1" -Mode full
& "$HOME/.config/shell/install.ps1" -Mode update
```

`-WhatIf` 以 `--check --diff` 运行 playbook，只预览不修改；
预览同样需要连接，因此仍会按下文准备 WSL 的 sshd，但不会请求管理员批准：

```powershell
& "$HOME/.config/shell/install.ps1" -WhatIf
```

默认布置当前 Windows 用户、`common.json` 中 `environments.msys2.root` 指定的
MSYS2，以及默认 WSL 发行版。当前 MSYS2 安装目录为 `J:\msys2`。
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
`-WslDevDriveOnly` 只运行带 `dev_drive` 标签的任务：Windows 开发盘任务、
WSL 的 `~/.config/shell` 链接和 `wsl-dev-drive.service`，可与 `-WslDistribution` 一起使用。
`-WindowsHome` 可指定配置部署的 Windows 用户主目录；
只有目标为当前账户主目录时，才设置该账户的用户级 `HOME`。
`-AnsibleArgument` 原样追加给 `ansible-playbook`，例如 `@('--tags', 'config', '-v')`。
Windows 目录和文件链接均使用 SymbolicLink；普通权限下创建链接需要开发人员模式。

### 控制容器与连接

控制容器镜像由 `ansible/Containerfile`、`requirements.txt`、`requirements.yml` 定义，
标签取三者内容的哈希；文件不变时复用已有镜像，修改后自动重建。
镜像基于 `python:3.14-slim`，即当前稳定版 ansible-core 支持的最高 Python；
`requirements.*` 只规定最低版本。`update` 模式总会以 `--pull --no-cache` 重建镜像，
让 Python、ansible-core 和 collection 随增量更新升级到最新稳定版。
容器通过 `host.wslc.internal` 访问 Windows 主机的回环地址，所有连接都只监听 `127.0.0.1`。

运行状态保存在 `%LOCALAPPDATA%\shell-ansible`：SSH 密钥、`known_hosts`、
本次生成的库存和变量文件。

WSL 发行版由 `ansible/bootstrap/wsl.sh` 准备：缺少时安装 OpenSSH 和 Python，
在 `/etc/shell-ansible` 写入独立的 sshd 配置、主机密钥和授权公钥，
不修改发行版自身的 sshd。启动器为每个发行版选一个固定的回环端口（22000–22999），
运行期间以 root 启动这个 sshd，结束后停止。Ansible 以 root 连接，
包管理任务直接执行；配置任务通过 `su` 切换到发行版的默认用户（`shell_user`）。
目前只在默认用户为 root 的发行版上验证过。

Windows 不单独开放远程管理服务。第一个 WSL 发行版的 sshd 同时承载 Windows 连接：
库存中的 Windows 主机使用 `ansible_shell_type: powershell`，
sshd 的 `PATH` 指向 `/etc/shell-ansible/bin`，其中的 `PowerShell` 包装脚本切换到
Windows 用户主目录，设置注册表中的 `PSModulePath`，再经 WSL interop 启动 Windows PowerShell。
这些进程以当前登录用户的普通令牌运行，Scoop 的目录联接、MSYS2 和用户级 `HOME` 都不需要提权。
没有使用 Windows OpenSSH 或 WinRM：前者的 sshd 启用了 RedirectionGuard，
SSH 会话无法经过普通用户创建的目录联接（Scoop 的 `apps/*/current`、Clink 的 cmd AutoRun）；
后者需要提权配置监听、证书映射并保存密码。至少需要一个 WSL 发行版，`-SkipWsl` 时仍用它承载连接。

只有两项操作需要管理员权限，均只在需要时请求：

- `init`/`full` 检测到开发人员模式未开启时，开启它（`AllowDevelopmentWithoutDevLicense`）；
- 开发盘计划任务缺失或配置变化时，注册它。

Ansible 在交互会话中以 `Start-Process -Verb RunAs` 启动提升的 Windows PowerShell 完成这些步骤，
因此会出现 UAC 提示；`-WhatIf` 只报告而不请求。已在管理员会话中运行时直接执行。
主机变量 `shell_elevate: false` 关闭提权请求，此时计划任务只给出提示，
开发人员模式未开启则在部署链接前停止。

`-Inventory`、`-StateDirectory`、`-Network`、`-Playbook`、`-PrepareOnly` 供测试使用：
提供 `-Inventory` 时跳过本机连接准备，库存文件须放在状态目录中。

### 冲突与重复运行

入口文件和链接由自定义模块 `shell_paths`（Linux）和 `win_shell_paths`（Windows）部署。
模块先检查一组目标，再统一修改：已有的相同入口和链接保持原样；
内容不同的入口文件或非空的普通目录会导致整组停止，保留其中的配置。
只有内容与入口相同的普通文件、空目录和指向其他位置的目录链接会被替换为链接。
WSL 和 MSYS2 主目录下的 `.bashrc`、`.profile` 等文件，若与发行版模板
（`/etc/skel/`、Debian 的 `/usr/share/base-files/dot.*`，MSYS2 根目录下的 `etc/skel/`）
完全相同，视为未修改的默认文件，
同样直接替换；改动过的文件仍按冲突处理。
模块不递归删除目录，也不生成备份文件；支持 `--check` 和重复运行。
Windows 的 rc/profile 保持一行实际入口，WSL/MSYS2 链接到它们。
这些运行入口不逐份提交，清单集中在 `ansible/group_vars/all/main.yml` 的 `shell_entries`：
`unix` 指定 WSL/MSYS2 的对应路径，`false` 表示不部署；`msys: false` 表示 MSYS2 跳过。

`zsh_plugins.txt` 是版本管理中的实际插件清单。
各环境的 `~/.zsh_plugins.txt` 链接到它，修改插件时编辑仓库中的文件。
Nushell alias、OMP 自动加载脚本、zsh 补全和插件缓存由运行时生成。
历史、日志、下载的插件仓库和构建产物均不提交。

### 软件来源

软件清单集中在 `ansible/group_vars/all/packages.yml`：

| 环境 | 来源 |
|---|---|
| Windows | Scoop：`git-without-openssh`（versions bucket）、jq、oh-my-posh、clink、nu、pscompletions；没有 `pwsh` 时安装 Scoop 的 pwsh。 |
| MSYS2 | 缺少时下载官方 base 包解压到 `root`；pacman 安装 fish、git、jq、zsh 和 UCRT64 oh-my-posh；ble.sh 使用 nightly 包，Antidote 克隆到 Windows 的 `~/.local/share/antidote` 后链接。 |
| Arch Linux | 官方仓库和 archlinuxcn（blesh-git、oh-my-posh、yay）；powershell-bin、wsl2-ssh-agent-bin、zsh-antidote 由专用构建用户 `aurbuilder` 通过 yay 构建。 |
| Debian | apt 安装 ble.sh、zsh-antidote 和 zsh 插件；Oh My Posh、Nushell、PowerShell 和 wsl2-ssh-agent 使用 GitHub 发布包，放在 `/opt/shell-releases`，链接到 `/usr/local/bin`。 |

缺少 Python 的 Linux 先用 `raw` 安装 Python，再执行其他任务。
Scoop 首次安装时先从清单 URL 安装 Git，添加 bucket 后改用 versions bucket 重新安装。
`update` 模式下 Scoop 先更新 bucket 再升级受管应用；MSYS2 和 Arch Linux 执行整体升级，
避免部分升级；AUR 包用 `yay -Sua` 升级；Debian 只把受管包升级到最新版本；
GitHub 发布包通过 `releases/latest` 重定向比较版本，不调用 GitHub API；
下载的发布包保留在 `/var/cache/shell-releases`（只保留当前版本），AUR 构建目录为 `/var/cache/aurbuilder`。
已由其他方式安装的同名命令保持不变，不改由本仓库管理。
Windows Terminal profiles 和 Clink 注入不在安装范围内。
个人化安装路径目前保留在 `common.json` 和 MSYS2 主题映射中；
部署到其他 Windows 用户或 MSYS2 安装位置时应核对并调整这些路径。

### 测试

`tests/run.ps1` 在隔离环境中依次运行 `init`、准备、`full`、
重复 `full`（要求 `changed=0`）、`update`、验证和普通权限检查：

- wslc 容器 `archlinux:latest`、`debian:testing`（与 WSL 中的 Debian forky 一致）：直接使用官方镜像，模拟全新系统；
  用同一个 `wsl.sh` 安装 OpenSSH 和 Python 并启动专用 sshd（容器内监听所有地址）。
  仓库只读挂载到 `/mnt/c/Users/Jat/.config/shell`，`tests/prepare.yml`
  生成 Windows 侧的入口文件，模拟 WSL 布局。容器内没有 systemd，用户单元只链接不启动。
- Windows Sandbox：用 `wsb` CLI 启动，仓库只读映射到 `C:\shell-repo`。
  沙盒中没有 WSL，测试改用 WinRM（`tests/winrm.ps1`，HTTPS 和客户端证书）连接，
  Windows role 与生产使用相同的任务。`tests/sandbox.ps1` 为内置管理员账户映射完整令牌的证书，
  并创建非管理员账户 `shelltest`。完整流程以管理员账户运行：沙盒初始未开启开发人员模式，
  由 `init` 开启，`full` 注册开发盘任务。最后的 `unprivileged` 步骤以 `shelltest`
  运行两次 `config` 和 `dev_drive` 标签（`shell_elevate: false`，第二次要求 `changed=0`），
  验证普通权限下的链接、`HOME`、MSYS2 链接，以及计划任务只提示不提权。
  非管理员经 WinRM 网络登录无法使用 Windows Installer，因此不在沙盒里以 `shelltest` 安装软件。
  MSYS2 安装到 `C:\msys64`，开发盘任务使用空 VHDX 占位文件。

```powershell
& "$HOME/.config/shell/tests/run.ps1"
& "$HOME/.config/shell/tests/run.ps1" -Target debian -Step full, verify -Reuse -Keep
```

`-Keep` 保留容器和沙盒，`-Reuse` 复用仍在运行的容器和沙盒。
测试状态默认保存在 `%TEMP%\shell-ansible-test`。
各目标的准备（容器引导、沙盒启动和 WinRM 配置）在后台作业中并行进行，日志写入状态目录的
`setup-<目标>.log`。下载缓存跨轮保留：wslc 卷 `shell-test-pacman`、`shell-test-aur`（Arch 的包缓存和
AUR 构建目录）、`shell-test-apt`、`shell-test-releases`（Debian 的包缓存和 GitHub 发布包），
Debian 容器删除了丢弃包缓存的 `docker-clean` 配置；状态目录下的 `cache` 映射到沙盒的
`C:\shell-cache`，保存 Scoop 缓存（`SCOOP_CACHE`）和 MSYS2 基础包。
删除这些卷和 `cache` 目录即可重新下载。
测试启用 `ansible.posix.profile_tasks` 输出每个任务的耗时，结束时打印各准备和步骤的耗时，
并写入状态目录的 `timings.json`。启动器会把宿主环境中的 `ANSIBLE_*` 和 `PROFILE_TASKS_*`
变量传给控制容器。
测试不覆盖：WSL interop 承载的 Windows 连接（已在本机以 `-WhatIf` 验证）、UAC 批准流程、
启动 systemd 用户单元和挂载开发盘。

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
| `install.ps1` | 启动器：构建 wslc 控制容器、准备 WSL 连接、生成库存，按模式运行 playbook。 |
| `ansible/bootstrap/wsl.sh` | 在发行版中安装 OpenSSH/Python，写入 Ansible 专用 sshd 配置和 Windows PowerShell 包装。 |
| `ansible/site.yml` | 入口 playbook：校验模式，再以 `strategy: free` 并行配置 Windows/MSYS2 和各 Linux 主机。 |
| `ansible/roles/windows/` | Scoop、MSYS2、Windows 入口和链接、用户级 `HOME` 和开发盘任务。 |
| `ansible/roles/linux/` | Python 引导、Arch/Debian 软件、WSL 入口和链接、`links` 条目和 systemd 用户单元。 |
| `ansible/library/` | `shell_paths`、`win_shell_paths`：先检查全部目标再部署的入口与链接模块。 |
| `ansible/filter_plugins/shell.py` | 把 `shell_entries` 展开为 Windows、MSYS2、WSL 的部署清单，筛选 systemd 单元。 |
| `ansible/group_vars/all/` | 模式、入口清单和各环境软件清单。 |
| `ansible/Containerfile` | Ansible 控制容器镜像；`requirements.*` 固定 Python 包和 collection 范围。 |
| `tests/` | wslc 容器和 Windows Sandbox 的测试编排、准备和验证 playbook；`winrm.ps1` 只用于连接沙盒。 |
| `zsh_plugins.txt` | zsh 插件清单源码；各环境的标准清单路径链接到此文件。 |
| `systemd/wsl2-ssh-agent.service` | 上游用户服务副本，移除了 root 条件，`ExecStart` 改为按名称查找程序。 |
| `systemd/wsl-dev-drive.service` | 启动时请求 Windows 任务附加共享开发盘，确认 UUID 和文件系统就绪。 |
| `wsl-dev-drive.sh` | 读取共享开发盘配置、触发挂载并等待结果。 |
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
| MSYS2 | `/home/Jat`，对应 `J:\msys2\home\Jat` |

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
| `root` | MSYS2 安装根目录，供 playbook 读取；`-Msys2Root` 可显式覆盖。 |
| `path_prepend` | 加到 PATH 前面的目录列表。生成时删除空目录项和重复项。 |
| `aliases` | alias 名称与外部命令名称或可执行文件路径。 |
| `links` | 符号链接路径与目标路径；目前由 playbook 部署 WSL 条目。 |

同名的环境变量和 alias 由环境专属定义覆盖共享定义；
PATH 前置目录按共享定义、环境专属定义的顺序合并。

字符串可以引用 `${HOME}`、`${PNPM_HOME}` 等变量。
`HOME` 来自当前 shell；其他引用来自继承的环境及已展开的环境变量。
引用不存在的变量会报错，添加相互引用的变量时需要注意展开顺序。

`aliases` 用于外部命令名称或路径。带参数、管道或复杂逻辑的命令，
应写成对应 shell 的 common 文件中的函数。

`links` 与 `aliases` 独立，只有 playbook 创建文件系统链接。
链接路径和目标可以引用共享变量；现有相同链接不变，其他同名路径会报冲突。
当前 WSL 的 `links` 将 `${HOME}/.local/bin/git.exe` 链接到 Scoop Windows Git。
Oh My Posh 在 Windows 挂载盘上通过该链接调用 `git.exe`；该命令目录已在 PATH 中，
无需加入 Windows Git 安装目录。普通 `git` 继续调用 Linux Git。
修改 `links` 后运行 `update` 模式；修改 `aliases` 后重新加载 shell 配置。

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

Arch Linux 使用 AUR 的 `wsl2-ssh-agent-bin`，程序由 pacman 管理；
Debian 使用上游发布的二进制，链接到 `/usr/local/bin`。
包中只有预编译二进制，因此仓库保存从
[上游](https://github.com/mame/wsl2-ssh-agent/blob/main/extras/systemd/user/wsl2-ssh-agent.service)
复制的 `systemd/wsl2-ssh-agent.service`。
为支持当前默认 root 用户，直接删除了原文件的 `ConditionUser=!root`；
`ExecStart` 只写程序名，由 systemd 在 `/usr/local/bin`、`/usr/bin` 等固定目录中查找，
两种安装位置共用同一份单元。没有另设 drop-in。

playbook 遍历仓库 `systemd/` 下的用户单元文件，链接到各 WSL 用户的
`~/.config/systemd/user/`。支持 service、socket、timer、path、target；
带 `[Install]` 的普通单元会被启用并启动，静态单元只部署，
`name@.service` 这类模板也只部署，实例由使用者指定。
普通安装按文件发现单元；开发盘专用模式只选择 `wsl-dev-drive.service`。
单元运行所需程序在 `init` 阶段安装；启动失败时 playbook 直接报告错误。
单元文件内容变化后（`NeedDaemonReload`），重新加载用户管理器并重启对应单元。
systemd 用户管理器不可用时只链接单元并给出提示。
共享环境只设置 `SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/wsl2-ssh-agent.sock`，
各 shell 不再启动 agent。

查看和管理服务：

```sh
systemctl --user status wsl2-ssh-agent.service
systemctl --user restart wsl2-ssh-agent.service
journalctl --user -u wsl2-ssh-agent.service
```

## WSL 共享开发盘

`common.json` 的 `environments.wsl.dev_drive` 保存共享开发盘配置。
当前指向 Windows 用户主目录下的 `AppData/Local/wsl/dev.vhdx`，
挂载到 `/mnt/wsl/dev`，使用 Btrfs 和 `compress=zstd:1`。
`vhd` 相对于 `-WindowsHome`；`schtasks` 是该发行版访问 Windows 任务工具的完整路径。
如果发行版使用其他 Windows 挂载根目录，应相应调整 `schtasks` 和 `mountpoint`。
配置中的 UUID 必须与已有文件系统一致；重新创建数据盘后应更新 UUID。

普通安装会一并部署此功能，也可以只安装开发盘部分：

```powershell
& "$HOME/.config/shell/install.ps1" -WslDevDriveOnly -WhatIf
& "$HOME/.config/shell/install.ps1" -WslDevDriveOnly
```

playbook 注册当前 Windows 账户的 `WSL Attach Dev VHDX` 高权限按需任务。
任务直接执行系统目录的 `wsl.exe --mount --vhd ...`，没有登录或定时触发器。
只有任务缺失或配置变化时才修改，此时会为注册请求一次管理员批准（UAC）。
`-WhatIf` 不创建任务。同名但执行其他操作的任务会被视为冲突并保留。
管理 WSL 发行版时自动注册；`shell_dev_drive_task` 设为 `true` 或 `false` 可强制开启或关闭。

playbook 同时部署并启用 `wsl-dev-drive.service` 用户服务。
发行版中对应用户的 systemd 用户管理器启动时，服务检查挂载点的 UUID 和文件系统。
已经正确挂载时直接成功；其他文件系统占用该挂载点时失败。
尚未挂载时，通过 Windows 任务请求附加，最多等待 60 秒确认挂载成功；
失败由 systemd 重试，五分钟内最多启动三次，结果记录到用户日志。
服务停止时保留共享挂载，避免影响其他发行版。

这项功能需要 systemd、WSL Windows 互操作、jq、findmnt，以及内核对应文件系统支持。
它只附加已有 VHDX，不创建虚拟磁盘或格式化文件系统。
运行时重建盘后，需同步更新配置中的 UUID。
Windows 账户必须已登录，才能运行 Interactive 类型的计划任务。
服务按 WSL 用户部署；其他发行版可通过 `-WslDistribution` 一并安装，
各发行版共用同一个 Windows 挂载任务。

```sh
systemctl --user status wsl-dev-drive.service
systemctl --user restart wsl-dev-drive.service
journalctl --user -u wsl-dev-drive.service
findmnt -M /mnt/wsl/dev
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
