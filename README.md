# Jack SS 中文管理菜单

基于官方 sing-box 的独立 Shadowsocks 服务。默认端口 **8388**，加密 **chacha20-ietf-poly1305**，支持 **TCP + UDP**，流量直接从本机出口发出。适合作为自己的节点或客户端链式代理的入口。

## 一条命令安装

使用 **root** 登录服务器，复制整行执行：

```bash
bash -c 'set -e; if ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then apt-get update && apt-get install -y curl ca-certificates; elif command -v dnf >/dev/null; then dnf install -y curl ca-certificates; elif command -v yum >/dev/null; then yum install -y curl ca-certificates; else echo "不支持的系统"; exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fLSs --retry 2 https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh -o "$f"; bash "$f"'
```

选择 **1. 安装 SS 节点**，填写端口和公网 IP / 域名。完成后会显示密码与 `ss://` 分享链接，导入小火箭等客户端即可。

以后登录服务器，输入：

```bash
s-s
```

本地运行源码也可以：`sudo bash ss.sh`。

旧版本用户重新执行上面的一键命令，即可把菜单快捷命令更新为 `s-s`，保留原节点配置和密码。脚本只清理本项目创建的旧 `ss` 菜单文件。

## 中文菜单

| 编号 | 功能 |
| --- | --- |
| 1 | 安装 SS 节点，自动安装缺失依赖 |
| 2 | 查看节点参数与分享链接 |
| 3 | 修改端口 |
| 4 | 修改密码，留空自动生成 |
| 5 / 6 / 7 | 启动 / 停止 / 重启 |
| 8 | 查看最近 60 条日志 |
| 9 | 更新官方稳定版内核 |
| 10 | 修改分享链接的公网 IP / 域名 |
| 11 | 卸载本菜单创建的服务、资料、内核和菜单 |
| 0 | 退出 |

## 环境和行为

- 支持使用 systemd 的 Debian / Ubuntu / CentOS / Rocky / AlmaLinux，架构为 amd64 或 arm64。过旧系统可能无法运行最新内核；尚未逐个发行版实机验证。
- 自动下载 SagerNet/sing-box 官方最新稳定版，并核对 GitHub 发布资产的 SHA256；没有校验值时停止。
- 本项目使用 `/etc/jack-ss/`、`/opt/jack-ss/` 和 `jack-ss.service`；不接管 `/etc/sing-box/`，不卸载系统已有 sing-box，不修改哪吒、SSH 或其他服务。
- 如果旧节点占用 8388，选择其他空闲端口即可；旧节点仍由旧服务管理。
- 安装为开机自启；配置和密码仅 root 可读。节点资料位于 `/etc/jack-ss/node.txt`。
- 修改配置前执行 `sing-box check`；服务立即启动失败时恢复旧配置。升级也保留内核以便回退。
- 不关闭或清空防火墙。对正在运行的 UFW / firewalld 添加端口规则，并记录新增规则供卸载清理；其他防火墙需自行放行。
- **阿里云等云服务器必须另在控制台安全组放行节点端口的 TCP 和 UDP。** 公网 IP 自动检测失败时手动填写公网地址，不能填写阿里云内网地址。
- IPv6 被系统完全禁用时，`::` 监听可能不可用，应先检查系统网络设置。
- 菜单快捷命令为 `s-s`，系统原有的 `ss -ntlp` 等网络诊断命令照常使用。
- 卸载输入 `YES` 确认后执行；云安全组规则仍需在云控制台删除。

## 检查

```bash
bash -n ss.sh
bash ss.sh --version
bash ss.sh --help
```

已使用官方 sing-box 进行配置检查，并检查分享链接、文件权限及快捷命令迁移。本地 SOCKS → Shadowsocks → HTTP 测试因执行环境禁止创建 netlink socket 而无法启动；**实际网络连通性、systemd 服务和各发行版防火墙尚需在目标服务器核验**。

官方资料：[Shadowsocks 入站](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/) · [sing-box Releases](https://github.com/SagerNet/sing-box/releases)
