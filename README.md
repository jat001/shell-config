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
`install.ps1` 只负责启动：缺少时先安装 WSL 和配置的发行版（见“WSL 与 Windows Terminal”），
准备连接，再用 `wslc` 构建并运行 Ansible 控制容器，
把仓库只读挂载到容器的 `/work`。容器经各 WSL 发行版内的专用 sshd 管理 WSL，
并经同一条连接借助 WSL interop 以当前用户的普通权限管理 Windows 和 MSYS2。

安装分三种模式，`-Mode` 默认为 `full`：

| 模式 | 内容 |
|---|---|
| `init` | 初始化：开启开发人员模式，设置两个开发盘（见下文），安装 Scoop、MSYS2、Python、Windows Terminal、PowerShell 和字体等前置程序，以及下文列出的 shell 和依赖，应用 WSL 与 Windows Terminal 设置；不部署 shell 入口等其余配置。 |
| `full` | 全量安装：`init` 的全部内容，加上入口文件、共享链接、用户级 `HOME`、其余 systemd 用户单元、WSL 设置和 Windows Terminal 设置。 |
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
MSYS2，以及 `common.json` 中 `environments.wsl.distributions` 列出的 WSL 发行版。
当前清单为 `archlinux` 和 `Debian`，第一项设为默认发行版；清单为空时使用现有默认发行版。
当前 MSYS2 安装目录为 `${DEV_DRIVE}/msys2`，
`${DEV_DRIVE}` 由 playbook 替换为 Windows 开发盘的盘符（见下文），目前是 `J:\msys2`。
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
`-WslDevDriveOnly` 只运行带 `dev_drive` 标签的任务：WSL 开发盘的 Windows 计划任务、
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
包管理任务直接执行；配置任务对 root 和 WSL 用户各运行一次，通过 `su` 切换到对应账户（见“WSL 用户”）。

Windows 不单独开放远程管理服务。第一个 WSL 发行版的 sshd 同时承载 Windows 连接：
库存中的 Windows 主机使用 `ansible_shell_type: powershell`，
sshd 的 `PATH` 指向 `/etc/shell-ansible/bin`，其中的 `PowerShell` 包装脚本切换到
Windows 用户主目录，设置注册表中的 `PSModulePath`，再经 WSL interop 启动 Windows PowerShell。
这些进程以当前登录用户的普通令牌运行，Scoop 的目录联接、MSYS2 和用户级 `HOME` 都不需要提权。
没有使用 Windows OpenSSH 或 WinRM：前者的 sshd 启用了 RedirectionGuard，
SSH 会话无法经过普通用户创建的目录联接（Scoop 的 `apps/*/current`、Clink 的 cmd AutoRun）；
后者需要提权配置监听、证书映射并保存密码。至少需要一个 WSL 发行版，`-SkipWsl` 时仍用它承载连接。

以下操作需要管理员权限，均只在需要时请求：

- WSL 尚未安装时，安装 WSL 本身；需要重启时，重启后重新运行安装器；
- `init`/`full` 检测到开发人员模式未开启时，开启它（`AllowDevelopmentWithoutDevLicense`）；
- Windows 或 WSL 开发盘文件缺失时，创建并格式化新的动态 VHDX；
- Windows 开发盘未登记开机附加或尚未附加时，登记并附加它；
- WSL 开发盘计划任务缺失或配置变化时，注册它。

WSL 可用后，Ansible 先汇总开发人员模式、建盘、Windows 开机挂载和 WSL 计划任务的实际变化，
只在存在变化时请求一次 UAC，在同一个管理员进程里完成这些系统步骤。
Scoop、MSYS2 和用户配置仍在普通权限下运行；已在管理员会话中运行时，系统步骤直接执行。
WSL 本身尚未安装时，MSI 引导属于更早的独立阶段，可能另需一次 UAC 和重启；安装器不自动重启宿主。
`-WhatIf` 只报告系统变化，不请求管理员批准；连接和传输所需的临时脚本仍会准备。
主机变量 `shell_elevate: false` 关闭提权请求，此时开发盘登记和计划任务只给出提示
（未附加的 Windows 开发盘取不到盘符，依赖它的步骤会停止），
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
| Windows | Scoop：`git-without-openssh`（versions bucket）、jq、oh-my-posh、clink、clink-completions、nu、pscompletions、Maple-Mono-NF-CN（nerd-fonts bucket）；Microsoft Store：Windows Terminal、PowerShell。 |
| MSYS2 | 缺少时下载官方 base 包解压到 `root`；pacman 安装 fish、git、jq、zsh 和 UCRT64 oh-my-posh；ble.sh 使用 nightly 包，Antidote 克隆到 Windows 的 `~/.local/share/antidote` 后链接。 |
| Arch Linux | 官方仓库和 archlinuxcn（blesh-git、oh-my-posh、yay）；powershell-bin、wsl2-ssh-agent-bin、zsh-antidote 由 WSL 用户通过 yay 构建。 |
| Debian | Debian 官方源安装 bash-completion、ble.sh、zsh-antidote 和可用的 zsh 插件；Nushell 使用项目官方 Gemfury 源，PowerShell 使用微软官方源。Oh My Posh、wsl2-ssh-agent 使用各自官方 GitHub 二进制，由共享更新器和 systemd timer 维护。 |

缺少 Python 的 Linux 先用 `raw` 安装 Python，再执行其他任务。
Scoop 首次安装时先从清单 URL 安装 Git，添加 bucket 后改用 versions bucket 重新安装。
`update` 模式下 Scoop 先更新 bucket 再升级受管应用；MSYS2 和 Arch Linux 执行整体升级，
避免部分升级；AUR 包用 `yay -Sua` 升级；Debian 只把受管包升级到最新版本；
GitHub 发布包通过 `releases/latest` 重定向比较版本，不调用 GitHub API；
下载的发布包保留在 `/var/cache/shell-releases`，先校验内容长度、上游 SHA256 和可执行格式，再原子切换命令链接。
旧的已安装版本保留，避免仍在运行的 shell 引用旧绝对路径时失效。
AUR 构建目录默认为 WSL 用户的 `~/.cache/yay`（`shell_aur_cache` 可改为其他目录）。
已由其他方式安装的同名命令保持不变，不改由本仓库管理。
Windows Terminal 的受管设置和 MSYS2、Nushell profiles 由 `windows-terminal.json` 定义并合并部署；
现有其他 profile 和未受管字段保留。Clink 自动注入在 `full`/`update` 的配置阶段注册（见“CMD 与 Clink”）。
Debian 的上游 apt 源分别使用独立的 `Signed-By` 密钥，仅允许提供声明的目标包；
其他包在这些源中的优先级为 `-1`，运行库继续由 Debian 官方源提供。
Debian 12 使用微软 bookworm 源；13 使用 trixie 源，forky/sid 使用已验证可满足依赖的 Debian 13 通用包。
后者不表示微软对 Debian testing 提供官方发行版支持。

Oh My Posh 和 wsl2-ssh-agent 的当前官方发布没有 Debian 包，使用官方二进制，
不接入其他维护者的重打包源，也不自建仓库。安装器与
`shell-releases-update.service` 共用 `/usr/local/libexec/shell-releases-update` 和
`/etc/shell-releases.json`，不会各维护一份升级逻辑。
`shell-releases-update.timer` 每天检查一次，随机延迟最多一小时，`Persistent=true` 补跑错过的任务。
timer 只更新已受管且仍安装的程序，不接管其他安装，也不重新安装已移除的程序；
发生校验失败或用户服务重启失败时保留或恢复旧命令链接。SSH agent 更新后只尝试重启已运行的受管用户单元。
日志用 `journalctl -u shell-releases-update.service` 查看。

运行 `install.ps1 -Mode update` 同样会更新这些程序；apt 管理的 Nushell 和 PowerShell
则通过正常的 apt 升级流程更新。固定版本的 zsh 插件继续遵循 `zsh_plugins.txt`，
PowerShell 用户模块继续由 PSResourceGet 管理，系统程序 timer 不修改插件清单或共享用户模块。

### 测试

`tests/run.ps1` 先验证 Terminal JSONC 字符串保留、配置合并和重复运行，
再在隔离环境中依次运行 `init`、准备、`full`、
重复 `full`（要求 `changed=0`）、`update`、验证和普通权限检查：

- wslc 容器 `archlinux:latest`、`debian:testing`（与 WSL 中的 Debian forky 一致）：直接使用官方镜像，模拟全新系统；
  用同一个 `wsl.sh` 安装 OpenSSH 和 Python 并启动专用 sshd（容器内监听所有地址）。
  仓库只读挂载到 `/mnt/c/Users/shell/.config/shell`（有意不用真实用户名），`tests/prepare.yml`
  生成 Windows 侧的入口文件，模拟 WSL 布局。容器内没有 systemd，用户单元只链接不启动。
- Windows Sandbox：用 `wsb` CLI 启动，仓库只读映射到 `C:\shell-repo`。
  沙盒中没有 WSL，测试改用 WinRM（`tests/winrm.ps1`，HTTPS 和客户端证书）连接，
  Windows role 与生产使用相同的任务。`tests/sandbox.ps1` 为内置管理员账户映射完整令牌的证书，
  并创建非管理员账户 `shelltest`。完整流程以管理员账户运行：沙盒初始未开启开发人员模式，
  由 `init` 开启，同时登记、附加 Windows 开发盘并注册 WSL 开发盘任务。
  最后的 `unprivileged` 步骤以 `shelltest`
  运行两次 `config` 和 `dev_drive` 标签（`shell_elevate: false`，第二次要求 `changed=0`），
  验证普通权限下的链接、`HOME`、MSYS2 链接、已附加开发盘的盘符读取，以及登记和计划任务只提示不提权。
  非管理员经 WinRM 网络登录无法使用 Windows Installer，因此不在沙盒里以 `shelltest` 安装软件。
  MSYS2 安装到 `C:\msys64`。`sandbox.ps1` 用 diskpart 为两个账户各建一个 512 MB 的
  `AppData\Local\Dev.vhdx`（NTFS）：管理员的先分离，由 playbook 附加；`shelltest` 的保持附加。
  WSL 开发盘任务使用空 VHDX 占位文件。

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
`C:\shell-cache`，保存 Scoop 缓存（`SCOOP_CACHE`）、MSYS2 基础包和 MSYS2 的 pacman 包
（`shell_msys2_cache`，传给 pacman 的 `--cachedir`；生产环境默认使用用户目录下的持久缓存；设为空时使用 MSYS2 自身的缓存）。
`cache/git` 保存 ScoopInstaller/Scoop、Main、Versions 的浅克隆裸镜像，每轮在主机上增量 `fetch`；
沙盒管理员账户的 `.gitconfig` 用 `url.insteadOf` 把 `https://github.com/ScoopInstaller/` 指向这些镜像，
因此添加 bucket、`update` 时把 main bucket 转为 git 仓库以及更新 Scoop 核心都从本地克隆。
Scoop 安装器自身下载的核心和 main bucket 压缩包不经过 git，仍从 GitHub 下载。
删除这些卷和 `cache` 目录即可重新下载。
测试启用 `ansible.posix.profile_tasks` 输出每个任务的耗时，结束时打印各准备和步骤的耗时，
并写入状态目录的 `timings.json`。启动器会把宿主环境中的 `ANSIBLE_*` 和 `PROFILE_TASKS_*`
变量传给控制容器。
隔离测试不覆盖：首次安装 WSL 和发行版、真实 Microsoft Store 下载、UAC 批准流程、
启动 systemd 用户单元和挂载真实 WSL 开发盘。Sandbox 无 WSL，通过宿主的控制容器部署；
无 winget 时使用官方 GitHub 发布的同包族 MSIX，不能据此证明 Store 下载流程。
WSL interop 承载的 Windows 连接和已安装发行版上的完整部署已在本机验证。

### Hyper-V 完整部署测试

首次准备使用仓库内的 `Prepare` 入口：

```powershell
& "$HOME/.config/shell/tests/hyperv.ps1" -Action Prepare
```

准备入口先复用状态目录 `media/` 中的 ISO；没有缓存时，从微软评估中心公开下载页解析当前语言的
Windows 11 Enterprise ISO 地址，用 curl 断点续传到缓存。`-IsoLanguage en-US` 可选择语言，
`-IsoSource <本地 ISO 或 HTTPS 地址>` 可指定来源，`-IsoSha256 <SHA256>` 可校验预期哈希。
缓存记录保存 SHA256，再次使用前检查；挂载后还会检查微软安装程序签名。

媒体准备完成后只请求一次 UAC：缺少时启用 Hyper-V，创建新的动态系统 VHDX 并应用 Windows 镜像，
创建支持嵌套虚拟化、Secure Boot 和 vTPM 的 VM，通过 PowerShell Direct 等待安装完成，
建立 `Clean-Windows`，安装缓存的 WSL MSI、重启客户机并验证嵌套容器，再建立 `WSL-Ready`。
Hyper-V 组件若需要宿主重启会停止并提示，再次运行复用缓存；不自动重启宿主。
已有 VM 和检查点按身份记录复用，不覆盖同名的其他 VM、不重新格式化已有系统盘。

准备状态和错误分别在 `prepare-progress.json`、`prepare-result.json`。
默认创建随机密码的本地测试管理员，凭据用当前 Windows 用户的 DPAPI 加密保存在状态目录；
无人值守应答文件在建立干净基线前删除。默认不启用自动登录，GUI 验证时需要登录测试桌面。
`tests/hyperv_prepare.ps1` 的 `-Stage Host`、`Create`、`Baselines` 可分别准备宿主、Windows VM 和 WSL 基线；
它还支持指定 VM 名称、内存、CPU、系统盘容量和映像索引。当前准备入口支持 x64 宿主与 x64 Windows 映像。

`tests/hyperv.ps1` 复用独立 Windows 测试 VM。首次启动测试控制流程需要一次 UAC，
后续同步、部署、恢复检查点和取日志通过同一个流程执行。它只管理状态文件中记录 ID 的测试 VM，
两小时后退出；`Stop` 可以提前结束。测试用管理员会话只在 VM 中运行安装器。

```powershell
& "$HOME/.config/shell/tests/hyperv.ps1" -Action Start
& "$HOME/.config/shell/tests/hyperv.ps1" -Action Sync
& "$HOME/.config/shell/tests/hyperv.ps1" -Action Run -Modes init
& "$HOME/.config/shell/tests/hyperv.ps1" -Action Collect
```

动作异步执行，结果位于状态目录的 `operations/<操作 ID>.json`；
前一步完成后再发送依赖它的动作。进度保存在 `progress.json`。
`Run -Modes full,full,update` 检查完整部署、重复部署和更新，结束后会重启测试 VM，并在登录会话中检查实际启动。
`Restore -Baseline WSL-Ready` 或 `Clean-Windows` 恢复指定基线，会丢弃 VM 中后续的改动。
恢复后重新 `Sync` 再运行测试；`Collect` 保留日志和下载缓存。`Clean-Windows` 基线用于测试 WSL 引导与重启；完整回归默认从 `WSL-Ready` 开始。

默认状态目录为当前用户的 `AppData/Local/shell-ansible-test/hyperv`，
包含 VM 身份记录 `vm-created.json` 和本机加密的测试凭据 `guest-credential.xml`。
Windows 软件包缓存会在客户机与宿主的 `cache/downloads` 之间复用，位于 VM 检查点之外。
当前 VM 已配置嵌套虚拟化、Secure Boot 和 vTPM；基线分别为干净 Windows 和已验证 WSL/wslc 的状态。
首次 Windows 及 VM 准备与日常的检查点回归分开执行，VM 磁盘和凭据不放进仓库。
最近新增的 WSL MSI 缓存引导已通过 PowerShell 5.1/7 的下载、复用与校验测试，尚未从 `Clean-Windows` 完整回归。

### Docker 补全

Docker Desktop 提供的 WSL Docker CLI 和补全链接随其 WSL 集成挂载出现，不由此仓库复制或维护。
Docker Desktop 停止时这些链接可能悬空；命令及对象补全需先具备可用的 Docker CLI。

| Shell | 加载方式 |
|---|---|
| Bash | 按实际安装位置加载 bash-completion，自动加载 Docker 提供的补全；MSYS2 为显式 alias 加载 CLI 生成的 Bash 补全。 |
| zsh | 将存在的 XDG 数据目录下 `zsh/vendor-completions` 加入 `fpath`；补全缓存按有效文件列表失效，覆盖 Docker Desktop 链接由悬空恢复的情况。MSYS2 加载 CLI 生成的补全。 |
| fish | WSL 使用 vendor completion；MSYS2 加载 CLI 生成的 fish 补全。 |
| PowerShell 5.1/7 | 保留 PSCompletions，同时注册 Docker CLI 生成的原生补全；局部兼容严格错误策略并修正 stderr 重定向，避免诊断消息写到提示行，不改变调用方的错误策略。 |
| Nushell | 外部补全器调用 Docker 的 `__complete` 接口，保留命令说明和 `--flag=value` 前缀；文件补全交回内置实现，其他命令交回原来的外部补全器或默认补全，不增加中转依赖。 |
| CMD/Clink | Scoop 安装并注册 `clink-completions`，包含 Docker 和 Compose 补全。 |

MSYS2 的 `docker` 是 `common.json` 中的显式 alias，指向现有 Windows Docker Desktop CLI；
不创建链接、不扩展全局 PATH。若 Docker Desktop 安装在其他位置，只修改这个 alias。

`tests/docker_completions.ps1` 在现有安装上验证 Windows、WSL、MSYS2 的命令、上下文和选项补全，
以及 WSL zsh 补全链接恢复后的缓存失效；Docker Desktop 的 WSL 集成需要可用。
`-Target Windows`、`WSL`、`MSYS2` 可选择环境，`-WslDistribution`、`-Msys2Root` 可指定目标。
Clink 的自动检查验证脚本安装及注册，实际 Tab 补全另做交互验证；当前主机已验证 `docker ru` 补成 `docker run`。

### 下载缓存

Windows 默认缓存位于用户主目录的 `AppData/Local/shell-ansible/cache`。
`install.ps1 -CacheDirectory <目录>` 可同时指定 WSL 发行版缓存和 Windows 下载缓存根目录。

| 下载 | 缓存方式 |
|---|---|
| WSL 运行时 | GitHub 最新稳定版 MSI，按版本与架构保存在 `wsl/runtime`；下载后及复用前校验微软 Authenticode 签名。 |
| WSL 发行版 | 从微软 `DistributionInfo.json` 解析 `.wsl` URL 和 SHA256，使用与 WSL 相同的 Windows 原生 HTTP 客户端；校验成功后才发布到 `wsl/packages`，复用前再次校验。 |
| Scoop | `shell_scoop_cache` 传入 `SCOOP_CACHE`。 |
| MSYS2 | `shell_msys2_cache` 保存 pacman 包和基础安装包。 |
| Microsoft Store 应用的官方发布包 | `shell_store_cache` 保存按版本命名的 MSIX/PreinstallKit。 |
| ble.sh 等归档 | `shell_archive_cache` 按 URL、ETag/Last-Modified 区分版本；下载完成后才发布缓存文件。 |
| Ansible 控制镜像 | 复用已有镜像、构建层和 pip/Galaxy 缓存；更新模式仍检查更新。 |
| Linux 包及发布包 | pacman/apt 自身缓存，以及 `/var/cache/shell-releases`；现有容器测试继续使用持久卷。 |

元数据和版本查询仍需要联网。发行版文件名包含公布的 SHA256 前缀，不依赖下载服务器的 HEAD 响应；
HTML 防护页或其他校验失败的下载会停止并删除临时文件，不进入缓存。Debian 和 Arch 安装包均已验证可缓存。
WSL 尚未安装时，先取得并验证 MSI，再在一次管理员进程中启用 VirtualMachinePlatform、静默安装 MSI。
安装日志保存在状态目录的 `wsl-install.log`；需要重启时停止并提示，不自动重启。已有 WSL 不重复安装运行时。

`tests/wsl_cache.ps1 -CacheDirectory <目录>` 验证实际下载、缓存复用和无效安装包拒绝，不安装或卸载 WSL；已在 Windows PowerShell 5.1 与 PowerShell 7 验证。

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
| `windows-terminal.json` | Windows Terminal 受管设置，由 playbook 合并进 `settings.json`。 |
| `common.sh` | Bash/zsh 共用的环境加载、初始化文件查找，以及提示符主题选择。 |
| `common.bash` | Bash 交互初始化、历史设置、Oh My Posh 和 ble.sh 配置。传入 `ble` 时只设置 ble.sh。 |
| `common.zsh` | zsh 历史、按键、补全、Oh My Posh 和插件。传入 `environment` 时只加载共享环境。 |
| `common.fish` | fish 的环境加载、前缀历史搜索、按键和 Oh My Posh 初始化。 |
| `common.ps1` | Windows PowerShell 5.1、Windows/WSL PowerShell 7 的环境、PSReadLine、PSCompletions 和提示符。 |
| `common-env.nu` | Nushell 环境加载，生成 alias 和当前环境的 Oh My Posh 初始化脚本。 |
| `common.nu` | Nushell 平台检查，加载生成的 alias 和 Oh My Posh 初始化脚本。 |
| `common.lua` | CMD/Clink 主题位置发现、初始化、UTF-8 代码页、Windows PATH 排序和共享 alias 加载。 |
| `common.clink_settings` | Clink 的提示符选择、主题路径和历史共享设置。 |
| `common.inputrc` | Bash/Clink 的 Readline 铃声设置，以及上下键前缀历史搜索。 |

## 加载入口与共享链接

下面的 `~` 表示对应环境的用户主目录：

| 环境 | 当前主目录 |
|---|---|
| Windows | `C:\Users\Jat` |
| WSL archlinux | `/root` |
| MSYS2 | `/home/<用户名>`，对应 `${DEV_DRIVE}\msys2\home\<用户名>`（目前为 `J:\msys2\home\Jat`） |

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
| `environment` | 环境变量名称与字符串值；值为数组时依次尝试，取第一个所引用变量都已定义的候选。 |
| `root` | MSYS2 安装根目录，供 playbook 读取；`-Msys2Root` 可显式覆盖。 |
| `path_prepend` | 加到 PATH 前面的目录列表。生成时删除空目录项和重复项。 |
| `aliases` | alias 名称与外部命令名称或可执行文件路径。 |
| `links` | 符号链接路径与目标路径；目前由 playbook 部署 WSL 条目。 |

同名的环境变量和 alias 由环境专属定义覆盖共享定义；
PATH 前置目录按共享定义、环境专属定义的顺序合并。

字符串可以引用 `${HOME}`、`${PNPM_HOME}` 等变量。
`HOME` 来自当前 shell；其他引用来自继承的环境及已展开的环境变量。
`${WINDOWS_HOME}` 是 Windows 用户目录，不写死用户名，也不导出到环境：
Windows 取 `USERPROFILE`，MSYS2 把继承的 `USERPROFILE` 转为 `/c/Users/...` 形式，
WSL 由各 shell 解析 `~/.config/shell` 链接（指向 `<Windows 用户目录>/.config/shell`）得到，
playbook 规划链接时直接传入检测到的 Windows 用户目录。
WSL 中 `${DEV_DRIVE}` 只在共享开发盘已挂载时定义（见下文），同样不导出。
引用不存在的变量会报错，添加相互引用的变量时需要注意展开顺序。

`aliases` 用于外部命令名称或路径。带参数、管道或复杂逻辑的命令，
应写成对应 shell 的 common 文件中的函数。

`links` 与 `aliases` 独立，只有 playbook 创建文件系统链接。
链接路径和目标可以引用共享变量；现有相同链接不变，其他同名路径会报冲突。
目标不存在或当前账户读不到的链接跳过并列出，Windows 一侧补上后再运行 `update` 即可创建。
当前 WSL 的 `links` 将 `${HOME}/.local/bin/git.exe` 链接到 Scoop Windows Git。
Oh My Posh 在 Windows 挂载盘上通过该链接调用 `git.exe`；该命令目录已在 PATH 中，
无需加入 Windows Git 安装目录。普通 `git` 继续调用 Linux Git。
其余条目让 WSL 与 Windows 共用账户和工具配置：`.ssh`、`.gnupg`、`.gitconfig`、`.aws`、
`.azure`、`.vimrc`、`.wakatime.cfg`、Docker 的 `contexts` 和 `features.json`、
Cargo 的 `credentials.toml`（Scoop rustup 目录下）、pnpm 配置目录和 fish 的 `fish_plugins`。
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

解析后的整份清单与加载脚本位于 `${XDG_CACHE_HOME:-$HOME/.cache}/zsh/`
（WSL 中再按 `WSL_DISTRO_NAME` 分子目录，因为内容包含发行版的安装路径）：
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
普通安装按文件发现单元；`init` 和开发盘专用模式只选择 `wsl-dev-drive.service`。
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

## Windows 开发盘

`common.json` 的 `environments.windows.dev_drive.vhd` 指定 Windows 开发盘的 VHDX，
相对于 `-WindowsHome`，当前为 `AppData/Local/Dev.vhdx`（ReFS 开发盘，挂载为 `J:`）。
Windows 不会在重启后自动重新附加普通 VHDX；从“设置”创建的开发盘登记在
`HKLM\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks\{GUID}` 的 `Path` 值中，
由系统开机附加。playbook 通过 Windows 原生 `AttachVirtualDisk` 的 `AT_BOOT` 标志
完成附加及启动登记，不再靠手写注册表模拟注册。已正确登记并附加的盘保持原样。
旧脚本生成的登记可通过确定的 GUID 精确识别；迁移时默认不自动分离正在使用的盘。
关闭盘上程序并手动分离后可重新部署；只有测试 VM 的受控迁移显式允许自动分离。

盘符不写入配置：附加后从该 VHDX 对应磁盘的分区读取，设为用户级环境变量 `DEV_DRIVE`（如 `J:`），
`common.json` 中 MSYS2 的 `root` 和 `oh-my-posh/msys2.omp.json` 的路径映射都通过它引用开发盘。
VHDX 不存在时，playbook 会先创建动态 VHDX、GPT 分区和 ReFS Dev Drive，再登记和附加。
`size_gib` 控制新盘容量上限，当前为 1024 GiB；已有 VHDX 不调整容量，也不进入格式化分支。
`-WhatIf` 下未附加的开发盘使用已有的 `DEV_DRIVE` 预览。

## WSL 共享开发盘

`common.json` 的 `environments.wsl.dev_drive` 保存共享开发盘配置。
当前指向 Windows 用户主目录下的 `AppData/Local/wsl/dev.vhdx`，
挂载到 `/mnt/wsl/dev`，使用 Btrfs 和 `compress=zstd:1`。
`vhd` 相对于 `-WindowsHome`；`schtasks` 是该发行版访问 Windows 任务工具的完整路径。
如果发行版使用其他 Windows 挂载根目录，应相应调整 `schtasks` 和 `mountpoint`。
UUID 不写入配置：服务第一次在挂载点看到预期类型的文件系统时，把它的 UUID 记录到
`~/.local/state/shell/dev-drive.uuid`，之后的挂载必须与之一致。
这个文件固定留在本地，不随 `XDG_STATE_HOME` 移到开发盘，因为挂载前就要读取它。

普通安装会一并部署此功能，也可以只安装开发盘部分：

```powershell
& "$HOME/.config/shell/install.ps1" -WslDevDriveOnly -WhatIf
& "$HOME/.config/shell/install.ps1" -WslDevDriveOnly
```

`init` 起即注册当前 Windows 账户的 `WSL Attach Dev VHDX` 高权限按需任务。
任务直接执行系统目录的 `wsl.exe --mount --vhd ...`，没有登录或定时触发器。
只有任务缺失或配置变化时才修改，此时会为注册请求一次管理员批准（UAC）。
`-WhatIf` 不创建任务。同名但执行其他操作的任务会被视为冲突并保留。
管理 WSL 发行版时自动注册；`shell_dev_drive_task` 设为 `true` 或 `false` 可强制开启或关闭。

playbook 同时部署并启用 `wsl-dev-drive.service` 用户服务（`init` 也会部署 `~/.config/shell` 链接和这个服务）。
各主机并行执行，启动服务前 WSL 一侧最多等待 2 分钟，直到 Windows 一侧注册好计划任务；
仍未注册时只启用不启动，并给出提示。
发行版中对应用户的 systemd 用户管理器启动时，服务检查挂载点的 UUID 和文件系统。
已经正确挂载时直接成功；其他文件系统占用该挂载点时失败。
尚未挂载时，通过 Windows 任务请求附加，最多等待 60 秒确认挂载成功；
失败由 systemd 重试，五分钟内最多启动三次，结果记录到用户日志。
服务停止时保留共享挂载，避免影响其他发行版。

这项功能需要 systemd、WSL Windows 互操作、jq、findmnt，以及内核对应文件系统支持。
VHDX 不存在时，Windows 任务会先在默认 WSL 发行版准备 `btrfs-progs`，创建动态 VHDX，
校验新设备的容量、分区、挂载和文件系统签名，再建立 Btrfs。`size_gib` 当前为 1024 GiB。
只有本次新建的临时 VHDX 可以格式化，成功分离后才移动到配置路径；
失败的临时盘会保留以便检查，已有文件始终复用。`-WhatIf` 不创建或格式化磁盘。
重建盘后删除 `~/.local/state/shell/dev-drive.uuid`，下次启动服务时重新记录。
Windows 账户必须已登录，才能运行 Interactive 类型的计划任务。
服务按 WSL 用户部署；其他发行版可通过 `-WslDistribution` 一并安装，
各发行版共用同一个 Windows 挂载任务。

```sh
systemctl --user status wsl-dev-drive.service
systemctl --user restart wsl-dev-drive.service
journalctl --user -u wsl-dev-drive.service
findmnt -M /mnt/wsl/dev
```

开发盘创建的独立集成测试使用新的测试目录，保留结果供检查，需在管理员 PowerShell 中运行：

```powershell
& "$HOME/.config/shell/tests/dev_drives.ps1" -Distribution archlinux
```

测试默认使用 50 GiB 动态盘，可用 `-SizeGiB 1024` 验证部署容量。覆盖预览无写入、
ReFS Dev Drive 属性、Btrfs 挂载读写及重复执行后 VHDX 哈希不变。

### 共享 XDG 目录

可以在发行版之间共享的 XDG 基础目录放在开发盘上，由 `common.json` 的 WSL `environment` 设置：

| 变量 | 开发盘已挂载 | 未挂载 |
|---|---|---|
| `XDG_DATA_HOME` | `/mnt/wsl/dev${HOME}/.local/share` | `~/.local/share` |
| `XDG_STATE_HOME` | `/mnt/wsl/dev${HOME}/.local/state` | `~/.local/state` |
| `XDG_CACHE_HOME` | `/mnt/wsl/dev${HOME}/.cache` | `~/.cache` |

开发盘上按主目录分开：root 使用 `/mnt/wsl/dev/root`，WSL 用户使用 `/mnt/wsl/dev/home/<用户名>`。
账户自己不能在 root 所有的挂载点下建目录，所以 `full` 和 `update` 在开发盘已挂载时以 root
为每个受管账户创建这个目录（属主为该账户，权限 `0700`）。

`XDG_CONFIG_HOME` 留在本地：其中有各发行版自己的 systemd 用户单元，包括挂载开发盘的服务。
`XDG_RUNTIME_DIR` 属于当前会话，也留在本地。pnpm 的目录跟随这些变量。
各发行版的安装路径不同（例如 Oh My Posh 在 Arch 是 `/usr/bin/oh-my-posh`，在 Debian 是
`/usr/local/bin/oh-my-posh`），记录了这些路径的缓存不能共享：Oh My Posh 的初始化脚本通过
`OMP_CACHE_DIR=${HOME}/.cache` 留在本地的 `~/.cache/oh-my-posh`（Oh My Posh 只使用已存在的目录，
playbook 会创建 `~/.cache`）；Nushell 的初始化脚本由 `env.nu` 每次启动时写到配置目录的
`oh-my-posh.nu`，不使用共享数据目录中的 vendor autoload；zsh 的插件缓存按发行版分目录。

各 shell 启动时读取 `/proc/self/mounts`：挂载点上是配置的文件系统时定义 `${DEV_DRIVE}`，
使用开发盘上的目录；否则（例如 WSL 刚启动、服务还没挂载好）这个 shell 继续使用本地目录，
不会写进挂载点下的 tmpfs。变量只对从这些 shell 启动的程序生效；
不经过 shell 的 systemd 服务等仍使用本地默认目录。
shell 自身在读取配置前就确定的目录另行处理：PowerShell 把 `$XDG_DATA_HOME/powershell/Modules`
加到 `PSModulePath` 前面；直接启动（没有继承这些变量）的交互式 fish 用原参数重新启动一次，
使历史记录也来自开发盘。
各发行版的同名账户需要有相同的 uid 和 gid，才能读写同一组目录；WSL 用户的 ID 由 playbook 统一（见“WSL 用户”）。

`full` 和 `update` 在开发盘已挂载时，把本地 `~/.local/share`、`~/.local/state` 中的每个条目
移到开发盘的同名位置，原位置不留链接：不读取这些变量的程序之后从空的本地目录开始。
开发盘上已有同名条目时保留本地副本并给出提示，不合并内容（本地只有空目录时直接删除）；`~/.local/state/shell` 不移动；
早期版本留下的、指向开发盘同名条目的链接保持不动。缓存可以重新生成，`~/.cache` 不迁移，
共享缓存从空目录开始。

## WSL 与 Windows Terminal

`install.ps1` 在启动 Ansible 前准备 WSL，因为控制容器本身运行在 WSL 中：

- `wsl.exe --version` 失败（没有安装 WSL 发行版本，只有系统自带的占位程序）时，
  以一次管理员批准运行 `wsl.exe --install --no-distribution`；需要重启时停止并提示重启后再运行。
- 安装 `common.json` 中 `environments.wsl.distributions` 列出、尚未注册的发行版
  （目前为 `archlinux` 和 `Debian`），使用 `--no-launch`，并跳过发行版自带的首次启动设置
  （注册表中的 `RunOOBE` 置 0），账户和软件由 playbook 准备。
- 把列表中的第一个设为默认发行版。未指定 `-WslDistribution` 时，管理列表中已注册的全部发行版。

`-WhatIf` 只列出这些操作。当前 Sandbox 测试没有安装或运行 WSL，因此没有覆盖首次安装 WSL 和发行版。

playbook 管理两份 WSL 设置：

| 文件 | 来源 | 说明 |
|---|---|---|
| `%USERPROFILE%\.wslconfig` | `environments.windows.wslconfig` | 只设置列出的节和键，其余内容保留；`wsl.exe --shutdown` 后生效。 |
| 各发行版的 `/etc/wsl.conf` | `environments.wsl.wsl_conf` 和 `default_user` | 同样逐键设置；`wsl.exe --terminate` 该发行版后生效。 |

Windows Terminal 和 PowerShell 7 从 Microsoft Store 安装（`shell_store_apps`）：
有 winget 时用它的 `msstore` 源安装商店包，之后由商店更新，`update` 模式另外运行 `winget upgrade`；
没有 winget 时（例如 Windows Sandbox），从 GitHub 最新发布安装同一个包系列的 MSIX，
Windows Terminal 使用带依赖的 PreinstallKit。两者都只为当前用户安装，已安装时不改动。
发布版本从 `releases/latest` 的跳转中读取，不使用有频率限制的 API；
`shell_store_cache` 可以指定下载缓存目录。

`windows-terminal.json` 保存受管设置：全局选项、动作和快捷键、默认配置、配色、主题，
以及 MSYS2 和 Nushell 两个自定义配置。playbook 把它合并进 `settings.json`：
对象逐键合并；`actions`、`keybindings` 按 `id`，`schemes`、`themes` 按 `name`，
`profiles.list` 按 `guid` 匹配后合并，没有的条目追加；其他列表整体替换。
自动生成的配置（Visual Studio、WSL、Docker 等）和界面中改动的其他设置保持不变；
`settings.json` 中的注释和末尾逗号可以解析，但写回时不保留注释。
受管设置中的 `${MSYS2_ROOT}`、`${MSYS2_HOME}`、`${MSYS2_USER_HOME}`、`${SCOOP}` 由检测到的路径替换；
某个列表条目引用的变量没有值时（例如不管理 MSYS2），跳过该条目。
窗口位置 `initialPosition` 与显示器有关，不纳入管理。
字体 Maple Mono NF CN 通过 Scoop 的 `nerd-fonts` bucket 安装（`Maple-Mono-NF-CN`）。

## WSL 用户

除 root 外，playbook 在每个受管发行版中维护一个非 root 用户，用户名取 Windows 用户目录名的小写形式
（目前为 `jat`），由 `install.ps1` 作为 `shell_user` 传入。`common.json` 的 WSL 部分设置：

| 字段 | 内容 |
|---|---|
| `user` | 该用户的 `uid` 和 `gid`，目前都是 `1000`。 |
| `ids` | 其他需要在各发行版保持一致的组 ID，目前 `docker` 为 `1001`；同名用户存在时 uid 也设为该值。 |
| `default_user` | 写入 `/etc/wsl.conf` 的 `[user] default`，目前为 `root`；修改后 `wsl.exe --terminate` 该发行版才生效。 |

这些 ID 被上述账户以外的用户或组占用时，playbook 停止并列出占用者；
只在这些账户之间互相占用时（例如 `docker` 和用户组的 gid 对调），先换到临时 ID 再换到目标 ID，
并把原来属于旧 ID 的文件（根文件系统、`/run` 和 `/tmp` 中）改到新 ID 上，例如 Docker Desktop 的 `docker.sock`。
`-WhatIf` 只列出将要做的修改。

用户不存在时创建（主目录取发行版默认值），并通过 `/etc/sudoers.d/<用户名>` 获得免密码 sudo；
yay 以该用户构建 AUR 包。不设置登录密码。
root 和该用户得到相同的入口文件、`links`、systemd 用户单元和 XDG 目录，
并各自从 PSGallery 安装 `shell_powershell_modules` 中的 PowerShell 模块（目前为 PSCompletions），
装在该账户 shell 使用的 `XDG_DATA_HOME` 下；`update` 模式同时更新。
systemd 用户单元的 `default.target.wants` 链接直接创建，用户管理器未运行时也已启用，下次登录时启动。
`links` 中当前账户读不到的目标会跳过：Windows 一侧的 `.ssh`、`.gnupg` 属于 root（权限 `0700`），
所以只链接给 root，WSL 用户使用自己的 `~/.ssh`、`~/.gnupg`。

## CMD 与 Clink

Scoop 安装 Clink 不会自动注册 CMD 的启动命令。`init` 安装软件，`full`/`update`
在部署入口文件和 `HOME` 后，使用官方 `clink autorun install` 为当前用户开启自动注入。
注册位置是 `HKCU\Software\Microsoft\Command Processor\AutoRun`，使用 Scoop 的
`apps/clink/current/clink.bat`，升级 Clink 后路径仍然有效；不设置全局 `HKLM` AutoRun。

安装器保留 AutoRun 中的其他命令，已有当前 Clink 注册和额外参数时不重复注册。
`-WhatIf` 只报告需要注册，不写注册表；`--tags clink` 可单独执行这个配置步骤。
指定其他用户的 `-WindowsHome` 时跳过注册，避免把该用户的配置注册到当前账户。
只执行配置任务但尚未安装 Clink 时，会提示先运行 `init`。

新开的交互式 CMD 自动加载 Clink，再读取 `%LOCALAPPDATA%\clink\profile.lua`
和共享的 `common.lua`、`common.clink_settings`。`cmd /d` 跳过 AutoRun；
`cmd /c` 的非交互命令不是验证注入的方法。
Sandbox 验证包含：预览不写入、保留其他 AutoRun 命令、保留已有 Clink 参数、重复部署，
以及隐藏的交互式 CMD 进程实际加载 `clink_dll_*.dll`；测试后还原测试前的 AutoRun 值。

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
