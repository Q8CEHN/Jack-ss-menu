#!/usr/bin/env bash
# JACK_SS_MENU — lightweight Shadowsocks manager.
set -Eeuo pipefail
umask 077
VERSION=2.0.1
ROOT=/etc/jack-ss
MENU=/usr/local/bin/s-s
UNIT=/etc/systemd/system/jack-ss.service
POLICY_OWN=0
cleanup() {
  if (( POLICY_OWN )) && [[ -f /usr/sbin/policy-rc.d ]] && grep -q JACK_SS_PACKAGE_GUARD /usr/sbin/policy-rc.d; then rm -f /usr/sbin/policy-rc.d; fi
}
trap cleanup EXIT
fail() { echo "错误：$*" >&2; exit 1; }
ask() { read -r -p "$1" "$2" </dev/tty; }
is_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; }
root_check() { [[ $EUID -eq 0 ]] || fail '请使用 root 运行。'; }
install_menu() {
  [[ ! -e "$MENU" ]] || grep -q JACK_SS_MENU "$MENU" || fail "$MENU 已被其他程序占用。"
  if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$(readlink -f "$MENU")" ]]; then install -m 755 "${BASH_SOURCE[0]}" "$MENU"; fi
  if [[ -f /usr/local/bin/ss ]] && grep -q JACK_SS_MENU /usr/local/bin/ss; then rm -f /usr/local/bin/ss; fi
}
check_space() {
  local available
  available=$(df -Pk /usr | awk 'NR==2 {print $4}')
  [[ "$available" =~ ^[0-9]+$ ]] || return 0
  (( available >= 4096 )) || fail '/usr 可用空间不足 4 MB，请先释放空间。'
}
install_core() {
  if command -v ss-server >/dev/null; then return; fi
  check_space
  if command -v apt-get >/dev/null; then
    # Prevent a newly installed package from starting its example server.
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
      cat >/usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
# JACK_SS_PACKAGE_GUARD
case "$1" in shadowsocks-libev*) exit 101;; *) exit 0;; esac
POLICY
      chmod 755 /usr/sbin/policy-rc.d; POLICY_OWN=1
    fi
    if ! apt-cache show shadowsocks-libev >/dev/null 2>&1; then
      apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -o APT::Keep-Downloaded-Packages=false install -y --no-install-recommends shadowsocks-libev
    cleanup; POLICY_OWN=0
    if is_systemd; then systemctl disable --now shadowsocks-libev.service >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null; then update-rc.d shadowsocks-libev disable >/dev/null 2>&1 || true; fi
  elif command -v apk >/dev/null; then
    apk add --no-cache shadowsocks-libev
  elif command -v dnf >/dev/null; then
    dnf install -y --setopt=install_weak_deps=False shadowsocks-libev || fail '软件源未提供 shadowsocks-libev，建议使用 Debian / Ubuntu。'
  elif command -v yum >/dev/null; then
    yum install -y shadowsocks-libev || fail '软件源未提供 shadowsocks-libev，建议使用 Debian / Ubuntu。'
  else fail '未找到支持的软件包管理器。'; fi
  command -v ss-server >/dev/null || fail '未安装成功。'
}
load_state() {
  [[ -f "$ROOT/settings" ]] || fail '请先选择 1 安装。'
  # This is a root-only file written with Bash printf %q, never downloaded.
  source "$ROOT/settings"
}
write_state() {
  local key
  for key in HOST LOCAL_PORT PUBLIC_PORT PASSWORD MODE METHOD; do printf '%s=%q\n' "$key" "${!key}"; done >"$ROOT/settings.new"
  mv -f "$ROOT/settings.new" "$ROOT/settings"
}
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}
write_config() {
  local bind_address=0.0.0.0
  [[ "$HOST" != *:* ]] || bind_address=::
  cat >"$ROOT/config.json.new" <<JSON
{
  "server": "$bind_address",
  "server_port": $LOCAL_PORT,
  "password": "$(json_escape "$PASSWORD")",
  "method": "$METHOD",
  "timeout": 60,
  "mode": "$MODE",
  "fast_open": false
}
JSON
  mv -f "$ROOT/config.json.new" "$ROOT/config.json"
}
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 > 0 && 10#$1 <= 65535 )); }
read_port() {
  local value
  ask "$1 [$2]：" value; value=${value:-$2}
  valid_port "$value" || fail '端口范围为 1–65535。'
  printf -v "$3" '%s' "$((10#$value))"
}
valid_host() { [[ -n "$1" && ${#1} -le 253 && "$1" != *[^a-zA-Z0-9.:-]* ]]; }
read_address() {
  local guess=${HOST:-}
  if [[ -z "$guess" ]] && command -v curl >/dev/null; then guess=$(curl -4fsS --connect-timeout 2 --max-time 4 https://api.ipify.org || true); fi
  ask "公网 IP / 域名 [$guess]：" HOST
  HOST=${HOST:-$guess}; valid_host "$HOST" || fail '公网地址格式无效。'
}
read_mode() {
  local answer
  ask '启用 UDP？[y/N]：' answer
  case "$answer" in y|Y) MODE=tcp_and_udp;; *) MODE=tcp_only;; esac
}
random_password() { PASSWORD=$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n'); }
process_running() {
  [[ -r "$ROOT/ss.pid" ]] || return 1
  read -r pid <"$ROOT/ss.pid"
  [[ "$pid" =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
  [[ $(readlink "/proc/$pid/exe") == */ss-server ]] || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" | grep -Fxq "$ROOT/config.json"
}
start_service() {
  if is_systemd; then systemctl start jack-ss; else
    process_running && return 0
    ss-server -c "$ROOT/config.json" -f "$ROOT/ss.pid" >/dev/null 2>&1
  fi
}
stop_service() {
  if is_systemd; then systemctl stop jack-ss; else
    if process_running; then
      kill "$pid"
      local count
      for count in {1..10}; do process_running || break; sleep 0.2; done
      process_running && return 1
    fi
    rm -f "$ROOT/ss.pid"
  fi
}
healthy() { if is_systemd; then systemctl is-active --quiet jack-ss; else process_running; fi; }
restart_service() { stop_service && start_service; }
register_service() {
  local core
  core=$(command -v ss-server)
  if is_systemd; then
    cat >"$UNIT" <<UNIT
[Unit]
Description=Jack SS
After=network.target
[Service]
ExecStart=$core -c /etc/jack-ss/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1024
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable jack-ss >/dev/null
  elif command -v rc-update >/dev/null && [[ -x /sbin/openrc-run ]]; then
    cat >/etc/init.d/jack-ss <<INIT
#!/sbin/openrc-run
# JACK_SS_MENU
name="Jack SS"
command="$core"
command_args="-c /etc/jack-ss/config.json"
command_background=true
pidfile="/etc/jack-ss/ss.pid"
depend() { need net; }
INIT
    chmod 755 /etc/init.d/jack-ss; rc-update add jack-ss default
  elif command -v update-rc.d >/dev/null; then
    cat >/etc/init.d/jack-ss <<'INIT'
#!/bin/sh
# JACK_SS_MENU
### BEGIN INIT INFO
# Provides: jack-ss
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Jack SS
### END INIT INFO
case "$1" in
start) exec /usr/local/bin/s-s --start;;
stop) exec /usr/local/bin/s-s --stop;;
restart) exec /usr/local/bin/s-s --restart;;
*) exit 1;;
esac
INIT
    chmod 755 /etc/init.d/jack-ss; update-rc.d jack-ss defaults
  else echo '未配置开机启动，请在系统启动任务中添加 s-s --start。'; fi
}
node_info() {
  load_state
  local address=$HOST token protocol=TCP
  [[ "$MODE" != tcp_and_udp ]] || protocol='TCP + UDP'
  [[ "$address" != *:* ]] || address="[$address]"
  token=$(printf '%s:%s' "$METHOD" "$PASSWORD" | base64 | tr '/+' '_-' | tr -d '=\n')
  {
    printf '公网：%s:%s\n本机端口：%s\n协议：%s\n加密：%s\n密码：%s\n\n' "$HOST" "$PUBLIC_PORT" "$LOCAL_PORT" "$protocol" "$METHOD" "$PASSWORD"
    printf 'ss://%s@%s:%s#Jack-SS\n' "$token" "$address" "$PUBLIC_PORT"
  } | tee "$ROOT/node.txt"
}
firewall_add() {
  local proto
  local protocols=(tcp)
  [[ "$MODE" != tcp_and_udp ]] || protocols+=(udp)
  for proto in "${protocols[@]}"; do
    if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
      if ! ufw show added | grep -Eq "^ufw allow $LOCAL_PORT/$proto([[:space:]]|$)"; then
        ufw allow "$LOCAL_PORT/$proto" comment jack-ss
        printf 'ufw %s %s\n' "$LOCAL_PORT" "$proto" >>"$ROOT/firewall"
      fi
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
      if ! firewall-cmd --permanent --query-port="$LOCAL_PORT/$proto" >/dev/null; then
        firewall-cmd --permanent --add-port="$LOCAL_PORT/$proto"
        printf 'firewalld-permanent %s %s\n' "$LOCAL_PORT" "$proto" >>"$ROOT/firewall"
      fi
      if ! firewall-cmd --query-port="$LOCAL_PORT/$proto" >/dev/null; then
        firewall-cmd --add-port="$LOCAL_PORT/$proto"
        printf 'firewalld-runtime %s %s\n' "$LOCAL_PORT" "$proto" >>"$ROOT/firewall"
      fi
    fi
  done
}
firewall_remove() {
  [[ -f "$ROOT/firewall" ]] || return 0
  local backend port proto
  while read -r backend port proto; do
    case "$backend" in
      ufw) ufw --force delete allow "$port/$proto" || true;;
      firewalld-permanent) firewall-cmd --permanent --remove-port="$port/$proto" || true;;
      firewalld-runtime) firewall-cmd --remove-port="$port/$proto" || true;;
    esac
  done <"$ROOT/firewall"
  : >"$ROOT/firewall"
}
legacy_import() {
  command -v python3 >/dev/null || fail '旧版配置迁移需要旧版安装时的 python3。'
  install -d -m 700 "$ROOT/migration-backup"
  cp -p "$ROOT/config.json" "$ROOT/migration-backup/config.json"
  [[ ! -f "$UNIT" ]] || cp -p "$UNIT" "$ROOT/migration-backup/jack-ss.service"
  python3 - "$ROOT" >"$ROOT/legacy-values" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); c=json.loads((p/'config.json').read_text())
assert len(c['inbounds'])==1 and c['inbounds'][0]['type']=='shadowsocks'
i=c['inbounds'][0]; assert i['method'] in ('chacha20-ietf-poly1305','aes-128-gcm','aes-256-gcm')
print(i['listen_port']); print(i['method']); print(base64.b64encode(i['password'].encode()).decode()); print((p/'host').read_text().strip())
PY
  local encoded
  { read -r LOCAL_PORT; read -r METHOD; read -r encoded; read -r HOST; } <"$ROOT/legacy-values"
  PASSWORD=$(printf '%s' "$encoded" | base64 -d)
  PUBLIC_PORT=$LOCAL_PORT; MODE=tcp_and_udp
  rm -f "$ROOT/legacy-values"
}
install_node() {
  if [[ -f "$ROOT/settings" ]]; then node_info; return; fi
  install_core; install -d -m 700 "$ROOT"
  local migrating=0
  if [[ -f "$ROOT/config.json" ]]; then
    grep -q '"inbounds"' "$ROOT/config.json" || fail '发现未知配置，停止覆盖。'
    legacy_import; migrating=1
    read_address; read_port '公网映射端口' "$PUBLIC_PORT" PUBLIC_PORT
    is_systemd || fail '旧版迁移需要在原 systemd 环境执行。'
    systemctl stop jack-ss
  else
    read_port '本机监听端口' 8388 LOCAL_PORT
    read_address; read_port '公网映射端口' "$LOCAL_PORT" PUBLIC_PORT
    read_mode; METHOD=chacha20-ietf-poly1305; random_password
  fi
  write_config; write_state; register_service
  if ! start_service; then echo '服务启动失败。'; fi
  sleep 1
  if ! healthy; then
    if (( migrating )); then
      stop_service || true
      cp -p "$ROOT/migration-backup/config.json" "$ROOT/config.json"
      cp -p "$ROOT/migration-backup/jack-ss.service" "$UNIT"
      rm -f "$ROOT/settings"
      systemctl daemon-reload; systemctl restart jack-ss || true
      fail '迁移失败，已恢复旧版。'
    fi
    fail '启动失败，选择 8 查看日志。'
  fi
  if (( migrating )); then rm -f /opt/jack-ss/sing-box /opt/jack-ss/sing-box.previous /opt/jack-ss/sing-box.new; rmdir /opt/jack-ss 2>/dev/null || true; fi
  firewall_add
  echo '安装完成'; node_info
}
change_settings() {
  load_state
  case "$1" in
    ports) read_port '本机监听端口' "$LOCAL_PORT" LOCAL_PORT; read_port '公网映射端口' "$PUBLIC_PORT" PUBLIC_PORT;;
    password) ask '新密码（留空随机）：' PASSWORD; [[ -n "$PASSWORD" ]] || random_password;;
    address) read_address;; mode) read_mode;;
  esac
  cp -p "$ROOT/settings" "$ROOT/settings.previous"
  cp -p "$ROOT/config.json" "$ROOT/config.json.previous"
  write_config; write_state
  if ! restart_service; then echo '重启失败。'; fi
  sleep 1
  if ! healthy; then
    mv -f "$ROOT/settings.previous" "$ROOT/settings"; mv -f "$ROOT/config.json.previous" "$ROOT/config.json"
    restart_service || true; fail '修改失败，已恢复旧配置。'
  fi
  rm -f "$ROOT/settings.previous" "$ROOT/config.json.previous"
  firewall_remove; firewall_add
  node_info
}
show_logs() {
  if is_systemd; then journalctl -u jack-ss -n 30 --no-pager
  elif command -v logread >/dev/null; then logread | tail -40
  else echo '当前系统没有日志服务。'; fi
}
update_core() {
  load_state
  if command -v apt-get >/dev/null; then
    apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --only-upgrade shadowsocks-libev
  elif command -v apk >/dev/null; then apk upgrade --no-cache shadowsocks-libev
  elif command -v dnf >/dev/null; then dnf upgrade -y shadowsocks-libev
  elif command -v yum >/dev/null; then yum update -y shadowsocks-libev; fi
  restart_service; sleep 1; healthy || fail '更新后启动失败。'
  echo '更新完成'
}
uninstall_node() {
  local answer
  ask '卸载节点和菜单？输入 YES：' answer
  [[ "$answer" == YES ]] || return 0
  stop_service || true; firewall_remove
  if is_systemd; then systemctl disable jack-ss >/dev/null 2>&1 || true; rm -f "$UNIT"; systemctl daemon-reload; fi
  if [[ -f /etc/init.d/jack-ss ]] && grep -q JACK_SS_MENU /etc/init.d/jack-ss; then
    if command -v rc-update >/dev/null; then rc-update del jack-ss default || true
    elif command -v update-rc.d >/dev/null; then update-rc.d -f jack-ss remove; fi
    rm -f /etc/init.d/jack-ss
  fi
  rm -rf -- "$ROOT"
  if [[ -f "$MENU" ]] && grep -q JACK_SS_MENU "$MENU"; then rm -f "$MENU"; fi
  echo '卸载完成'; exit 0
}
main() {
  case "${1:-}" in --version) echo "$VERSION"; return;; --help) echo 's-s：中文菜单；--start / --stop / --restart：管理服务。'; return;; esac
  root_check
  case "${1:-}" in
    --start) load_state; start_service; return;; --stop) stop_service; return;; --restart) load_state; restart_service; return;;
    ''|--menu) ;; *) fail "未知参数：$1";;
  esac
  install_menu
  while true; do
    printf '\n===== Jack SS 轻量版 %s =====\n' "$VERSION"
    printf '%s\n' '1. 安装 / 迁移' '2. 查看节点' '3. 修改端口' '4. 修改密码' '5. 启动' '6. 停止' '7. 重启' '8. 查看日志' '9. 更新内核' '10. 修改公网地址' '11. 卸载' '12. TCP / UDP 设置' '0. 退出'
    ask '请选择：' choice
    case "$choice" in
      1) install_node;; 2) node_info;; 3) change_settings ports;; 4) change_settings password;;
      5) load_state; start_service;; 6) stop_service;; 7) load_state; restart_service;;
      8) show_logs;; 9) update_core;; 10) change_settings address;; 11) uninstall_node;; 12) change_settings mode;; 0) return;; *) echo '编号无效';;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
