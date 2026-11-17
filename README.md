# Jack SS 多节点版 3.2.0

`shadowsocks-libev` + `s-s` 中文菜单。一台服务器可以新建多个 SS 节点，各自使用独立端口、密码、TCP/UDP 设置和 IP 上限。

## 已安装 2.1.1：直接从菜单升级

运行 `s-s`，选择 **9 → 1（更新菜单）**，显示 **3.2.0** 即升级完成。

原有节点自动出现在节点列表中，名称显示为“原有节点”。原配置、端口、密码和正在运行的服务保留，无需重新创建或移动。升级菜单本身不重启节点。旧节点已经启用的 IP 上限也会保留，后续按选中节点独立管理。

## 一键安装 / 更早版本升级

root 登录后复制整行：

```sh
sh -c 'set -e; if ! command -v bash >/dev/null || ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update && apt-get install -y --no-install-recommends bash curl ca-certificates; elif command -v apk >/dev/null; then apk add --no-cache bash curl ca-certificates; elif command -v dnf >/dev/null; then dnf install -y bash curl ca-certificates; elif command -v yum >/dev/null; then yum install -y bash curl ca-certificates; else exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fLSs --retry 2 "https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=3.2.0" -o "$f"; bash "$f"'
```

首次使用选择 **1. 新建节点 / 旧版迁移**。以后输入 `s-s` 即可打开菜单。2.0.3 及更早版本的旧“9”不能更新菜单，需要先执行上面的命令一次。

## 怎么用

主菜单只保留新建节点、节点列表、更新与卸载入口。每次选择节点后，在该节点的管理页操作，顶部显示节点名称、地址、运行状态、协议和 IP 上限。

1. **1. 新建节点**：填写名称、端口、公网地址、TCP/UDP 和密码；密码留空自动生成。需要更多节点时重复新建。
2. **2. 节点列表**：选择一个节点，进入它的管理页。
3. 在该节点管理页选择 **3. IP 限制 → 1. 设置上限**。例如节点一设 2、节点二设 5，分别计数；输入 0 关闭当前节点的限制。

列表只显示名称、端口、状态和上限。密码及分享链接在节点管理页的“查看节点 / 分享链接”里显示。每层菜单都可按 0 返回。

## 菜单

| 页面 | 编号 | 功能 |
| --- | --- | --- |
| 主菜单 | 1 | 新建节点 |
| 主菜单 | 2 | 节点列表，选中后进入节点管理 |
| 主菜单 | 8 | 卸载全部节点及本项目，需要输入 YES |
| 主菜单 | 9 | 更新：1 更新菜单、2 更新共享 SS 内核 |
| 节点管理 | 1 | 查看节点参数与分享链接 |
| 节点管理 | 2 | 编辑名称、端口、密码、公网地址、TCP/UDP |
| 节点管理 | 3 | 当前节点 IP 上限、当前 IP、清空记录、关闭限制 |
| 节点管理 | 4 / 5 / 6 | 启动 / 停止 / 重启当前节点 |
| 节点管理 | 7 | 当前节点日志 |
| 节点管理 | 8 | 仅删除当前节点，需要输入 YES |

修改或删除一个节点不更改其他节点的配置。端口不可重复。可建数量受端口、内存及系统资源约束。

## 3.2.0 修复限制服务启动失败

旧版可能出现 `Failed to bind family 2. Are you root?`，这是 NFQUEUE 初始化失败，输入的 IP 数量不是原因。3.2.0 改成独立 TCP/UDP 转发入口，不再使用 NFQUEUE、nftables、NET_ADMIN 或 python-netfilterqueue。只需要系统 Python 3 标准库和 systemd。

已出现这个错误的用户：先 **9 → 1** 更新菜单，再进入 **节点列表 → 选择节点 → IP 限制 → 设置上限** 重新设置一次。已正常运行旧限制的节点也可重新设置一次上限切换到新实现。

## 每个节点独立限制 IP

- 每个节点拥有独立上限、接入顺序、等待重连记录和限制服务，互不影响。同一 IP 访问两个节点时分别计数。
- 上限为 2，A 先接入、B 后接入，C 接入时关闭 B 的全部 TCP 连接和 UDP 转发，保留 A 和 C。D 再接入时替换 C。已有 IP 新建连接不改变顺序。
- 被替换 IP 等待 60 秒后才能作为新 IP 重连，防止自动重连反复互踢。5 分钟双向无流量释放名额。
- TCP / UDP 在同一节点内共用上限。IPv4 / IPv6 一起计数，同一设备的不同公网地址分别计数；IPv4 映射 IPv6 地址归一为原 IPv4，不重复计数。
- **按来源 IP 计数，不在转发入口验证 SS 密码。** SS 密码仍由原内核验证。错误密码或端口扫描连接也可能占名额、触发替换。
- 启用限制后，转发入口继续监听原节点端口；SS 内核改为仅监听本机回环地址的内部端口。原公网地址、节点端口、密码及分享链接保留。限制服务停止后不能绕过它直接访问内部 SS 服务。
- 转发的是原始加密 TCP/UDP 数据，不解密、不记录转发内容。启用限制的流量经过额外本机转发，相比纯 SS 内核会增加 CPU 和内存开销；不开启限制时仍直接使用原 SS 内核。
- 启用、修改或关闭限制会重启所选节点，已有连接可能短暂中断。关闭限制后恢复原端口直接监听。开启后上限一直保存，启动失败或进程退出时每 3 秒持续重试，不自动改为不限。故障期间不恢复公开的无限制监听；只有手动关闭、输入 0 或卸载才取消限制。空闲释放在线 IP 名额也不会关闭功能。只处理本项目旧防火墙表，不清空整机防火墙。

## 系统与资源

- 节点优先支持 Debian / Ubuntu；Alpine 使用 APK，CentOS / Rocky / AlmaLinux 需软件源提供 shadowsocks-libev，不添加额外软件源或编译内核。
- 普通节点支持 systemd、OpenRC、Debian SysV。IP 限制目前使用 systemd，需系统 Python 3（当前实际验证 Debian 13 / Python 3.13）。未安装 Python 时 Debian / Ubuntu 自动安装。
- 每个普通节点一个 C 内核进程；每个开启 IP 限制的节点另有一个 Python 转发进程。不开启限制时不运行转发进程，不安装额外的队列或防火墙依赖。
- 软件包共用；删除一个节点不卸载共享内核。全部卸载只清理安装记录中本项目新增且可安全删除的包，保留其他软件正在依赖的包。
- 在线更新验证脚本标识、Bash 语法和版本号。下载失败或远端版本更低时保留本机菜单。更新共享内核会重启正在运行的本项目节点；更新菜单本身不重启节点。

## 数据与服务

- 原有节点继续保存在 `/etc/jack-ss/`，服务名仍为 `jack-ss`，不自动改动原密码或端口。
- 新节点分别保存在 `/etc/jack-ss/nodes/编号/`，服务为 `jack-ss-node-编号`。节点目录和凭据仅 root 可读。
- 安装包归属记录位于 `/etc/jack-ss/`，不随单节点删除而移除。节点资料各自保存在其目录的 `node.txt`。
- 命令行指定新节点：`s-s --node 1 --start` / `--stop` / `--restart`。原有节点使用 `s-s --node legacy --start`。
- NAT 环境仍需商家预先映射 / 放行对应端口；节点限制使用本机监听端口作为隔离范围。

## 验证

26 项测试通过，包含以下实际网络测试，全部仅使用回环地址，不需要 NET_ADMIN 或 NFQUEUE：

- 三个实际来源 IP 接入：第三个断开第二个的 TCP 连接，保留第一个；第二个自动重连被拦截。
- UDP 新来源与 TCP 共用上限，并能替换已有 TCP 来源；60 KB UDP 数据及 256 KB TCP 数据正常往返。
- 同一来源 IP 访问两个受限节点时分别计数，停止一个节点不影响另一个。
- IPv4 / IPv6 双栈转发、实际 shadowsocks-libev 双节点加密 TCP / UDP 转发。
- 独立密码 / 模式 / 服务、端口冲突、单节点删除、原节点保留、关闭限制恢复公开监听、启动失败保留限制及内部监听、服务持续重试策略和在线更新校验。

生成的 systemd 服务已通过静态检查。实际 VPS 的开机恢复仍需在目标机器验证；本地已完成真实 IP 替换及转发测试。

```sh
python3 -m unittest -v test_ip_guard.py test_update.py test_multinode.py test_relay_live.py
# 如已安装原 SS 内核：
SS_CORE_BIN_DIR=/usr/bin python3 -m unittest -v test_native.py
```

参考：[Debian 软件包](https://packages.debian.org/trixie/shadowsocks-libev) · [ss-server 手册](https://manpages.debian.org/trixie/shadowsocks-libev/ss-server.1.en.html)
