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
普通用户读不到计划任务服务。读失败不是“任务没注册”，不要再排一次。

容器和沙盒（`-Target arch,debian,sandbox`，沙盒用完已停）：Arch、Debian、Windows Sandbox 的 `init`、`prepare`、`full`、重复 `full`（`changed=0`）、`update`、`verify` 都是 failed=0。
无提权账户的第二次 `full` 也是 `changed=0`。
Debian 上 WSL 用户 `shell` 加载 PowerShell 通过。发布目录原先是 `0700`，非 root 的 PowerShell 把 `/usr/local/bin/oh-my-posh` 当成不能放进管道的文件。

虚拟机用状态目录里已有的 `ShellConfig-Test`。从 `WSL-Ready` 恢复，同步仓库，再跑 `init,full,full,update`。不要另建同名虚拟机，测完也不要删。
`init`、第一次 `full`、重复 `full` 都是 failed=0，重复那次三台都是 `changed=0`。
这次 `update` 还没有下载重试。Windows 升级 Store 里的 PowerShell 时，`winget upgrade 9MZ1SNWT0N5D` 返回 `-2147012867`，搜索源 `msstore` 失败。Debian 和 Arch 是 failed=0。
这个退出码现在会再试。商店一直连不上，第三次还是失败。这台虚拟机还没用这版再跑。
测试脚本只停提权 worker。
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
