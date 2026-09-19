# Realm 中转管理

用 [Realm](https://github.com/zhboner/realm) 做 TCP/UDP 端口转发的终端菜单：部署和更新 Realm、增删转发规则、管理 systemd 服务。Realm 程序装在 `/opt/realm/realm`，转发配置在 `/etc/realm/config.toml`。支持的系统：

| 系统 | 版本 |
|---|---|
| Debian | 10 11 12 13 14 |
| Ubuntu | 18.04 20.04 22.04 24.04 26.04 |
| Rocky Linux | 8 9 10 |
| AlmaLinux | 8 9 10 |

## 一键安装

在 VPS 上以 root 执行；需要已安装 `curl` 和 CA 证书：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/macwk-com/realm-script/main/install.sh)
```

如果提示找不到 curl，先执行：

```bash
apt update && apt install -y curl ca-certificates
```

安装脚本先查询 `main` 分支的最新提交再按提交下载管理脚本，检查 Bash 语法后保存为 `/usr/local/bin/realmctl`，并打开菜单。推送后一分钟内就能装到新版本，不受 GitHub 下载地址 5 分钟缓存的影响。安装快捷命令本身不会安装 Realm，也不会改动转发规则。新服务器在菜单里先选 **8 部署 Realm**，再选 **2 添加转发规则**。

以后直接输入：

```bash
realmctl
```

普通用户先下载安装脚本，再用 sudo 执行，以后用 `sudo realmctl`：

```bash
curl -fsSL https://raw.githubusercontent.com/macwk-com/realm-script/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh
```

也可以先下载、检查再执行：

```bash
curl -fSL https://raw.githubusercontent.com/macwk-com/realm-script/main/install.sh -o install.sh
less install.sh
bash install.sh
```

下面命令行示例中的 `bash realm.sh`，安装后也可以直接写成 `realmctl`。

## 各系统的差异

- **Realm 安装包**：官方默认的 Linux 版要求 glibc 2.38（Debian 13、Ubuntu 24.04、Rocky 10 起）。更老的系统自动改用官方的 glibc 2.28 版；Ubuntu 18.04 的 glibc 只有 2.27，用官方的 musl 静态版。
- **tomlkit**：脚本用它读写转发配置，需要 0.8 以上。Debian 10–11、Ubuntu 18.04–20.04、Rocky 8 的软件源里没有或版本太旧，会自动从 PyPI 装到 `/opt/realm/python`，不影响系统自带的 Python，卸载时一起删除。
- **Rocky / AlmaLinux**：依赖从 EPEL 源安装；sudo 不搜索 `/usr/local/bin`，会在 `/usr/bin/realmctl` 放一个链接，普通用户照样用 `sudo realmctl`。firewalld 启用时，添加规则后会提示对应的 `firewall-cmd` 放行命令。
- **Debian 10、11**：已停止维护，软件源搬到了 `archive.debian.org`，使用前需要先改好 `/etc/apt/sources.list`。

## 使用

菜单分两层：主菜单按用途分成四类，选 2 到 4 进入各自的子菜单。子菜单顶部先显示当前状态，做完一步回到这个子菜单，选 0 返回主菜单。主菜单底部会按当前状态提示下一步，比如还没部署、还没有规则、服务没运行，或配置改了还没生效。

```
 1. 部署 Realm            3. 服务管理
 2. 转发规则管理          4. 更新与卸载
```

1. **部署 Realm**：首次安装 Realm 程序和 systemd 服务；已经部署过会提示改用「更新 Realm」。
2. **转发规则管理**：顶部列出每条规则的实际状态——监听中、端口被哪个程序占用、改了配置等重启生效。进程在运行不代表每条转发都生效，这一栏能直接看出哪条有问题。下面是添加、修改、删除转发规则。
3. **服务管理**：顶部显示服务是否运行、版本、开机自启、已运行多久和转发协议；下面是启动并开启自启、停止并关闭自启、重启服务、查看服务日志。
4. **更新与卸载**：更新 Realm、更新管理脚本、卸载 Realm。

`bash realm.sh status` 把服务状态和规则状态打印成一页总览。

添加规则时每一步当场检查：本机端口被其他程序占用、和已有规则冲突、目标地址写错，都会提示并重新输入；直接回车返回菜单。修改规则时选好序号，逐项输入新的监听端口和远程目标，直接回车表示不改；只改地址，传输参数等其他设置保留，改完只需重启一次。删除时可以一次选多条（如 `1,3` 或 `1-3`），确认前会列出要删的规则。

初次使用会检查依赖，只安装缺少的 `curl`、`ca-certificates`、`python3-tomlkit`、`util-linux`。主要面向 Debian 13，Ubuntu 和 Rocky/Alma 也能用（dnf 系统会先启用 EPEL 以安装 `python3-tomlkit`）；缺少依赖时停止，不会错误报告安装成功。macOS、没有运行 systemd 的容器或非 root 环境不会执行部署。

## 命令行

```bash
# 查看规则
bash realm.sh list

# 添加规则，并立即应用；应用失败会恢复配置
bash realm.sh add 0.0.0.0:23457 example.com:443 --apply

# IPv6 地址必须加方括号
bash realm.sh add '[::1]:23458' '[2001:db8::1]:443'

# 修改第 2 条规则的监听和目标，并立即应用
bash realm.sh modify 2 0.0.0.0:23460 example.com:8443 --apply

# 删除指定编号、范围或多条
bash realm.sh delete 2 --apply
bash realm.sh delete 1-3
bash realm.sh delete 1,3

bash realm.sh install
bash realm.sh update
bash realm.sh start
bash realm.sh stop
bash realm.sh restart
bash realm.sh status
```

不带 `--apply` 时只保存配置，服务仍继续使用原配置。带 `--apply` 时：服务在运行就重启；没运行就启动并设为开机自启；规则删光了就停止服务（Realm 没有规则无法运行）。重启会让正在转发的连接断开一下。

启动、重启后不只看进程在不在：Realm 在某个端口绑定失败时进程仍会继续运行，所以脚本会逐个确认配置里的端口真的在监听，并指出被哪个程序占用。带 `--apply` 的增删如果没通过这项检查，会恢复操作前的配置和运行状态。

本工具不自动修改 UFW；新增监听端口后，需要在防火墙及服务商安全组中放行。菜单添加默认监听 `0.0.0.0`，可通过命令行指定具体 IP 或 IPv6。

## 更新

- **更新管理脚本**（「更新与卸载」里）：下载 `main` 分支的最新提交，推送后一分钟内就能更新到；`realmctl` 等已安装的副本一起更新，更新完自动打开新版本。
- **更新 Realm**（「更新与卸载」里）：先和 Realm 官方最新发布比较版本，已经是最新版就不做任何改动；有新版本时，如果服务正在运行会先确认，因为更新要重启 Realm，正在转发的连接会断开一下。现有配置和规则保留。主菜单的「部署 Realm」只用于首次部署，已部署过会提示改用「更新 Realm」。
- 也可以重新执行上面的一键安装命令，同样按最新提交下载。

## 配置与安装保护

- 使用 TOML Kit 解析、展示和修改规则，保留无关配置及注释。日志、DNS 表不会被误删，传输参数不会覆盖列表显示的地址。
- 添加时检查端口范围、地址格式和重复/通配监听冲突。对复杂的同端口协议拆分配置采取保守拒绝策略，不自行修改。
- 首次部署才创建默认配置；重新部署和更新保留已有配置及服务文件。
- 从 Realm 官方 GitHub release 的资产列表选择安装包，保留 HTTPS 证书校验；发布提供 SHA256 时验证摘要。
- 下载到临时目录，仅提取安装包中的普通 `realm` 文件，验证新程序能运行且版本匹配后原子替换。
- 更新前正在运行的服务会重启并检查状态；失败时恢复旧文件并尝试恢复服务。原来未运行的服务不会因更新而自动启动。
- 自更新使用当前脚本的绝对路径，下载和语法检查成功后再替换，不受工作目录切换影响。
- 「卸载 Realm」为完整卸载，确认后停止并禁用服务，删除 Realm 程序、服务文件、当前配置、脚本生成的全部备份，以及管理脚本本身和 `/usr/local/bin/realmctl`。成功后退出菜单；转发规则不会保留。
- 只移除空目录，保留目录内其他文件；不删除系统共享日志、依赖包或 UFW 放行规则。服务停止或文件删除失败时会尝试恢复，卸载成功后不保留恢复备份。

## 备份策略

备份在 `/var/backups/realm/`，仅 root 可访问。完整卸载会删除这些备份。

**每次操作成功后，只保留最近一次操作前的备份。** 失败操作不会清理先前备份；下一次操作成功时再统一清理。这里只处理本脚本生成、带完整清单的备份，不修改 Git 历史。

备份中有 `manifest.json`，记录原文件路径及对应的编号文件。备份可能包含私有转发目标或凭据，不要提交到 GitHub。目录 0/1 等编号由该次操作的清单解释，不要直接把整个备份目录复制到配置目录。

自动恢复是尽力而为：断电、进程被强制终止或磁盘故障无法保证自动回退。服务检查用于确认进程持续运行，不等于实际端到端转发测试。
