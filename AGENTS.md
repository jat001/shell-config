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

和 `/etc/skel`、Debian `dot.*`、MSYS2 `etc/skel` 的比较只看用户主目录顶层的 dotfile。路径里有 `/` 的不比。
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

## 测试

隔离回归用 `tests/run.ps1`。状态目录用临时目录，不要指向 `%LOCALAPPDATA%\shell-ansible`。
不要删或覆盖 `C:\Users\Jat` 的现网配置、主目录和已安装的工具。

```powershell
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch,debian
```

`-Target` 要让 PowerShell 把逗号收成数组。`Start-Process -ArgumentList` 里重复写 `-Target` 绑不上，用 `-Command`。

`tests/run.ps1` 开头在控制容器里跑：

- `tests/test_terminal_settings.py`
- `tests/test_release_update.py`（用了 Unix 的 `fcntl`，不能在 Windows 的 CPython 里导入）
- `tests/test_shell_paths.py`
- `tests/test_nushell_defaults.py`
- `tests/test_invariants.py`

可以单独跑、也不碰现网的：

- `tests/system_setup.ps1`：临时目录里的系统步骤计划。PowerShell 5.1 和 7 都能跑。
- `tests/msys2_update.ps1`：临时命令替身测试核心升级重启和普通错误，不运行 MSYS2。
- `tests/hyperv_worker_test.ps1`：模拟启动、热加载与错误恢复，测试并发文件读写和客户机脚本参数，不申请管理员权限。
- `tests/native_commands.ps1`：本机要有 `wslc.exe`。只解析命令，并检查一个不存在的镜像。
- `tests/wsl_cache.ps1 -CacheDirectory <临时目录>`：下载并复用 WSL 缓存，不安装 WSL。
- `tests/common_plan.ps1`：用本机 `jq` 看空参数、没挂上的开发盘和平台判断。

不要在现网上跑：

- `tests/clink.ps1` 会改当前用户的 AutoRun，再改回来。沙盒验证在沙盒里调用它。
- `tests/docker_completions.ps1` 用本机现有的 Docker、WSL 和 MSYS2。
- `tests/dev_drives.ps1` 和 `tests/hyperv.ps1` 要管理员，会创建虚拟磁盘或 Hyper-V 虚拟机。

`tests/run.ps1` 的 Windows 目标是 Windows Sandbox，Linux 目标是 `archlinux:latest` 和 `debian:testing`。
容器里没有 systemd，用户单元只链接，不启动。
`shell-test` 网络固定 `10.77.90.0/24`。wslc 默认的下一个地址池可能是 `172.18.0.0/16`，这台机器的 Hyper-V 默认交换机是 `172.18.144.0/20`。重叠时沙盒 IP 像在本地网桥上，连接报 `No route to host`。
沙盒执行策略是 Restricted。写进模块参数的脚本能跑，磁盘上的 `.ps1` 不行。调用 `system_setup.ps1`、`download.ps1`、`clink.ps1` 之前，把当前进程的执行策略设成 Bypass。
`wsb exec -c` 会把命令字符串里的 PowerShell 开关当成自己的参数。启动命令放进映射进去的 `launch.cmd`，传给 `wsb` 的只是这个文件的路径。
普通用户读不到计划任务服务。CIM 可能把内层 AccessDenied 包成 ResourceUnavailable，按内层错误码判断，别匹配本地化文本。ObjectNotFound 才是任务没注册。

容器和沙盒（`-Target arch,debian,sandbox`，沙盒用完已停）：Arch、Debian、Windows Sandbox 的 `init`、`prepare`、`full`、重复 `full`（`changed=0`）、`update`、`verify` 都是 failed=0。
无提权账户的第二次 `full` 也是 `changed=0`。
Debian 上 WSL 用户 `shell` 加载 PowerShell 通过。发布目录原先是 `0700`，非 root 的 PowerShell 把 `/usr/local/bin/oh-my-posh` 当成不能放进管道的文件。

虚拟机用状态目录里已有的 `ShellConfig-Test`。从 `WSL-Ready` 恢复，同步仓库，再跑 `init,full,full,update`。不要另建同名虚拟机，测完也不要删。
`init`、连续两次 `full`、`update` 已回归，三台都是 failed=0，重复 `full` 的三台都是 `changed=0`。
断电冷启动后，开发盘、各 shell、Clink 和 Terminal GUI 启动的 13 项检查通过，临时自动登录及凭据已清理。
更新构建曾遇 Docker Hub 和 Galaxy TLS EOF，重试后通过；别关闭 TLS 校验或把失败当成成功。
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
`Run` 和 `Guest` 是后台任务，`operations/<id>.json` 只表示成功启动；看对应 `<id>.progress.json` 的 Running 和 Success 判断完成结果。
客户机输出在 `guest-logs/operations/<id>/`，参数文件不在日志收集范围内。

`Sync`、恢复、断电和准备 VM 之前先等后台任务结束，避免覆盖运行中的源码。日常诊断与日志收集可在任务运行时进行。
`Collect` 最后再做一次，将下载缓存取回宿主；日志允许共享读取，写入中的日志也能采集。
临时自动登录只在显式 `EnableLogon` 时设置，`ClearLogon`、验证结束及正常 `Stop` 会清理注册表密码和 LSA 凭据。
完成后 `Stop` 退出管理员执行器，保留测试 VM 和快照，不注册常驻宿主服务或关闭 UAC。
NAT 只转发默认发行版的 `127.0.0.1`，每个 sshd 都听在这个地址上。启动 sshd 之前按 `common.json` 写好 `.wslconfig`，里面要有镜像网络和 `hostAddressLoopback`。文件有变化就 `wsl --shutdown`。连接建立之后不能再 shutdown。
同步进客户机的文件要整文件覆盖。`Copy-Item -ToSession -Force` 换不掉已有文件。

## 改的时候

干净的 `debian:testing` 没有 `ca-certificates`。`ansible/bootstrap/wsl.sh` 得在 Ansible 用 Python 下 HTTPS 密钥之前装上。只装 Python 不够。

Arch 的 `farseerfc` 在官方 keyring 里，但 `pacman-key --init` 不导入它。先 `pacman-key --populate archlinux`，再 `--lsign-key`，然后才能同步带 archlinuxcn 的库。

Windows PowerShell 在 `ErrorActionPreference = Stop` 时，输出被重定向或放进 `Start-Job`，本机程序的 stderr 会变成终止错误。
`wslc` 的进度、找不到的网络或容器、Python unittest 的点都在 stderr。探测和日志在本地把 `ErrorActionPreference` 设为 `Continue`，只看退出码。`install.ps1` 的 `Invoke-Wslc` 就是这样。

`Out-String` 不会折断已经是字符串的 docker inspect 输出。不要为这个去改解析。

Nushell 的 scaffold 用目标上的 `nu -c 'config reset -w'` 现生成。配置目录要先建好。

链接和发布包更新先检查，失败要能恢复。不要改成递归删除或覆盖用户文件。
