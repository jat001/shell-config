# 代理维护说明

用户怎么安装和使用，看 README。这里只写改代码时要守住的结构、不变量和验证方法。

## 架构

`install.ps1` 是唯一的安装入口。它在 Windows 上准备 WSL，用 `wslc` 构建 Ansible 控制容器，把仓库只读挂到容器的 `/work`，再跑 `ansible/site.yml`。

Windows 不开放 WinRM 或 Windows OpenSSH。第一个 WSL 发行版上的专用 sshd 同时承载 Windows：库存里的 Windows 主机使用 `ansible_shell_type: powershell`，`/etc/shell-ansible/bin/PowerShell` 经 WSL interop 启动 Windows PowerShell。这些进程是当前用户的普通令牌。`-SkipWsl` 仍必须留下这个传输用的发行版。

Playbook 以 `strategy: free` 并行配置 Windows/MSYS2 和各 Linux 主机。入口清单在 `ansible/group_vars/all/main.yml` 的 `shell_entries`，软件清单在 `packages.yml`。`shell_paths` / `win_shell_paths` 先检查一整组目标，再一起修改。

运行状态、SSH 密钥和本次库存在 `%LOCALAPPDATA%\shell-ansible`，不要写进仓库。

## 不变量

- 入口和链接：相同的保留；内容不同的普通文件或非空目录让整组失败并保留原文件。模块不递归删除目录，也不做备份。只有和入口内容相同的文件、空目录、指向别处的链接，以及和发行版模板完全相同的默认 dotfile，可以替换。
- 和 `/etc/skel`、Debian `dot.*`、MSYS2 `etc/skel` 的比较只针对用户主目录顶层的 dotfile。路径里含 `/` 的文件不走这套比较。Debian 的 Nushell 包在 postinst 里执行 `config reset -w`，会留下 `/root/.config/nushell/env.nu` 和 `config.nu`。部署前用同一支 `nu` 在临时家目录生成 scaffold，只有内容完全一致才通过 `defaults` 替换。不要把这两个文件当成可以无条件覆盖的入口。`config nu --default` 是另一份内置文件，不能拿来比较。
- 配置文件是 UTF-8、无 BOM、LF。
- 共用的环境变量和外部命令 alias 只放在 `common.json`。平台判断在 `common.jq`。各 shell 必须把 `MSYSTEM`、`WSL_DISTRO_NAME`、`WSL_INTEROP` 传给 jq，包括空值。Windows PowerShell 会丢掉空的本机参数，所以这些值只在 WSL 上传递。
- `${DEV_DRIVE}` 和 `${WINDOWS_HOME}` 只用于展开，不导出。WSL 上 `DEV_DRIVE` 仅在 `/proc/self/mounts` 里挂载点的文件系统与配置一致时定义。
- 已由其他方式安装的同名命令不接管。GitHub 发布包先校验长度、上游 SHA256 和 ELF，再原子切换链接；失败时恢复旧链接。
- 开发盘的 VHDX 路径必须落在 `-WindowsHome` 下面，并且是 `.vhdx`。已有盘不调整容量、不格式化。
- 控制容器标签是 `Containerfile` 与两份 `requirements` 的哈希。已有同标签镜像或缓存里的 tar 直接用。`update` 才 `--pull --no-cache` 重建，构建一共试 3 次。成功后的镜像 tar 写到下载缓存的 `images`。pip 和 Galaxy 仍用构建缓存挂载，基础镜像留在 wslc 的本地镜像库。
- 一次性下载（WSL 安装包、Scoop 安装脚本、通用文件、归档头、apt 签名密钥、Store 的 GitHub 回退）失败时一共试 3 次。winget 退出码 `0` 和 `-1978335189`（没有可升级的版本）算成功。`-1978335138` 先刷新一次 winget 客户端再继续。其余失败，包括 `-2147012867`（连不上 Microsoft Store），用完 3 次才失败。有 winget 时 Store 应用不写入这份下载缓存。

## 测试

隔离回归用 `tests/run.ps1`。不要把它指向用户的 `%LOCALAPPDATA%\shell-ansible`，状态目录用临时目录。不要对 `C:\Users\Jat` 的现网配置、主目录或已安装工具做删除或覆盖。

```powershell
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch
& .\tests\run.ps1 -StateDirectory "$env:TEMP\shell-audit" -Target arch,debian
```

`-Target` 要让 PowerShell 把逗号解析成数组。`Start-Process -ArgumentList` 里重复写 `-Target` 绑不上，应使用 `-Command`。

跑测脚本在开头用控制容器执行：

- `tests/test_terminal_settings.py`
- `tests/test_release_update.py`（依赖 Unix 的 `fcntl`，不能在 Windows 的 CPython 里导入）
- `tests/test_shell_paths.py`
- `tests/test_nushell_defaults.py`
- `tests/test_invariants.py`

其他可单独跑、且不碰现网配置的测试：

- `tests/system_setup.ps1`：临时目录里的系统步骤计划，PowerShell 5.1 和 7 都可跑。
- `tests/native_commands.ps1`：需要本机已有 `wslc.exe`，只解析命令并检查不存在的镜像。
- `tests/wsl_cache.ps1 -CacheDirectory <临时目录>`：下载并复用 WSL 缓存，不安装 WSL。
- `tests/common_plan.ps1`：用本机 `jq` 检查空参数、未挂载的开发盘和平台判断。不改现网配置。

不要在现网上跑这些：

- `tests/clink.ps1` 会改当前用户的 AutoRun，再还原。沙盒验证会在沙盒里调用它。
- `tests/docker_completions.ps1` 使用现有的 Docker、WSL 和 MSYS2。
- `tests/dev_drives.ps1` 和 `tests/hyperv.ps1` 需要管理员，并且会创建虚拟磁盘或 Hyper-V 虚拟机。

`tests/run.ps1` 的 Windows 目标是 Windows Sandbox，Linux 目标是 `archlinux:latest` 和 `debian:testing` 容器。容器没有 systemd，用户单元只链接不启动。

容器和沙盒回归（`tests/run.ps1 -StateDirectory $env:TEMP\shell-audit -Target arch,debian,sandbox`，沙盒用完已停）：Arch、Debian 和 Windows Sandbox 的 `init`、`prepare`、`full`、重复 `full`（`changed=0`）、`update` 和 `verify` 都是 failed=0。无提权账户的第二次 `full` 也是 `changed=0`。Debian 上 WSL 用户 `shell` 加载 PowerShell 通过：发布目录原先是 `0700`，非 root 的 PowerShell 把 `/usr/local/bin/oh-my-posh` 当成不能放进管道的文件。

干净虚拟机仍用状态目录里已有的 `ShellConfig-Test`（不要另建同名虚拟机）。从 `WSL-Ready` 恢复并同步仓库后跑 `init,full,full,update`。`init`、第一次 `full` 和重复 `full`（三台都是 `changed=0`）都是 `failed=0`。这次 `update` 还没有下载重试，停在 Windows 升级 Microsoft Store 里的 PowerShell：`winget upgrade 9MZ1SNWT0N5D failed (-2147012867)`，搜索源 `msstore` 失败。这个退出码现在会再试，商店一直连不上时第三次仍然失败。这次虚拟机没有用加重试之后的代码再跑。Debian 和 Arch 的这次 `update` 是 `failed=0`。测试脚本只停止提权 worker，不删除这台虚拟机。NAT 只转发默认发行版的 `127.0.0.1`，所以安装器要在启动 sshd 之前写好镜像网络并在 `.wslconfig` 有变化时 `wsl --shutdown`。同步客户机文件必须整文件覆盖；`Copy-Item -ToSession -Force` 不会替换已有文件。

## 改代码时要注意

- 干净的 `debian:testing` 没有 `ca-certificates`。`ansible/bootstrap/wsl.sh` 必须在 Ansible 用 Python 下载 HTTPS 密钥之前装上它。只装 Python 不够。
- Arch 的 `farseerfc` 密钥在官方 keyring 里，但是 `--init` 不会导入它。要先 `pacman-key --populate archlinux`，再 `--lsign-key`，然后才能同步带 archlinuxcn 的数据库。
- Windows PowerShell 在 `ErrorActionPreference = Stop` 并且输出被重定向或放进 `Start-Job` 时，会把本机程序的 stderr 当成终止错误。`wslc` 的进度、找不到的网络或容器、Python unittest 的点都在 stderr。探测和日志要在本地把 `ErrorActionPreference` 设为 `Continue`，只根据退出码失败。`install.ps1` 的 `Invoke-Wslc` 已经是这样做的。
- `wsb exec -c` 会把命令字符串里的 PowerShell 开关当成自己的参数。沙盒启动命令放在映射进去的 `launch.cmd`，传给 `wsb` 的只是这个文件的路径。
- `Out-String` 不会折断已经是字符串的 docker inspect 输出；不要为了这个去改解析。空的本机参数会被 PowerShell 丢掉，`@($null)` 不会。Nushell 会保留空参数。
- Nushell 的 scaffold 要用目标上的 `nu -c 'config reset -w'` 现生成。配置目录必须先建好，否则命令成功但不写文件；`--no-config-file` 同样不写。生成时如果改动了账户自己的 `env.nu` 或 `config.nu`，捕获任务必须失败。
- 链接模块和发布包更新要保持先检查、失败可恢复。不要顺手改成递归删除或覆盖用户文件。
- `install.ps1` 在启动各发行版的 sshd 之前，先按 `common.json` 写好 `.wslconfig`，文件有变化时执行 `wsl --shutdown`。NAT 只把默认发行版的 `127.0.0.1` 转发到 Windows，而每个 sshd 都听在这个地址上。镜像网络和 `hostAddressLoopback` 生效之后，第二个发行版的端口才能在 Windows 上回环看到。连接已经建立之后不能再 shutdown。
- 发布目录用 `TemporaryDirectory` 创建，模式是 `0700`。二进制和它上面直到发布根的每一层目录都要让其他账户能执行。否则非 root 的 PowerShell 对 `/usr/local/bin/oh-my-posh` 报 `Cannot run a document in the middle of a pipeline`。
- `tests/run.ps1` 的 `shell-test` 网络要固定在 `10.77.90.0/24`。wslc 默认的下一个地址池可能是 `172.18.0.0/16`，这台机器的 Hyper-V 默认交换机是 `172.18.144.0/20`。地址重叠时，沙盒 IP 看起来像在本地网桥上，连接报 `No route to host`。
- Windows Sandbox 的执行策略是 Restricted。写进模块参数里的脚本不受这个限制，磁盘上的 `.ps1` 受限制。调用文件之前要把当前进程的执行策略设成 Bypass。普通用户读不到计划任务服务时，不要把 WSL 开发盘任务当成缺失再排一次注册。
