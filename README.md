# Jack SS 轻量版

`shadowsocks-libev` + `s-s` 中文菜单，支持 NAT 小鸡。

- C 内核，单个服务进程，默认仅 TCP，可选 TCP + UDP。
- 不安装 Python、Docker、二维码工具，不下载或解压 sing-box。
- Debian 13 amd64 实测：`ss-server` 文件约 147 KB；本地低负载 TCP / UDP 测试中进程 RSS 约 **2.3 MB**。这是单进程测量，系统、连接数和吞吐量会影响总占用。
- 使用系统软件源安装内核与共享库；包索引、依赖和系统本身也需要空间。不能保证所有商家标称的“最小套餐”都满足条件。

## 一键安装

root 登录后复制整行：

```sh
sh -c 'set -e; if ! command -v bash >/dev/null || ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update && apt-get install -y --no-install-recommends bash curl ca-certificates; elif command -v apk >/dev/null; then apk add --no-cache bash curl ca-certificates; elif command -v dnf >/dev/null; then dnf install -y bash curl ca-certificates; elif command -v yum >/dev/null; then yum install -y bash curl ca-certificates; else exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fLSs --retry 2 "https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=2.0.3" -o "$f"; bash "$f"'
```

看到 **2.0.3** 后，选择 **1. 安装 / 迁移**。

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
| 8 / 9 | 查看日志 / 更新内核 |
| 10 | 修改公网地址 |
| 11 | 彻底卸载 |
| 12 | TCP / UDP 设置 |

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
f=$(mktemp); curl -fLSs 'https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?v=2.0.3' -o "$f" && bash "$f" --uninstall; rm -f "$f"; hash -r
```

## 已验证

Bash 语法、密码转义与分享链接、公网/本机端口分离、TCP / UDP 实际转发、修改失败回滚。systemd / OpenRC / SysV 的开机启动仍需在目标 VPS 上验证。

参考：[Debian 官方软件包](https://packages.debian.org/trixie/shadowsocks-libev) · [ss-server 手册](https://manpages.debian.org/trixie/shadowsocks-libev/ss-server.1.en.html)
