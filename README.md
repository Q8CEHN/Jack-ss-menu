# Jack SS 轻量版

`shadowsocks-libev` + `s-s` 中文菜单，支持 NAT 小鸡。

- C 内核，单个服务进程，默认仅 TCP，可选 TCP + UDP。
- 默认不安装 Python、Docker、二维码工具，不下载或解压 sing-box。启用 IP 限制时会安装额外依赖。
- Debian 13 amd64 实测：`ss-server` 文件约 147 KB；本地低负载 TCP / UDP 测试中进程 RSS 约 **2.3 MB**。这是单进程测量，系统、连接数和吞吐量会影响总占用。
- 使用系统软件源安装内核与共享库；包索引、依赖和系统本身也需要空间。不能保证所有商家标称的“最小套餐”都满足条件。

## 一键安装

root 登录后复制整行：

```sh
sh -c 'set -e; if ! command -v bash >/dev/null || ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update && apt-get install -y --no-install-recommends bash curl ca-certificates; elif command -v apk >/dev/null; then apk add --no-cache bash curl ca-certificates; elif command -v dnf >/dev/null; then dnf install -y bash curl ca-certificates; elif command -v yum >/dev/null; then yum install -y bash curl ca-certificates; else exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fLSs --retry 2 "https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=2.1.1" -o "$f"; bash "$f"'
```

看到 **2.1.1** 后，选择 **1. 安装 / 迁移**。

以后打开菜单：

```bash
s-s
```

## 安装填写

端口只输入一次，同时用于服务监听和节点链接。默认 `8388`，可自行修改。

接着填写公网 IP / 域名，并选择是否启用 UDP。

## 菜单

| 编号 | 功能 |
| --- | --- |
| 1 | 安装 / 从旧版 sing-box 迁移 |
| 2 | 查看参数与分享链接 |
| 3 / 4 | 修改端口 / 密码 |
| 5 / 6 / 7 | 启动 / 停止 / 重启 |
| 8 / 9 | 查看日志 / 更新菜单或内核 |
| 10 | 修改公网地址 |
| 11 | 彻底卸载 |
| 12 | TCP / UDP 设置 |
| 13 | IP 数量限制：设置上限、查看 IP、清空顺序、关闭 |

## 在线更新菜单（2.1.1）

新版菜单选择 **9 → 1**，在线更新菜单获得新功能，不用上传文件，不修改节点地址、端口和密码，也不重启节点。选择 **9 → 2** 更新 SS 内核。下载失败、脚本无效或远端版本更低时保留原菜单。

旧版 2.0.3 的 9 只有更新内核功能，无法自行获取新版菜单；首次仍需重新执行上面的在线安装命令更新脚本，随后即可从菜单更新。在线更新需要新版代码已经发布到仓库。

## IP 数量限制（2.1.0）

运行 `s-s` → **13. IP 数量限制** → **1. 设置 / 修改上限**，输入人数上限，输入 `0` 关闭。默认关闭，不更改原节点密码或地址。已安装用户重新执行上面的一键命令即可更新菜单。

采用你指定的替换顺序：上限为 2 时，A 先接入、B 后接入，C 接入后替换 B，保留 A 和 C；D 再接入时替换 C。已有 IP 新建连接不会改变首次接入顺序。

- TCP 和 UDP 共用一个 IP 上限，IPv4 / IPv6 合并计算，但同一设备的 IPv4 和 IPv6 算两个来源。服务器只能看到 NAT 后的公网 IP，同公网 IP 的多台设备只计一个。
- 被替换的 IP 在 60 秒内不能重新接入，防止自动重连反复互踢；60 秒后它作为新 IP 重试时，仍可替换当前最后接入者。5 分钟双向无流量释放名额；这不是精确的设备在线检测。
- **按到达本机节点端口的来源流量计数，不是 SS 密码认证后的账号/设备计数。** 扫描或错误密码连接也可能占用名额、触发替换；当前内核不提供认证后的来源事件。
- 使用独立 nftables 表，只限制本节点本机监听端口，保留主机其他防火墙规则。新来源经 NFQUEUE 决定是否接入，已接入来源由内核处理流量。限制服务异常时对新来源保持拦截，重启失败可从菜单关闭限制恢复。
- 当前 IP 限制支持 **Debian / Ubuntu + systemd**，且系统软件源需提供 `python3-netfilterqueue`、`nftables`、`iproute2`。不满足条件时显示错误，不启用限制；主菜单其他功能仍可用。无 NET_ADMIN、缺少 NFQUEUE / nftables 内核支持的容器或 NAT 小机可能无法启用。
- 额外运行一个 Python 控制进程，仅启用时安装依赖、启动服务；不开启时保持原来的轻量节点。开机随节点恢复限制；重启节点、修改限制或清空记录后，接入顺序按新流量重建。菜单能查看当前顺序与等待重连 IP。
- 关闭限制会移除本项目规则与限制服务；彻底卸载还会按安装记录清理本项目新增的软件包，包管理器判断被其他软件依赖的包会保留。

## 支持与升级

- 优先支持 Debian / Ubuntu；Alpine 使用 APK，CentOS / Rocky / AlmaLinux 需要现有软件源提供 `shadowsocks-libev`。不自动添加额外仓库或编译源码。
- 支持 systemd、OpenRC 和 Debian SysV 开机启动。其他初始化环境可用 `s-s --start`，需自行添加启动任务。
- 密码和配置在 `/etc/jack-ss/`，仅 root 可读；资料在 `/etc/jack-ss/node.txt`。
- 原 1.x 用户重新执行安装命令，选择 1 迁移，保留本项目的端口、密码和加密方式；确认新服务运行后删除本项目旧的大内核。失败时恢复旧配置和服务。
- 卸载会删除节点、密码、迁移备份、旧私有内核、服务、自启链接、新旧菜单命令和本项目防火墙规则，同时移除未共享的 shadowsocks-libev 软件包。新安装会记录新增依赖，仅清理其中已无软件依赖的包；旧版使用受限的 libev 依赖名单。已有共享内核、其他节点及其他软件仍在使用的依赖会保留。
- 防火墙自动处理限运行中的 UFW / firewalld，其他规则需自行设置。

## 彻底卸载

菜单选择 **11**，输入 `YES`。旧菜单已被删除时，也可直接下载新版执行卸载：

```bash
f=$(mktemp); curl -fLSs 'https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=2.1.1' -o "$f" && bash "$f" --uninstall; rm -f "$f"; hash -r
```

## 已验证

Bash 语法、密码转义与分享链接、公网/本机端口分离、TCP / UDP 实际转发、修改失败回滚。systemd / OpenRC / SysV 的开机启动仍需在目标 VPS 上验证。2.1.0 的 IP 替换顺序、重连等待、空闲释放、IPv4 / IPv6 合并及失败时保留旧状态已通过自动化模拟测试；当前开发环境无 NET_ADMIN，尚未完成真实内核 TCP / UDP 限流与 systemd 开机恢复测试。

参考：[Debian 官方软件包](https://packages.debian.org/trixie/shadowsocks-libev) · [ss-server 手册](https://manpages.debian.org/trixie/shadowsocks-libev/ss-server.1.en.html)
