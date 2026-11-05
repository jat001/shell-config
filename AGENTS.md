# 安装器

安装和使用见 README。

`install.ps1` 是唯一入口。它在 Windows 上准备 WSL，用 `wslc` 构建 Ansible 控制容器，仓库只读挂到容器的 `/work`，再跑 `ansible/site.yml`。

Windows 不开 WinRM，也不开 Windows OpenSSH。
第一个 WSL 发行版上的 sshd 同时连 Windows。库存里的 Windows 主机用 `ansible_shell_type: powershell`，`/etc/shell-ansible/bin/PowerShell` 经 WSL interop 启动 Windows PowerShell。这些进程用的是当前用户的普通令牌。
`-SkipWsl` 也得留下这个发行版。

Playbook 用 `strategy: free`，Windows/MSYS2 和各 Linux 主机一起配。
入口在 `ansible/group_vars/all/main.yml` 的 `shell_entries`，软件在 `packages.yml`。
`shell_paths` / `win_shell_paths` 先检查一整组，再一起改。

运行状态、SSH 密钥和这次库存在 `%LOCALAPPDATA%\shell-ansible`，不进仓库。

## 守住这些

入口和链接先检查再改。相同的留下。内容和入口不同的普通文件，或非空目录，整组失败，原文件留着。
模块不递归删目录，也不做备份。能换掉的只有：和入口内容相同的文件、空目录、指向别处的链接、和发行版模板完全相同的默认 dotfile。

和 `/etc/skel`、openSUSE `/usr/etc/skel`、Debian `dot.*`、Fedora `/usr/share/rootfiles`、MSYS2 `etc/skel` 的比较只看用户主目录顶层的 dotfile。读不到的默认文件按不匹配处理。路径里有 `/` 的不比。
openSUSE 的 `/usr/etc/skel` 是 `0640 root:root`。新建 WSL 账户时由 playbook 建空主目录，`useradd` 不复制模板，否则新账户读不到这些模板也无法比较。
Debian 的 Nushell 包在 postinst 里跑 `config reset -w`，留下 `/root/.config/nushell/env.nu` 和 `config.nu`。
部署前用同一支 `nu`，在临时家目录生成 scaffold，内容完全一致才按 `defaults` 换。这两个文件不能无条件覆盖。
`config nu --default` 是另一份内置文件，不能拿来比。`config reset -w` 在配置目录不存在时退出 0 但不写文件，`--no-config-file` 也不写。生成时若改动了账户自己的 `env.nu` 或 `config.nu`，这次捕获要失败。

配置文件是 UTF-8、无 BOM、LF。

共用的环境变量和外部命令 alias 只放 `common.json`。平台判断在 `common.jq`。
各 shell 把 `MSYSTEM`、`WSL_DISTRO_NAME`、`WSL_INTEROP` 传给 jq，空值也传。
Windows PowerShell 会丢掉空的本机参数，所以这三个值只在 WSL 上传递。`@($null)` 不会被丢掉。Nushell 会保留空参数。

`${DEV_DRIVE}` 和 `${WINDOWS_HOME}` 只用来展开，不导出。
WSL 上的 `DEV_DRIVE` 仅在 `/proc/self/mounts` 里挂载点的文件系统和配置一致时才有。

别的方式已经装好的同名命令不接管。
GitHub 发布包先核对长度、上游 SHA256 和 ELF，再原子换链接。失败把旧链接放回去。
发布目录由 `TemporaryDirectory` 创建，模式 `0700`。二进制以及往上直到发布根的每一层目录都要让其他账户能执行，否则非 root 的 PowerShell 对 `/usr/local/bin/oh-my-posh` 报 `Cannot run a document in the middle of a pipeline`。版本没变时只改权限，不重新下载。

开发盘的 VHDX 必须在 `-WindowsHome` 下面，而且是 `.vhdx`。已有的盘不改容量，也不格式化。

控制容器的标签是 `Containerfile` 和两份 `requirements` 的哈希。同标签的本地镜像或缓存里的 tar 直接用。
只有 `update` 才 `--pull --no-cache` 重建。构建试 3 次，成功后的镜像 tar 写到下载缓存的 `images`。
pip 和 Galaxy 仍用构建缓存挂载。基础镜像留在 wslc 的本地镜像库，`update` 还是会 `--pull`。

一次性下载失败再试，一共 3 次。包括 WSL 安装包、Scoop 安装脚本、通用文件、归档头、apt 签名密钥，以及没有 winget 时从 GitHub 下的 Store 包。
winget 退出码 `0` 和 `-1978335189`（没有可升级的版本）算成功。`-1978335138` 先刷新一次 winget 客户端再继续。
其余的，包括 `-2147012867`（连不上 Microsoft Store），第三次仍失败才停。有 winget 时，Store 应用不放进这份下载缓存。

每次调用通用 `download.ps1`，都会在缓存的 `records` 里留一份 JSON。能看出有没有命中缓存、文件多大、成功下载了多少字节、试了几次、花了多久。命中时 `networkBytes=0`，不算平均速度；失败那几次收了多少没法确定，就不填。URL 的查询参数不进日志，日志写不进去也不影响下载。
这里只记 `download.ps1` 自己看到的流量。WSL 专用下载器、Docker、apt、pip、Galaxy 和别的包管理器都不算在内，别拿它当总下载量。

部署从运行安装器的宿主机读取 Windows 时区和当前用户 Culture。Windows 时区走 `system_setup.ps1` 的计划/提权流程，Culture 只改当前账户。Linux/WSL 用仓库里的 CLDR 默认映射转换时区，生成对应 UTF-8 locale，并设置系统 `LANG` 和 `LC_ALL`；不改显示语言、输入法或非 Unicode 系统区域。非英语环境额外启用并生成 `en_US.UTF-8`，默认 `LANG` 不变。`locale.gen` 固定启用第一处匹配，重复启用项去掉，Debian postinst 在末尾补的注释不误启用，其他 locale 不动。MSYS2 的时区和 `LANG` 自动继承 Windows，`LC_ALL` 也在 common shell 里通过 `locale -uU` 自动设置，不维护单独的 locale profile。宿主机进程显式设置 `LC_ALL` 时优先沿用，否则使用 Culture 对应的 UTF-8 locale。未知时区、非具体语言-地区 Culture 要失败，不能猜测。
MSYS2 进程若没有 `USERPROFILE`，common shell 用 Windows API 查询用户目录，再经 `cygpath` 转成 `WINDOWS_HOME` 展开值；不能展开成空路径。`LOCALAPPDATA` 从 `WINDOWS_HOME` 展开，供 antidote 使用。
WSL 不只写系统 locale 文件。common shell 要从 `/etc/locale.conf` 或 `/etc/default/locale` 读取并显式导出 `LC_ALL`，覆盖直接 `wsl.exe`、Bash、zsh、fish、PowerShell 和 Nushell；`su -` 的 PAM 检查不能代替这些入口。
只跑区域设置用 `--tags regional -e shell_regional_only=true`；这个开关同时跳过 `always` 的软件引导、仓库准备和账户入口任务。正常部署不要传它。
Arch 官方容器的 `NoExtract` 排除了非英文 locale 源文件。缺目标源文件时，在 options 的提取规则末尾加目标例外并重装 `glibc`；不能只跑 `locale-gen`，它可能返回 0 但没有生成 locale。
openSUSE Tumbleweed 的 locale 在 `glibc-locale` 里预先编译，没有 `/etc/locale.gen` 和 `locale-gen`。部署只检查 `locale -a`，不写 locale 定义文件。`/usr/etc/profile.d/lang.sh` 在 `LC_ALL` 等于 `LANG` 时会 unset `LC_ALL`；common shell 仍从 `/etc/locale.conf` 显式导出。

## 测试

隔离回归用 `tests/run.ps1`。状态目录用临时目录，不要指向 `%LOCALAPPDATA%\shell-ansible`。
不要删或覆盖 `C:\Users\Jat` 的现网配置、主目录和已安装的工具。

```powershell
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch,debian
```

`-Target` 要让 PowerShell 把逗号收成数组。`Start-Process -ArgumentList` 里重复写 `-Target` 绑不上，用 `-Command`。

平时想少跑几步，可以加 `-Profile fast` 或 `-Profile standard`。`fast` 只跑 `init,prepare,full,verify`；`standard` 除了 `update` 其他照跑。Hyper-V 分别对应 `init,full` 和 `init,full,full`。
不带 `-Profile` 还是 `full`，发布前照原来的完整流程跑。想自己挑步骤就用 `-Step` 或 `-Modes`，别和 `-Profile` 混用。

换了状态目录还想复用已经下好的东西，可以加 `-CacheDirectory <临时缓存目录>`。默认缓存仍在各状态目录里。共享目录只能串行用，别指向现网缓存，也别让几个测试进程一起写。
自定义库存时，客户机的 `shell_download_cache` 由库存决定，安装器不会再把宿主缓存路径覆盖进去。Sandbox 固定用映射进去的 `C:\shell-cache`。
失败后想接着跑，首轮要加 `-Keep`，下次用同一个状态目录加 `-Reuse -Keep`，剩下的步骤用 `-Step` 列出来。它不会替你记哪些步骤已经过了。

`tests/run.ps1` 开头直接在 Windows 跑 `tests/regional.ps1` 和 `tests/system_setup.ps1`，再在控制容器里跑：

- `tests/test_terminal_settings.py`
- `tests/test_release_update.py`（用了 Unix 的 `fcntl`，不能在 Windows 的 CPython 里导入）
- `tests/test_shell_paths.py`
- `tests/test_nushell_defaults.py`
- `tests/test_locale_gen.py`
- `tests/test_invariants.py`
- `tests/test_shell_startup.py`

可以单独跑、也不碰现网的：

- `tests/regional.ps1`：只测试 CLDR 时区映射、Culture 转换和宿主机采集，不调用设置命令。
- `tests/system_setup.ps1`：临时目录里的系统步骤计划，包含时区匹配、变更和 WhatIf 替身。PowerShell 5.1 和 7 都能跑。
- `tests/msys2_update.ps1`：临时命令替身测试核心升级重启和普通错误，不运行 MSYS2。
- `tests/hyperv_worker_test.ps1`：模拟启动、热加载与错误恢复，测试并发文件读写和客户机脚本参数，不申请管理员权限。
- `tests/native_commands.ps1`：本机要有 `wslc.exe`。只解析命令，并检查一个不存在的镜像。
- `tests/wsl_cache.ps1 -CacheDirectory <临时目录>`：下载并复用 WSL 缓存，不安装 WSL。
- `tests/common_plan.ps1`：用本机 `jq` 看空参数、没挂上的开发盘和平台判断。
- `tests/download_metrics.ps1`：用临时 `file://` 文件检查缓存命中和下载记录，脚本只返回路径，不访问网络。

`tests/verify.yml` 还会对 root 和 WSL 用户分别调用 `tests/shell_startup.py`，在伪终端里启动 bash、zsh、fish、pwsh、nu，检查初始化、提示符和补全器。测试清掉继承的配置变量，明确断言 ble.sh 已加载，不能只看退出码或环境变量。

不要在现网上跑：

- `tests/clink.ps1` 会改当前用户的 AutoRun，再改回来。沙盒验证在沙盒里调用它。
- `tests/docker_completions.ps1` 用本机现有的 Docker、WSL 和 MSYS2。
- `tests/dev_drives.ps1` 和 `tests/hyperv.ps1` 要管理员，会创建虚拟磁盘或 Hyper-V 虚拟机。

`tests/run.ps1` 的 Windows 目标是 Windows Sandbox，Linux 目标是 `archlinux:latest`、`debian:testing`、`opensuse/tumbleweed:latest` 和 `fedora:45`。
容器里没有 systemd，用户单元只链接，不启动。
`shell-test` 网络固定 `10.77.90.0/24`。wslc 默认的下一个地址池可能是 `172.18.0.0/16`，这台机器的 Hyper-V 默认交换机是 `172.18.144.0/20`。重叠时沙盒 IP 像在本地网桥上，连接报 `No route to host`。
沙盒执行策略是 Restricted。写进模块参数的脚本能跑，磁盘上的 `.ps1` 不行。调用 `system_setup.ps1`、`download.ps1`、`clink.ps1` 之前，把当前进程的执行策略设成 Bypass。
`wsb exec -c` 会把命令字符串里的 PowerShell 开关当成自己的参数。启动命令放进映射进去的 `launch.cmd`，传给 `wsb` 的只是这个文件的路径。
普通用户读不到计划任务服务。CIM 可能把内层 AccessDenied 包成 ResourceUnavailable，按内层错误码判断，别匹配本地化文本。ObjectNotFound 才是任务没注册。

容器和沙盒（`-Target arch,debian,suse,fedora,sandbox`，沙盒用完已停）：Arch、Debian、openSUSE、Fedora、Windows Sandbox 的 `init`、`prepare`、`full`、重复 `full`（`changed=0`）、`update`、`verify` 都是 failed=0。
无提权账户的第二次 `full` 也是 `changed=0`，随后只跑 `user` 标签里的入口、链接、HOME、Culture 和 `.wslconfig` 检查，不套用管理员的软件矩阵。
Debian 上 WSL 用户 `shell` 加载 PowerShell 通过。发布目录原先是 `0700`，非 root 的 PowerShell 把 `/usr/local/bin/oh-my-posh` 当成不能放进管道的文件。

虚拟机用状态目录里已有的 `ShellConfig-Test`。从 `WSL-Ready` 恢复，同步仓库，再跑 `init,full,full,update`。不要另建同名虚拟机，测完也不要删。
VM 里的 Debian 必须和容器一样跑 testing。`hyperv_guest.ps1` 给安装器加 `-TestDebianTesting`，bootstrap 只替换 Debian 官方源并做 `full-upgrade`，`shell-*` 第三方源不动。普通安装不传这个开关，仍用 stable。
`init`、连续两次 `full`、`update` 已回归，Windows 和 archlinux、Debian、openSUSE 都是 failed=0，重复 `full` 都是 `changed=0`。更新后的断电冷启动验证通过（20 项检查），自动登录产生交互会话，AtLogOn 任务运行并在结束时清理凭据。
冷启动前要对 Winlogon 键本身调用 `RegFlushKey`；只 flush `HKLM\SOFTWARE` 会在强制断电时丢掉 `AutoAdminLogon` 和 `DefaultPassword`，自动登录不会发生，计划任务也不会触发。
MSYS2 的 `LC_ALL` 只在交互 shell 里由 `locale -uU` 设置；`verify-msys2.sh` 要在 `bash/zsh/fish -ic` 里断言，父 shell 看不到。
断电冷启动后的 16 项检查包括开发盘、启动设置、各 shell、Clink、WSL 用户和 Terminal GUI。临时自动登录及凭据必须清理，无提权 Windows 账户矩阵留在 Sandbox，不在 VM 里重复。
更新构建曾遇 Docker Hub 和 Galaxy TLS EOF，重试后通过；别关闭 TLS 校验或把失败当成成功。PowerShell Gallery 的 `Save-PSResource` 和 winget 的 Store 源也会遇到 TLS/超时，属于外部网络，重试即可。
客户机的 `wslc image save` 可能写出缺少 `manifest.json`/`index.json` 的 tar。导入前用 `tar -tf` 核对；必要时用宿主机的 `wslc image save` 生成完整归档再同步。
MSYS2 核心升级会主动关闭当前 Bash。只有退出 1 且出现明确核心重启提示时，第一轮升级才能接续；第二轮用新进程执行，仍检查退出码。
测试脚本只停提权 worker。

Hyper-V 测试只用一个宿主管理员执行器。先 `tests/hyperv.ps1 -Action Start`，已有进程时直接复用。
后续 `Prepare`、`Sync`、`Run`、`Status`、`Collect`、`Restore`、`ColdBoot`、`EnableLogon`、`ClearLogon` 和 `Stop` 都排到它的队列；没启动时直接报错，不为每个动作另弹 UAC。
`Prepare` 调用的准备子进程继承管理员令牌，不再请求提权。首次启用宿主组件需要重启时，重启后仍要重新启动执行器。

`tests/hyperv.ps1` 保留启动和请求循环，`tests/hyperv_actions.ps1` 在每次操作、进度查询时重新加载。
修改或修复操作脚本后继续提交请求，别重启管理员进程。固定入口自身的修改在下一次启动时生效。
状态目录由 PID、进程启动时间和执行器 Instance 标识，PS5.1/PS7 都能识别；不靠 PID 单独判断。
默认空闲两小时退出，运行中的客户机任务结束后重新计算空闲时间。

临时诊断和附加测试用同一入口，例如：

```powershell
& .\tests\hyperv.ps1 -Action Guest -ScriptPath C:\Temp\check.ps1 -ScriptArguments @{ Label = 'probe' }
```

`Guest` 在已核对身份的 VM 中执行独立脚本，不执行任意宿主脚本。源文件和结构化参数直接传入，无需再起一个诊断 worker。
客户机临时执行副本带 UTF-8 BOM，以兼容 Windows PowerShell 5.1；仓库源码仍保持 UTF-8 无 BOM / LF。
要调用客户机仓库里的现有测试，可在独立脚本中使用 `$env:USERPROFILE/.config/shell/tests/...`，别假定临时脚本的 `$PSScriptRoot` 是仓库目录。
`Run` 和 `Guest` 是后台任务，`operations/<id>.json` 只表示成功启动；看对应 `<id>.progress.json` 的 Running 和 Success 判断完成结果。`Run` 会等同一 OperationId 的验证结束；更新档还会在 worker 里完成临时自动登录和断电冷启动，部署进程退出不等于测试已经成功。
验证结果先写临时文件并落盘再替换，断电前还会再 flush。JSON 损坏要直接失败，别把它当成“还在跑”。
客户机输出在 `guest-logs/operations/<id>/`，参数文件不在日志收集范围内。

`Sync`、恢复、断电和准备 VM 之前先等后台任务结束，避免覆盖运行中的源码。日常诊断与日志收集可在任务运行时进行。
`Collect` 最后再做一次，将下载缓存取回宿主；日志允许共享读取，写入中的日志也能采集。
临时自动登录可由显式 `EnableLogon` 或更新部署的冷启动阶段设置，`ClearLogon`、验证结束及正常 `Stop` 会清理注册表密码和 LSA 凭据。
完成后 `Stop` 退出管理员执行器，保留测试 VM 和快照，不注册常驻宿主服务或关闭 UAC。
NAT 只转发默认发行版的 `127.0.0.1`，每个 sshd 都听在这个地址上。启动 sshd 之前按 `common.json` 写好 `.wslconfig`，里面要有镜像网络和 `hostAddressLoopback`。文件有变化就 `wsl --shutdown`。连接建立之后不能再 shutdown。
同步进客户机的文件要整文件覆盖。`Copy-Item -ToSession -Force` 换不掉已有文件。

## 改的时候

干净的 `debian:testing` 没有 `ca-certificates`。`ansible/bootstrap/wsl.sh` 得在 Ansible 用 Python 下 HTTPS 密钥之前装上。只装 Python 不够。
干净的 `opensuse/tumbleweed` 没有 Python、sshd 和 btrfs 工具。`wsl.sh` 用 zypper 先刷新再装 `ca-certificates openssh python3 btrfsprogs`。
openSUSE 的 `sshd` 10.6 在 `-D` 模式下不写 `PidFile`。`start-sshd.sh` 在 `exec` 前把自己的进程号写进 `sshd.pid`，停止和测试都读这个文件。
openSUSE 的 WSL 镜像还缺 `tar`、`gzip` 和 `findmnt`。`packages_suse` 要装 `tar`、`gzip`、`util-linux-systemd`；少了前两个，`ble.sh` 的 `.tar.xz` 不能解压，少了 `findmnt`，`wsl-dev-drive.service` 会等满 60 秒后失败。
openSUSE 的普通用户读不到块设备 UUID，`findmnt -o UUID` 为空。`wsl-dev-drive.sh` 在 UUID 为空时用 `sudo -n blkid` 补查；WSL 账户有免密 sudo。
openSUSE 的 `/etc/profile` 对登录 bash 先 source `~/.bashrc`，随后 bash 再读 `~/.bash_profile`，`common.bash` 会执行两次。用 `_shell_bash_loaded` 防重入；否则 ble.sh 会打印 `[ble: reload]` 并重建缓存。
WSL 把发行版快捷方式写在 `%APPDATA%\Microsoft\Windows\Start Menu\<名>.lnk` 根目录；Windows 的 All apps 只枚举 `Programs`。`install.ps1` 对每个已注册发行版把它移到 `Programs`，按 `--distribution-id` 去重，不覆盖指向其他发行版的同名文件。

Arch 的 `farseerfc` 在官方 keyring 里，但 `pacman-key --init` 不导入它。先 `pacman-key --populate archlinux`，再 `--lsign-key`，然后才能同步带 archlinuxcn 的库。

Windows PowerShell 在 `ErrorActionPreference = Stop` 时，输出被重定向或放进 `Start-Job`，本机程序的 stderr 会变成终止错误。
`wslc` 的进度、找不到的网络或容器、Python unittest 的点都在 stderr。探测和日志在本地把 `ErrorActionPreference` 设为 `Continue`，只看退出码。`install.ps1` 的 `Invoke-Wslc` 就是这样。

`Out-String` 不会折断已经是字符串的 docker inspect 输出。不要为这个去改解析。

`ansible.cfg` 的 ssh 连接关掉了 `usetty`。`su` 提权本来不提问，而 systemd 262 的 `pam_systemd` 会给带伪终端的会话写 OSC 3008 标记；Ansible 一旦加 `-tt`，`end=` 就落在模块 JSON 后面，每个任务都报一次“junk after the JSON data”。没有 tty 时它什么都不写。

Nushell 的 scaffold 用目标上的 `nu -c 'config reset -w'` 现生成。配置目录要先建好。

`FedoraLinux-45` 从 Microsoft 的 `DistributionInfo.json` 读取对应架构的镜像 URL 和 SHA256，校验后用 `--from-file` 注册。
Fedora 没有 `/etc/locale.gen` 和 `locale-gen`，locale 由 `glibc-langpack-<语言>` 提供。区域任务按语言安装语言包，再从 `locale -a` 确认，不写 locale 定义文件。
Fedora 45 默认 Python 3.15 和 DNF5，ansible-core 2.22 已支持目标端 3.15。`wsl.sh` 和 `main.yml` 装 `python3-libdnf5`，`packages_redhat.yml` 和区域任务用 `ansible.builtin.dnf5`。`blesh` 和 `zsh-antidote` 不在 Fedora 仓库，走 `fallbacks.yml`。
Fedora 45 默认 OpenSSL 4，PowerShell/.NET 仍要找 `libssl.so.3`；`shell_redhat_packages` 同时装 `openssl3-libs`，否则 `Save-PSResource` 报 `No usable version of libssl was found`。
官方 Fedora WSL Base 镜像不带 `awk`（`fedora:45` 容器镜像带），ble.sh 启动时会报 insane environment 并取消加载；`fedora:45` 容器镜像还缺 `ps`。`shell_redhat_packages` 里要有 `gawk` 和 `procps-ng`。openSUSE Tumbleweed 也没有 `awk`，`shell_zypper_packages` 里同样要有 `gawk`。
Fedora 45 的 nushell 0.99 没有 `job list`，而 oh-my-posh 生成的 nu init 会无条件引用它。`common-env.nu` 按 `scope commands` 将不支持的 `--job-count` 表达式替换为 0。0.99 的 `$env.config` 可能不存在，安装补全前要初始化空记录；补全器同时接受旧版的参数列表和新版的 `command` 记录。

链接和发布包更新先检查，失败要能恢复。不要改成递归删除或覆盖用户文件。
