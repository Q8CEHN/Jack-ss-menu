# Jack SS 多节点版 3.1.0

`shadowsocks-libev` + `s-s` 中文菜单。一台服务器可以新建多个 SS 节点，各自使用独立端口、密码、TCP/UDP 设置和 IP 上限。

## 已安装 2.1.1：直接从菜单升级

运行 `s-s`，选择 **9 → 1（更新菜单）**，显示 **3.1.0** 即升级完成。

原有节点自动出现在节点列表中，名称显示为“原有节点”。原配置、端口、密码和正在运行的服务保留，无需重新创建或移动。升级菜单本身不重启节点。旧节点已经启用的 IP 上限也会保留，后续按选中节点独立管理。

## 一键安装 / 更早版本升级

root 登录后复制整行：

```sh
sh -c 'set -e; if ! command -v bash >/dev/null || ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update && apt-get install -y --no-install-recommends bash curl ca-certificates; elif command -v apk >/dev/null; then apk add --no-cache bash curl ca-certificates; elif command -v dnf >/dev/null; then dnf install -y bash curl ca-certificates; elif command -v yum >/dev/null; then yum install -y bash curl ca-certificates; else exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fLSs --retry 2 "https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=3.1.0" -o "$f"; bash "$f"'
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

## 每个节点独立限制 IP

- 每个节点拥有独立的上限、接入顺序、等待重连名单、防火墙表、队列和限制服务。关闭或清空 A 的限制不改变 B。
- 按你指定的替换顺序：上限 2，A 先接入、B 后接入，C 接入后替换 B，保留 A 和 C；D 再接入时替换 C。已有 IP 新建连接不改变首次接入顺序。
- 被替换的 IP 在 60 秒内不能重新接入，防止客户端自动重连反复互踢。60 秒后重试会按新 IP 处理，仍可替换该节点当前最后接入者。
- 5 分钟双向无流量释放名额；这是流量活跃判断，不是精确的设备在线检测。重启该节点、修改限制或清空记录后，只重建该节点的接入顺序。
- TCP / UDP 在同一节点内共用上限；IPv4 / IPv6 一起计数，但同一设备的两个地址算两个 IP。同公网 IP 的多台设备只计一个；同一 IP 访问两个节点时，分别进入两个节点的计数。
- **按到达节点端口的来源流量计数，不是密码认证后的设备计数。** 扫描和错误密码连接也可能占名额或触发替换；当前内核不提供认证后的来源事件。
- 新来源通过 NFQUEUE 接入，已准入来源由内核处理。只操作本项目独立 nftables 表，不清空整机规则。限制服务异常时拦截新来源；可从菜单关闭该节点限制恢复。

## 系统与资源

- 节点优先支持 Debian / Ubuntu；Alpine 使用 APK，CentOS / Rocky / AlmaLinux 需要软件源提供 `shadowsocks-libev`。不添加额外软件源或编译内核。
- 节点支持 systemd、OpenRC、Debian SysV 开机启动。每个新节点一个服务进程；默认仅 TCP，可开启 UDP。
- IP 限制支持 **Debian / Ubuntu + systemd**，需软件源提供 `python3-netfilterqueue`、`nftables`、`iproute2`，且内核支持 NFQUEUE / nftables，拥有 NET_ADMIN 权限。部分容器 / NAT 小机可能无法启用。
- 默认关闭 IP 限制，未启用时不安装 Python 等限制组件。每个启用限制的节点额外运行一个 Python 控制进程；开启越多，资源占用越高。
- 软件包全项目共用；删除一个节点不卸载共享内核。全部卸载时只清理本项目新增且可安全删除的包，保留其他软件正在依赖的包。安装防火墙工具时阻止其示例规则服务自动启动。
- 在线更新会验证脚本标识、Bash 语法和版本号；下载失败、无效下载或远端版本更低时保留本机菜单。更新内核属于全项目操作，菜单里与更新脚本分别列出。

## 数据与服务

- 原有节点继续保存在 `/etc/jack-ss/`，服务名仍为 `jack-ss`，不自动改动原密码或端口。
- 新节点分别保存在 `/etc/jack-ss/nodes/编号/`，服务为 `jack-ss-node-编号`。节点目录和凭据仅 root 可读。
- 安装包归属记录位于 `/etc/jack-ss/`，不随单节点删除而移除。节点资料各自保存在其目录的 `node.txt`。
- 命令行指定新节点：`s-s --node 1 --start` / `--stop` / `--restart`。原有节点使用 `s-s --node legacy --start`。
- NAT 环境仍需商家预先映射 / 放行对应端口；节点限制使用本机监听端口作为隔离范围。

## 验证

- 26 项自动化测试通过：多节点创建、独立密码 / 协议 / 服务、独立 IP 限制与替换顺序、单节点修改 / 关闭限制 / 删除时保留其他节点、端口冲突、旧节点原地保留、全部卸载、在线更新失败保留旧版本。
- 两个实际 `shadowsocks-libev` 节点在本地完成 TCP 和 UDP 转发测试，停止其中一个后另一个仍可转发。使用菜单真实配置生成功能，所有流量均在本机回环地址。
- 开发环境没有 NET_ADMIN；真实内核 nftables / NFQUEUE 限流、systemd / OpenRC / SysV 开机恢复仍需在目标 VPS 验证。IP 限制目前通过逻辑及配置隔离模拟验证，不声称已完成实机限流验证。

```sh
python3 -m unittest -v test_ip_guard.py test_update.py test_multinode.py
# 如已安装实际内核，可额外验证本机 TCP/UDP：
SS_CORE_BIN_DIR=/usr/bin python3 -m unittest -v test_native.py
```

参考：[Debian 软件包](https://packages.debian.org/trixie/shadowsocks-libev) · [ss-server 手册](https://manpages.debian.org/trixie/shadowsocks-libev/ss-server.1.en.html) · [nftables 集合与超时](https://wiki.nftables.org/wiki-nftables/index.php/Updating_sets_from_the_packet_path)
