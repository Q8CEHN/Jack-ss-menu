#!/usr/bin/env bash
# JACK_SS_MENU — lightweight Shadowsocks manager.
set -Eeuo pipefail
umask 077
VERSION=3.2.0
BASE=/etc/jack-ss
ROOT=$BASE
NODE_ID=legacy
SERVICE=jack-ss
GUARD=jack-ss-iplimit
TABLE=jack_ss_iplimit
QUEUE=29083
MENU=/usr/local/bin/s-s
UNIT=/etc/systemd/system/jack-ss.service
INIT=/etc/init.d/jack-ss
CORE_DIR=/opt/jack-ss
LEGACY_MENU=/usr/local/bin/ss
POLICY_FILE=/usr/sbin/policy-rc.d
VENDOR_CONFIG=/etc/shadowsocks-libev
SYSTEMD_DIR=/etc/systemd/system
INIT_DIR=/etc/init.d
POLICY_OWN=0
UPDATE_TMP=''
cleanup() {
  if (( POLICY_OWN )) && [[ -f "$POLICY_FILE" ]] && grep -q JACK_SS_PACKAGE_GUARD "$POLICY_FILE"; then rm -f "$POLICY_FILE"; fi
  if [[ -n "$UPDATE_TMP" ]]; then rm -f -- "$UPDATE_TMP"; fi
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
record_packages_after_impl() {
  [[ -f "$ROOT/packages.before" ]] || return 0
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u >"$ROOT/packages.after"
  comm -13 "$ROOT/packages.before" "$ROOT/packages.after" >>"$ROOT/packages.owned"
  sort -u "$ROOT/packages.owned" -o "$ROOT/packages.owned"
  rm -f "$ROOT/packages.before" "$ROOT/packages.after"
}
install_core_impl() {
  if command -v ss-server >/dev/null; then
    if [[ ! -f "$ROOT/core-origin" ]]; then
      if [[ -f "$ROOT/settings" || -f "$ROOT/config.json" ]]; then
        printf 'legacy\n' >"$ROOT/core-origin"
      else install -d -m 700 "$ROOT"; printf 'shared\n' >"$ROOT/core-origin"; fi
    fi
    record_packages_after
    return
  fi
  check_space
  install -d -m 700 "$ROOT"
  printf 'owned\n' >"$ROOT/core-origin"
  if command -v apt-get >/dev/null; then
    # Prevent a newly installed package from starting its example server.
    if [[ ! -e "$POLICY_FILE" ]]; then
      cat >"$POLICY_FILE" <<'POLICY'
#!/bin/sh
# JACK_SS_PACKAGE_GUARD
case "$1" in shadowsocks-libev*) exit 101;; *) exit 0;; esac
POLICY
      chmod 755 "$POLICY_FILE"; POLICY_OWN=1
    fi
    if ! apt-cache show shadowsocks-libev >/dev/null 2>&1; then
      apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
    fi
    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u >"$ROOT/packages.before"
    DEBIAN_FRONTEND=noninteractive apt-get -o APT::Keep-Downloaded-Packages=false install -y --no-install-recommends shadowsocks-libev
    record_packages_after
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
  NAME=${NAME:-默认节点}
  source "$ROOT/settings"
}
write_state() {
  local key
  for key in NAME HOST LOCAL_PORT PUBLIC_PORT PASSWORD MODE METHOD; do printf '%s=%q\n' "$key" "${!key}"; done >"$ROOT/settings.new"
  mv -f "$ROOT/settings.new" "$ROOT/settings"
}
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}
write_config() {
  local bind_address=0.0.0.0 bind_port=$LOCAL_PORT
  [[ "$HOST" != *:* ]] || bind_address=::
  if [[ -f "$ROOT/ip-limit" && -f "$ROOT/ip-backend-port" ]]; then
    read -r bind_port <"$ROOT/ip-backend-port"
    valid_port "$bind_port" || fail '内部端口配置无效。'
    bind_address=127.0.0.1
  fi
  cat >"$ROOT/config.json.new" <<JSON
{
  "server": "$bind_address",
  "server_port": $bind_port,
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
  if is_systemd; then systemctl start "$SERVICE"; else
    process_running && return 0
    ss-server -c "$ROOT/config.json" -f "$ROOT/ss.pid" >/dev/null 2>&1
  fi
}
stop_service() {
  if is_systemd; then systemctl stop "$SERVICE"; else
    if process_running; then
      kill "$pid"
      local count
      for count in {1..10}; do process_running || break; sleep 0.2; done
      process_running && return 1
    fi
    rm -f "$ROOT/ss.pid"
  fi
}
healthy() { if is_systemd; then systemctl is-active --quiet "$SERVICE"; else process_running; fi; }
restart_service() { stop_service && start_service; }
register_service() {
  local core
  core=$(command -v ss-server)
  if is_systemd; then
    cat >"$UNIT" <<UNIT
[Unit]
Description=Jack SS node $NODE_ID
# JACK_SS_MENU
After=network.target
[Service]
ExecStart=$core -c $ROOT/config.json
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
    systemctl daemon-reload; systemctl enable "$SERVICE" >/dev/null
  elif command -v rc-update >/dev/null && [[ -x /sbin/openrc-run ]]; then
    cat >"$INIT" <<INIT
#!/sbin/openrc-run
# JACK_SS_MENU
name="Jack SS"
command="$core"
command_args="-c $ROOT/config.json"
command_background=true
pidfile="$ROOT/ss.pid"
depend() { need net; }
INIT
    chmod 755 "$INIT"; rc-update add "$SERVICE" default
  elif command -v update-rc.d >/dev/null; then
    cat >"$INIT" <<INIT
#!/bin/sh
# JACK_SS_MENU
### BEGIN INIT INFO
# Provides: $SERVICE
# Required-Start: \$network
# Required-Stop: \$network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Jack SS node
### END INIT INFO
case "\$1" in
start) exec /usr/local/bin/s-s --node $NODE_ID --start;;
stop) exec /usr/local/bin/s-s --node $NODE_ID --stop;;
restart) exec /usr/local/bin/s-s --node $NODE_ID --restart;;
*) exit 1;;
esac
INIT
    chmod 755 "$INIT"; update-rc.d "$SERVICE" defaults
  else echo "未配置开机启动，可使用 s-s --node $NODE_ID --start。"; fi
}
node_info() {
  load_state
  local address=$HOST token protocol=TCP
  [[ "$MODE" != tcp_and_udp ]] || protocol='TCP + UDP'
  [[ "$address" != *:* ]] || address="[$address]"
  token=$(printf '%s:%s' "$METHOD" "$PASSWORD" | base64 | tr '/+' '_-' | tr -d '=\n')
  {
    printf '节点：%s\n' "$NAME"
    printf '服务器：%s\n端口：%s\n' "$HOST" "$PUBLIC_PORT"
    if [[ "$LOCAL_PORT" != "$PUBLIC_PORT" ]]; then printf '本机端口：%s\n' "$LOCAL_PORT"; fi
    printf '协议：%s\n加密：%s\n密码：%s\n\n' "$protocol" "$METHOD" "$PASSWORD"
    printf 'ss://%s@%s:%s#Jack-SS-%s\n' "$token" "$address" "$PUBLIC_PORT" "$NODE_ID"
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
  local migrating=0 value
  if [[ -f "$ROOT/config.json" ]]; then
    grep -q '"inbounds"' "$ROOT/config.json" || fail '发现未知配置，停止覆盖。'
    legacy_import; migrating=1
    read_address
    is_systemd || fail '旧版迁移需要在原 systemd 环境执行。'
    systemctl stop "$SERVICE"
  else
    ask '节点名称（留空使用默认名称）：' value
    NAME=${value:-$NAME}
    read_port '端口' "${DEFAULT_PORT:-8388}" LOCAL_PORT
    PUBLIC_PORT=$LOCAL_PORT
    read_address
    read_mode; METHOD=chacha20-ietf-poly1305
    ask '密码（留空随机）：' PASSWORD; [[ -n "$PASSWORD" ]] || random_password
    ensure_port_free "$LOCAL_PORT" || return 1
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
      systemctl daemon-reload; systemctl restart "$SERVICE" || true
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
  local old_port=$LOCAL_PORT old_mode=$MODE
  case "$1" in
    ports) read_port '端口' "$LOCAL_PORT" LOCAL_PORT; PUBLIC_PORT=$LOCAL_PORT;;
    password) ask '新密码（留空随机）：' PASSWORD; [[ -n "$PASSWORD" ]] || random_password;;
    address) read_address;; mode) read_mode;; name) ask '节点名称：' NAME; [[ -n "$NAME" ]] || fail '名称不能为空。';;
  esac
  if [[ "$LOCAL_PORT" != "$old_port" ]]; then ensure_port_free "$LOCAL_PORT" || return 0; fi
  if [[ "$LOCAL_PORT" == "$old_port" && "$old_mode" == tcp_only && "$MODE" == tcp_and_udp ]]; then
    if command -v ss >/dev/null && [[ -n $(ss -H -lun "sport = :$LOCAL_PORT") ]]; then echo 'UDP 端口已被占用。'; return 0; fi
  fi
  cp -p "$ROOT/settings" "$ROOT/settings.previous"
  cp -p "$ROOT/config.json" "$ROOT/config.json.previous"
  stop_service || fail '无法停止节点，未修改配置。'
  write_config; write_state
  if [[ -f "$ROOT/ip-limit" ]] && ! iplimit_apply; then
    mv -f "$ROOT/settings.previous" "$ROOT/settings"; mv -f "$ROOT/config.json.previous" "$ROOT/config.json"
    iplimit_apply || fail '限制服务恢复失败，请查看日志。'
    start_service || true; fail 'IP 限制更新失败，已恢复旧配置。'
  fi
  if ! start_service; then echo '重启失败。'; fi
  sleep 1
  if ! healthy; then
    mv -f "$ROOT/settings.previous" "$ROOT/settings"; mv -f "$ROOT/config.json.previous" "$ROOT/config.json"
    if [[ -f "$ROOT/ip-limit" ]]; then iplimit_apply || fail '限制服务恢复失败，请查看日志。'; fi
    restart_service || true; fail '修改失败，已恢复旧配置。'
  fi
  rm -f "$ROOT/settings.previous" "$ROOT/config.json.previous"
  firewall_remove; firewall_add
  if [[ "$1" == password ]]; then node_info; else echo '设置已保存'; fi
}
show_logs() {
  if is_systemd; then journalctl -u "$SERVICE" -n 30 --no-pager
  elif command -v logread >/dev/null; then logread | tail -40
  else echo '当前系统没有日志服务。'; fi
}
update_core() {
  local selected=$NODE_ID id
  mapfile -t core_nodes < <(node_ids)
  if command -v apt-get >/dev/null; then
    apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --only-upgrade shadowsocks-libev
  elif command -v apk >/dev/null; then apk upgrade --no-cache shadowsocks-libev
  elif command -v dnf >/dev/null; then dnf upgrade -y shadowsocks-libev
  elif command -v yum >/dev/null; then yum update -y shadowsocks-libev; fi
  for id in "${core_nodes[@]}"; do
    node_context "$id"; load_state
    if healthy; then restart_service; healthy || fail "节点 $NAME 更新后启动失败。"; fi
  done
  node_context "$selected"
  echo '更新完成'
}
fetch_menu_update() {
  local release newest
  command -v curl >/dev/null || { echo '未找到 curl，请先安装 curl。' >&2; return 1; }
  UPDATE_TMP=$(mktemp "${MENU}.update.XXXXXX") || return 1
  if ! curl -fLSs --retry 2 --connect-timeout 10 --max-time 90 --proto '=https' --proto-redir '=https' \
    "https://raw.githubusercontent.com/Q8CEHN/Jack-ss-menu/main/ss.sh?update=$(date +%s)" -o "$UPDATE_TMP"; then
    echo '下载失败，保留当前菜单。' >&2; rm -f "$UPDATE_TMP"; UPDATE_TMP=''; return 1
  fi
  release=$(sed -n 's/^VERSION=//p' "$UPDATE_TMP")
  if ! grep -q '^# JACK_SS_MENU' "$UPDATE_TMP" || ! bash -n "$UPDATE_TMP" ||
     [[ ! "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo '下载内容不是有效的菜单脚本，保留当前菜单。' >&2
    rm -f "$UPDATE_TMP"; UPDATE_TMP=''; return 1
  fi
  newest=$(printf '%s\n%s\n' "$VERSION" "$release" | sort -V | tail -1)
  if [[ "$newest" != "$release" ]]; then
    echo "远端版本 $release 低于当前 $VERSION，保留当前菜单。" >&2
    rm -f "$UPDATE_TMP"; UPDATE_TMP=''; return 1
  fi
  [[ ! -e "$MENU" ]] || grep -q JACK_SS_MENU "$MENU" || { echo '快捷命令被其他程序占用。' >&2; return 1; }
  chmod 755 "$UPDATE_TMP" || return 1
  mv -f -- "$UPDATE_TMP" "$MENU" || return 1
  UPDATE_TMP=''
  echo "菜单已更新至 $release，节点配置已保留。"
}
update_menu() {
  if fetch_menu_update; then
    cleanup
    exec bash "$MENU" --menu
  fi
  return 0
}
updates_menu() {
  local choice
  menu_screen
  printf '更新\n\n%s\n' '1. 更新菜单（获取新功能）' '2. 更新 SS 内核' '0. 返回'
  ask '请选择：' choice
  case "$choice" in 1) update_menu;; 2) update_core; pause_menu;; 0) return;; *) echo '编号无效';; esac
}
core_is_shared_impl() {
  local exe target config origin=''
  [[ ! -r "$ROOT/core-origin" ]] || read -r origin <"$ROOT/core-origin"
  [[ "$origin" != shared ]] || return 0
  for exe in /proc/[0-9]*/exe; do
    target=$(readlink "$exe" 2>/dev/null || true)
    case "$target" in */ss-server|*/ss-server\ \(deleted\)|*/ss-local|*/ss-tunnel|*/ss-redir|*/ss-manager) return 0;; esac
  done
  # The package's generated loopback-only example is not another user node.
  if [[ -d "$VENDOR_CONFIG" ]]; then
    while IFS= read -r config; do
      if [[ "$config" != "$VENDOR_CONFIG/config.json" ]] ||
         ! tr -d '[:space:]' <"$config" | grep -Fq '"server":["::1","127.0.0.1"]'; then return 0; fi
    done < <(find "$VENDOR_CONFIG" -type f -name '*.json')
  fi
  while IFS= read -r config; do
    target=$(readlink -f "$config" 2>/dev/null || true)
    [[ "$target" != "$(readlink -f "$UNIT")" && "$target" != "$(readlink -f "$INIT")" ]] || continue
    [[ "$config" != "$INIT_DIR/shadowsocks-libev" ]] || continue
    if grep -q JACK_SS_MENU "$config" && grep -Fq "$BASE/nodes/" "$config"; then continue; fi
    return 0
  done < <(grep -RlE '(ss-server|ss-local|ss-tunnel|ss-redir|ss-manager)' "$SYSTEMD_DIR" "$INIT_DIR" 2>/dev/null || true)
  return 1
}
apt_purge_checked() {
  local plan action name rest requested allowed
  (( $# )) || return 0
  plan=$(LC_ALL=C apt-get -s purge -- "$@") || return 1
  while read -r action name rest; do
    if [[ "$action" == Inst ]]; then echo '保留软件包：卸载会触发其他软件变更。' >&2; return 2; fi
    [[ "$action" == Remv || "$action" == Purg ]] || continue
    allowed=0
    for requested in "$@"; do
      [[ "${name%%:*}" != "${requested%%:*}" ]] || allowed=1
    done
    if (( ! allowed )); then echo "保留软件包：其他软件依赖 $name。" >&2; return 2; fi
  done <<<"$plan"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -- "$@"
}
remove_core_impl() {
  if core_is_shared; then echo '保留共享内核。'; return 0; fi
  if command -v apt-get >/dev/null; then
    local result=0 plan action name rest
    local -a candidates=() orphaned=()
    if [[ -f "$ROOT/packages.owned" ]]; then
      mapfile -t candidates <"$ROOT/packages.owned"
    else
      # Old versions did not track installations. Only consider package-manager
      # auto-removable libev dependencies; never invoke global autoremove.
      candidates=(libbloom2 libcork16 libcorkipset1 libjsonparser1.1 libev4 libev4t64 libcares2 libmbedcrypto7 libmbedcrypto16)
    fi
    if dpkg-query -W -f='${db:Status-Abbrev}' shadowsocks-libev 2>/dev/null | grep -Eq '^(ii|rc)'; then
      apt_purge_checked shadowsocks-libev || result=$?
      (( result != 2 )) || return 0
      (( result == 0 )) || return "$result"
    fi
    plan=$(LC_ALL=C apt-get -s autoremove) || return 1
    local candidate
    while read -r action name rest; do
      [[ "$action" == Remv || "$action" == Purg ]] || continue
      for candidate in "${candidates[@]}"; do
        if [[ "${name%%:*}" == "${candidate%%:*}" ]]; then orphaned+=("$name"); break; fi
      done
    done <<<"$plan"
    apt_purge_checked "${orphaned[@]}" || result=$?
    (( result != 2 )) || return 0
    return "$result"
  elif command -v apk >/dev/null; then
    if apk info -r shadowsocks-libev 2>/dev/null | tail -n +2 | grep -q '[^[:space:]]'; then echo '保留共享内核。'; return 0; fi
    if apk info -e shadowsocks-libev >/dev/null 2>&1; then apk del shadowsocks-libev || return 1; fi
  elif command -v rpm >/dev/null && rpm -q shadowsocks-libev >/dev/null 2>&1; then
    if rpm -q --whatrequires shadowsocks-libev >/dev/null 2>&1; then echo '保留共享内核。'; return 0; fi
    if command -v dnf >/dev/null; then dnf remove -y --setopt=clean_requirements_on_remove=True shadowsocks-libev || return 1
    elif command -v yum >/dev/null; then yum remove -y --setopt=clean_requirements_on_remove=1 shadowsocks-libev || return 1; fi
  fi
  return 0
}
iplimit_install_deps_impl() {
  is_systemd || fail 'IP 限制目前需要 systemd。'
  if [[ -x /usr/bin/python3 ]]; then return; fi
  command -v apt-get >/dev/null || fail '请先安装系统 Python 3。'
  apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
  printf 'python3\n' >>"$ROOT/ip-packages.direct"
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u >"$ROOT/packages.before"
  DEBIAN_FRONTEND=noninteractive apt-get -o APT::Keep-Downloaded-Packages=false install -y --no-install-recommends python3
  record_packages_after
}
write_ip_guard() {
  cat >"$ROOT/ip_guard.py.new" <<'JACK_IP_GUARD_PY' || return 1
#!/usr/bin/python3
"""JACK_SS_IP_GUARD: per-node encrypted TCP/UDP relay, without kernel queues."""
import argparse
import asyncio
import collections
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import time

IDLE = 300
COOLDOWN = 60


def normalize_ip(value):
    ip = ipaddress.ip_address(value)
    return str(ip.ipv4_mapped or ip) if isinstance(ip, ipaddress.IPv6Address) else str(ip)


class Admission:
    def __init__(self, limit, evict=lambda ip: None, clock=time.monotonic):
        self.limit, self.evict, self.clock = limit, evict, clock
        self.active = collections.OrderedDict()
        self.banned = {}

    def expire(self):
        now = self.clock()
        for ip, touched in list(self.active.items()):
            if now - touched >= IDLE:
                del self.active[ip]
                self.evict(ip)
        self.banned = {ip: until for ip, until in self.banned.items() if until > now}

    def admit(self, ip):
        self.expire()
        if ip in self.banned:
            return False
        if ip in self.active:
            self.active[ip] = self.clock()
            return True
        if len(self.active) >= self.limit:
            victim, _ = self.active.popitem(last=True)
            self.banned[victim] = self.clock() + COOLDOWN
            self.evict(victim)
        self.active[ip] = self.clock()
        return True

    def touch(self, ip):
        if ip in self.active:
            self.active[ip] = self.clock()


class Reply(asyncio.DatagramProtocol):
    def __init__(self, relay, key, ip):
        self.relay, self.key, self.ip = relay, key, ip

    def datagram_received(self, data, _):
        if self.ip in self.relay.admission.active:
            self.relay.admission.touch(self.ip)
            self.relay.udp_touched[self.key] = time.monotonic()
            self.relay.front_udp.sendto(data, self.key)


class FrontUDP(asyncio.DatagramProtocol):
    def __init__(self, relay):
        self.relay = relay

    def datagram_received(self, data, address):
        r = self.relay
        ip = normalize_ip(address[0])
        if not r.admission.admit(ip):
            return
        r.udp_touched[address] = time.monotonic()
        if address in r.udp_sessions:
            r.udp_sessions[address].sendto(data)
        elif address in r.pending_udp:
            r.pending_udp[address].append(data)
        else:
            r.pending_udp[address] = collections.deque([data], maxlen=32)
            task = asyncio.create_task(r.new_udp(address, ip))
            r.udp_tasks.add(task)
            task.add_done_callback(r.udp_tasks.discard)


class Relay:
    def __init__(self, limit, backend, status):
        self.backend, self.status = backend, Path(status)
        self.tcp_writers = collections.defaultdict(set)
        self.udp_sessions, self.udp_touched, self.pending_udp = {}, {}, {}
        self.udp_tasks = set()
        self.front_udp = None
        self.admission = Admission(limit, self.evict)

    def evict(self, ip):
        for writer in self.tcp_writers.pop(ip, set()):
            writer.close()
        for address in list(set(self.udp_sessions) | set(self.pending_udp)):
            if normalize_ip(address[0]) == ip:
                transport = self.udp_sessions.pop(address, None)
                if transport:
                    transport.close()
                self.pending_udp.pop(address, None)
                self.udp_touched.pop(address, None)

    def publish(self):
        data = {'limit': self.admission.limit, 'active': list(self.admission.active),
                'banned': list(self.admission.banned), 'updated': time.time(),
                'idle_seconds': IDLE, 'cooldown_seconds': COOLDOWN}
        temp = self.status.with_suffix('.new')
        temp.write_text(json.dumps(data))
        temp.replace(self.status)

    async def tcp_client(self, reader, writer):
        ip = normalize_ip(writer.get_extra_info('peername')[0])
        if not self.admission.admit(ip):
            writer.close()
            return
        writers = self.tcp_writers[ip]
        writers.add(writer)
        upstream, pumps = None, []
        try:
            incoming, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.backend), 5)
            if ip not in self.admission.active or writer.is_closing():
                return
            writers.add(upstream)

            async def pump(source, destination):
                while data := await source.read(65536):
                    if ip not in self.admission.active:
                        return
                    self.admission.touch(ip)
                    destination.write(data)
                    await destination.drain()
                with contextlib.suppress(OSError, RuntimeError):
                    destination.write_eof()

            pumps = [asyncio.create_task(pump(reader, upstream)), asyncio.create_task(pump(incoming, writer))]
            await asyncio.gather(*pumps)
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            for task in pumps:
                task.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            writer.close()
            writers.discard(writer)
            if upstream:
                upstream.close()
                writers.discard(upstream)
            if not writers and self.tcp_writers.get(ip) is writers:
                self.tcp_writers.pop(ip, None)

    async def new_udp(self, address, ip):
        transport = None
        try:
            transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: Reply(self, address, ip), remote_addr=('127.0.0.1', self.backend))
            pending = self.pending_udp.pop(address, None)
            if pending is None or ip not in self.admission.active:
                transport.close()
                return
            self.udp_sessions[address] = transport
            for data in pending:
                transport.sendto(data)
        except OSError:
            if transport:
                transport.close()
            self.pending_udp.pop(address, None)
            self.udp_touched.pop(address, None)

    async def maintain(self):
        while True:
            self.admission.expire()
            for address, touched in list(self.udp_touched.items()):
                if time.monotonic() - touched >= IDLE:
                    transport = self.udp_sessions.pop(address, None)
                    if transport:
                        transport.close()
                    self.udp_touched.pop(address, None)
            self.publish()
            await asyncio.sleep(1)


def bound_socket(host, port, kind):
    family = socket.AF_INET6 if ':' in host else socket.AF_INET
    sock = socket.socket(family, kind)
    try:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        if kind == socket.SOCK_STREAM:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close()
        raise


async def run(args):
    os.umask(0o077)
    Path(args.status).parent.mkdir(parents=True, exist_ok=True)
    relay = Relay(args.limit, args.backend, args.status)
    server = await asyncio.start_server(relay.tcp_client, sock=bound_socket(args.bind, args.port, socket.SOCK_STREAM))
    maintenance = stopped = None
    try:
        if args.udp:
            relay.front_udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: FrontUDP(relay), sock=bound_socket(args.bind, args.port, socket.SOCK_DGRAM))
        relay.publish()
        notify = os.environ.get('NOTIFY_SOCKET')
        if notify:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
                sock.connect('\0' + notify[1:] if notify.startswith('@') else notify)
                sock.sendall(b'READY=1')
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        maintenance = asyncio.create_task(relay.maintain())
        stopped = asyncio.create_task(stop.wait())
        done, _ = await asyncio.wait([maintenance, stopped], return_when=asyncio.FIRST_COMPLETED)
        if maintenance in done:
            maintenance.result()
    finally:
        server.close()
        # Python 3.13 waits for accepted connections too: close them first.
        for ip in list(relay.tcp_writers):
            relay.evict(ip)
        await server.wait_closed()
        tasks = [task for task in (maintenance, stopped) if task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for transport in relay.udp_sessions.values():
            transport.close()
        if relay.front_udp:
            relay.front_udp.close()
        for task in list(relay.udp_tasks):
            task.cancel()
        await asyncio.gather(*relay.udp_tasks, return_exceptions=True)
        Path(args.status).unlink(missing_ok=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--backend', type=int, required=True)
    p.add_argument('--limit', type=int, required=True)
    p.add_argument('--bind', default='0.0.0.0')
    p.add_argument('--udp', action='store_true')
    p.add_argument('--status', required=True)
    args = p.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.backend <= 65535 or args.port == args.backend or not 1 <= args.limit <= 4096:
        p.error('invalid port or IP limit')
    try:
        asyncio.run(run(args))
    except OSError as exc:
        raise SystemExit(f'IP relay could not start: {exc}') from exc


if __name__ == '__main__':
    main()
JACK_IP_GUARD_PY
  chmod 700 "$ROOT/ip_guard.py.new" || return 1
  mv -f "$ROOT/ip_guard.py.new" "$ROOT/ip_guard.py"
}
iplimit_backend() {
  local id
  local -a reserved=("$LOCAL_PORT")
  while IFS= read -r id; do reserved+=("$(node_context "$id"; load_state; printf '%s' "$LOCAL_PORT")"); done < <(node_ids)
  /usr/bin/python3 - "$ROOT/ip-backend-port" "${reserved[@]}" <<'PY_BACKEND'
import pathlib,socket,sys
p=pathlib.Path(sys.argv[1]); reserved={int(x) for x in sys.argv[2:]}
previous=int(p.read_text()) if p.exists() else 0
for attempt in range(100):
    tcp=socket.socket(); udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    try:
        tcp.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        tcp.bind(('127.0.0.1', previous if attempt==0 else 0))
        port=tcp.getsockname()[1]
        if port in reserved: continue
        udp.bind(('127.0.0.1',port))
        temp=p.with_suffix('.new'); temp.write_text(str(port)+'\n'); temp.replace(p)
        break
    except OSError:
        continue
    finally:
        tcp.close(); udp.close()
else: raise SystemExit('没有可用的内部转发端口。')
PY_BACKEND
}
iplimit_clear_legacy_table() {
  if command -v nft >/dev/null && nft list table inet "$TABLE" >/dev/null 2>&1; then
    nft delete table inet "$TABLE" || return 1
  fi
}
iplimit_apply() {
  local limit backend udp='' bind=0.0.0.0
  read -r limit <"$ROOT/ip-limit"
  [[ "$limit" =~ ^[0-9]{1,4}$ ]] && (( limit >= 1 && limit <= 4096 )) || { echo 'IP 上限无效。'; return 1; }
  load_state
  [[ "$MODE" != tcp_and_udp ]] || udp=--udp
  [[ "$HOST" != *:* ]] || bind=::
  stop_service || return 1
  systemctl stop "$GUARD" >/dev/null 2>&1 || true
  iplimit_clear_legacy_table || return 1
  iplimit_backend || return 1
  read -r backend <"$ROOT/ip-backend-port"
  write_config || return 1
  write_ip_guard || return 1
  cat >"$SYSTEMD_DIR/$GUARD.service" <<UNIT || return 1
[Unit]
Description=Jack SS per-node IP relay
StartLimitIntervalSec=0
After=network.target
Before=$SERVICE.service
PartOf=$SERVICE.service
[Service]
Type=notify
NotifyAccess=main
ExecStart=/usr/bin/python3 $ROOT/ip_guard.py --port $LOCAL_PORT --backend $backend --limit $limit --bind $bind $udp --status /run/$GUARD/status.json
ExecStartPost=/usr/bin/systemctl --no-block start $SERVICE.service
Restart=always
RestartSec=3
TimeoutStartSec=15
RuntimeDirectory=$GUARD
RuntimeDirectoryMode=0700
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run/$GUARD
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
UNIT
  install -d -m 755 "$SYSTEMD_DIR/$SERVICE.service.d" || return 1
  cat >"$SYSTEMD_DIR/$SERVICE.service.d/iplimit.conf" <<UNIT || return 1
[Unit]
Requires=$GUARD.service
After=$GUARD.service
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=3
UNIT
  systemctl daemon-reload || return 1
  if ! systemctl restart "$GUARD"; then
    journalctl -u "$GUARD" -n 12 --no-pager >&2 || true
    return 1
  fi
  systemctl is-active --quiet "$GUARD" || return 1
  start_service || return 1
  healthy
}
iplimit_disable() {
  local was_running=0
  healthy && was_running=1
  if [[ -f "$ROOT/ip-backend-port" ]]; then stop_service || return 1; fi
  if is_systemd; then
    systemctl stop "$GUARD" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$GUARD"; then echo 'IP 限制服务无法停止。' >&2; return 1; fi
  fi
  iplimit_clear_legacy_table || return 1
  rm -f "$SYSTEMD_DIR/$GUARD.service" "$SYSTEMD_DIR/$SERVICE.service.d/iplimit.conf"
  rmdir "$SYSTEMD_DIR/$SERVICE.service.d" 2>/dev/null || true
  rm -f "$ROOT/ip-limit" "$ROOT/ip_guard.py" "$ROOT/ip_guard.py.new" "$ROOT/ip-backend-port" "$ROOT/ip-backend-port.new"
  if [[ -f "$ROOT/settings" ]]; then load_state; write_config || return 1; fi
  if is_systemd; then systemctl daemon-reload; systemctl reset-failed "$GUARD" >/dev/null 2>&1 || true; fi
  if (( was_running )); then start_service || return 1; fi
  return 0
}
iplimit_remove_deps_impl() {
  [[ -f "$ROOT/ip-packages.direct" ]] || return 0
  local -a packages=()
  local result=0 package
  mapfile -t packages <"$ROOT/ip-packages.direct"
  if command -v apt-get >/dev/null; then
    for package in "${packages[@]}"; do
      result=0
      apt_purge_checked "$package" || result=$?
      (( result == 0 || result == 2 )) || return "$result"
    done
  fi
}
iplimit_status() {
  if [[ ! -f "$ROOT/ip-limit" ]]; then echo 'IP 限制：关闭'; return; fi
  local limit
  read -r limit <"$ROOT/ip-limit"
  echo "IP 上限：$limit；新 IP 替换最后接入的 IP。"
  if ! systemctl is-active --quiet "$GUARD"; then echo '上限设置已保留；启动节点后继续生效，服务故障会自动重试。'; return; fi
  /usr/bin/python3 - "/run/$GUARD/status.json" <<'PY_STATUS'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
if not p.exists():
    print('正在加载 IP 列表。')
else:
    c=json.loads(p.read_text())
    print('当前 IP（按首次接入顺序）：')
    for n, ip in enumerate(c['active'],1): print(f'  {n}. {ip}')
    if not c['active']: print('  暂无')
    if c['banned']: print('等待重连：' + '、'.join(c['banned']))
PY_STATUS
}
iplimit_menu() {
  load_state
  local choice value
  while true; do
    menu_screen
    local cap=不限
    [[ ! -f "$ROOT/ip-limit" ]] || read -r cap <"$ROOT/ip-limit"
    printf '%s · IP 限制\n当前上限：%s\n\n' "$NAME" "$cap"
    printf '%s\n' '按来源 IP 计数，不校验 SS 密码。' '超额替换最后接入者，被替换 IP 等待 60 秒。' '' '1. 设置上限' '2. 当前 IP' '3. 清空接入记录' '4. 关闭限制' '0. 返回'

    ask '请选择：' choice
    case "$choice" in
      1)
        ask '最多允许几个 IP？[1–4096，0 关闭]：' value
        [[ "$value" =~ ^[0-9]{1,4}$ ]] && (( 10#$value <= 4096 )) || { echo '请输入 0–4096。'; pause_menu; continue; }
        value=$((10#$value))
        if (( value == 0 )); then iplimit_disable; echo '已关闭限制'; pause_menu; continue; fi
        iplimit_install_deps
        printf '%s\n' "$value" >"$ROOT/ip-limit"
        if iplimit_apply; then echo '设置完成'; else
          echo '上限已保存，不会自动关闭。限制服务启动失败时会持续重试。'
          echo '如需取消，请手动选择 4 关闭限制。'
        fi;;
      2) iplimit_status;;
      3) if [[ -f "$ROOT/ip-limit" ]]; then iplimit_apply; echo '已清空，新流量重新排序。'; else echo '尚未启用限制。'; fi;;
      4) iplimit_disable; echo '已关闭限制';;
      0) return;; *) echo '编号无效';;
    esac
    pause_menu
  done
}
# Package ownership is global; credentials, services and limits are per-node.
record_packages_after() { local ROOT=$BASE; record_packages_after_impl; }
install_core() { local ROOT=$BASE; install_core_impl; }
core_is_shared() { local ROOT=$BASE; core_is_shared_impl; }
remove_core() { local ROOT=$BASE; remove_core_impl; }
iplimit_install_deps() { local ROOT=$BASE; iplimit_install_deps_impl; }
iplimit_remove_deps() { local ROOT=$BASE; iplimit_remove_deps_impl; }
node_context() {
  local id=$1
  if [[ "$id" == legacy ]]; then
    ROOT=$BASE; NODE_ID=legacy; SERVICE=jack-ss
    GUARD=jack-ss-iplimit; TABLE=jack_ss_iplimit; QUEUE=29083; NAME=原有节点
  else
    [[ "$id" =~ ^[1-9][0-9]{0,4}$ ]] && (( id <= 30000 )) || fail '节点编号无效。'
    NODE_ID=$id; ROOT=$BASE/nodes/$id; SERVICE=jack-ss-node-$id
    GUARD=jack-ss-iplimit-node-$id; TABLE=jack_ss_iplimit_n$id; QUEUE=$((30000 + id)); NAME=节点$id
  fi
  UNIT=$SYSTEMD_DIR/$SERVICE.service; INIT=$INIT_DIR/$SERVICE
  unset HOST LOCAL_PORT PUBLIC_PORT PASSWORD MODE METHOD
}
node_ids() {
  local directory id
  if [[ -f "$BASE/settings" ]]; then printf 'legacy\n'; fi
  for directory in "$BASE"/nodes/*; do
    [[ -d "$directory" && -f "$directory/settings" ]] || continue
    id=${directory##*/}
    [[ "$id" =~ ^[1-9][0-9]{0,4}$ ]] && (( id <= 30000 )) || continue
    printf '%s\n' "$id"
  done
}
current_required() {
  [[ -f "$ROOT/settings" ]] && return 0
  echo '请先新建节点，或选择 2 切换节点。'
  return 1
}
list_nodes() {
  local id number=0
  printf '\n节点列表\n\n'
  while IFS= read -r id; do
    number=$((number + 1))
    (
      node_context "$id"; load_state
      local state=已停止 limit=不限
      healthy && state=运行中
      [[ ! -f "$ROOT/ip-limit" ]] || read -r limit <"$ROOT/ip-limit"
      printf '%s. %s [%s]\n   端口 %s  ·  IP 上限 %s\n\n' "$number" "$NAME" "$state" "$LOCAL_PORT" "$limit"
    )
  done < <(node_ids)
  (( number )) || echo '暂无节点。'
  return 0
}
select_node() {
  NODE_CHOSEN=0
  menu_screen
  local answer index
  local -a ids=()
  mapfile -t ids < <(node_ids)
  list_nodes
  (( ${#ids[@]} )) || return 0
  ask '选择节点编号（0 返回）：' answer
  [[ "$answer" =~ ^[0-9]{1,5}$ ]] || { echo '编号无效'; pause_menu; return 0; }
  index=$((10#$answer))
  (( index )) || return 0
  (( index <= ${#ids[@]} )) || { echo '编号无效'; pause_menu; return 0; }
  node_context "${ids[index-1]}"; load_state
  NODE_CHOSEN=1
}
ensure_port_free() {
  local requested=$1 id port
  while IFS= read -r id; do
    [[ "$id" != "$NODE_ID" ]] || continue
    port=$(node_context "$id"; load_state; printf '%s' "$LOCAL_PORT")
    if [[ "$port" == "$requested" ]]; then echo "端口 $requested 已用于其他节点。" >&2; return 1; fi
  done < <(node_ids)
  if command -v ss >/dev/null; then
    if [[ -n $(ss -H -ltn "sport = :$requested") || -n $(ss -H -lun "sport = :$requested") ]]; then
      echo "端口 $requested 已被其他服务占用。" >&2; return 1
    fi
  fi
  return 0
}
add_node() {
  if [[ -f "$BASE/config.json" && ! -f "$BASE/settings" ]]; then
    node_context legacy; install_node; return
  fi
  local id=1 port=8388
  while [[ -e "$BASE/nodes/$id" ]]; do id=$((id + 1)); done
  (( id <= 30000 )) || fail '节点编号已用尽。'
  node_context "$id"
  while (( port <= 65535 )); do
    ensure_port_free "$port" >/dev/null 2>&1 && break
    port=$((port + 1))
  done
  (( port <= 65535 )) || fail '没有可用端口。'
  install -d -m 700 "$ROOT"
  local DEFAULT_PORT=$port
  # Preserve a known public address as the default for subsequent nodes.
  if [[ -f "$BASE/settings" ]]; then HOST=$(node_context legacy; load_state; printf '%s' "$HOST");
  else
    local -a ids=(); mapfile -t ids < <(node_ids)
    if (( ${#ids[@]} )); then HOST=$(node_context "${ids[0]}"; load_state; printf '%s' "$HOST"); fi
  fi
  install_node
}
remove_node_resources() {
  stop_service || return 1
  healthy && { echo "节点 $NAME 仍在运行，停止删除。" >&2; return 1; }
  iplimit_disable || return 1
  firewall_remove || return 1
  if is_systemd; then
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT"
    find "$SYSTEMD_DIR" -mindepth 2 -maxdepth 2 -type l -name "$SERVICE.service" -delete
  fi
  if [[ -f "$INIT" ]] && grep -q JACK_SS_MENU "$INIT"; then
    if command -v rc-update >/dev/null; then rc-update del "$SERVICE" default || true
    elif command -v update-rc.d >/dev/null; then update-rc.d -f "$SERVICE" remove; fi
    rm -f "$INIT"
  fi
  if [[ "$NODE_ID" == legacy ]]; then
    # Global package records and all other nodes stay in BASE.
    rm -f "$ROOT/settings" "$ROOT/config.json" "$ROOT/node.txt" "$ROOT/firewall" "$ROOT/ss.pid" "$ROOT/host" "$ROOT/settings.previous" "$ROOT/config.json.previous"
    rm -rf -- "$ROOT/migration-backup"
  else
    rm -rf -- "$ROOT"
  fi
  if is_systemd; then systemctl daemon-reload; systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true; fi
}
delete_selected_node() {
  current_required || return 0
  load_state
  local answer
  ask "删除节点 $NAME（$LOCAL_PORT）？输入 YES：" answer
  [[ "$answer" == YES ]] || return 0
  remove_node_resources || fail '删除失败，已保留剩余资料以便重试。'
  echo '该节点已删除，其他节点保留。'
  local -a ids=(); mapfile -t ids < <(node_ids)
  node_context "${ids[0]:-legacy}"
}
uninstall_node() {
  local answer id
  local -a ids=()
  ask '卸载全部节点及本项目？输入 YES：' answer
  [[ "$answer" == YES ]] || return 0
  mapfile -t ids < <(node_ids)
  for id in "${ids[@]}"; do node_context "$id"; load_state; remove_node_resources || fail "节点 $NAME 清理失败。"; done
  # Also clean a legacy guard left by an interrupted old installation.
  node_context legacy
  stop_service || true
  iplimit_disable || fail '旧限制服务无法清理。'
  iplimit_remove_deps || fail '限制依赖清理失败。'
  remove_core || fail '软件包清理失败，保留安装记录以便重试。'
  if is_systemd; then systemctl disable "$SERVICE" >/dev/null 2>&1 || true; fi
  rm -f "$UNIT"
  rm -rf -- "$CORE_DIR" "$BASE"
  if [[ -f "$MENU" ]] && grep -q JACK_SS_MENU "$MENU"; then rm -f "$MENU"; fi
  if [[ -f "$LEGACY_MENU" ]] && grep -q JACK_SS_MENU "$LEGACY_MENU"; then rm -f "$LEGACY_MENU"; fi
  if is_systemd; then systemctl daemon-reload; fi
  echo '全部卸载完成'; exit 0
}
menu_screen() {
  # Clear the visible terminal only. Keep scrollback and noninteractive output.
  if [[ -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]]; then printf '\033[2J\033[H'; fi
  return 0
}
pause_menu() { local ignored; ask '按回车返回…' ignored; }
node_settings_menu() {
  local choice
  while true; do
    load_state; menu_screen
    printf '%s · 编辑设置\n\n' "$NAME"
    printf '%s\n' '1. 名称' '2. 端口' '3. 密码' '4. 公网地址' '5. TCP / UDP' '0. 返回'
    ask '请选择：' choice
    case "$choice" in
      1) change_settings name;; 2) change_settings ports;; 3) change_settings password;;
      4) change_settings address;; 5) change_settings mode;; 0) return;; *) echo '编号无效';;
    esac
    pause_menu
  done
}
node_menu() {
  local choice cap state protocol node_root=$ROOT
  while [[ -f "$node_root/settings" ]]; do
    load_state; menu_screen
    cap=不限; state=已停止; protocol=TCP
    [[ ! -f "$ROOT/ip-limit" ]] || read -r cap <"$ROOT/ip-limit"
    healthy && state=运行中
    [[ "$MODE" != tcp_and_udp ]] || protocol='TCP + UDP'
    printf '%s\n%s:%s\n%s  ·  %s  ·  IP 上限 %s\n\n' "$NAME" "$HOST" "$PUBLIC_PORT" "$state" "$protocol" "$cap"
    printf '%s\n' '1. 查看节点 / 分享链接' '2. 编辑设置' '3. IP 限制' '' '4. 启动' '5. 停止' '6. 重启' '7. 日志' '8. 删除此节点' '0. 返回'
    ask '请选择：' choice
    case "$choice" in
      0) return;;
      1) node_info; pause_menu;;
      2) node_settings_menu;;
      3) iplimit_menu;;
      4) start_service; echo '已启动'; pause_menu;;
      5) stop_service; echo '已停止'; pause_menu;;
      6) restart_service; echo '已重启'; pause_menu;;
      7) show_logs; pause_menu;;
      8) delete_selected_node; [[ -f "$node_root/settings" ]] || return 0;;
      *) echo '编号无效'; pause_menu;;
    esac
  done
  return 0
}
main() {
  case "${1:-}" in
    --version) echo "$VERSION"; return;;
    --help) echo 's-s：多节点中文菜单；--node 编号 --start/--stop/--restart：指定节点；--uninstall：卸载全部。'; return;;
  esac
  root_check
  node_context legacy
  if [[ "${1:-}" == --node ]]; then [[ $# -ge 3 ]] || fail '缺少节点编号或操作。'; node_context "$2"; shift 2; fi
  case "${1:-}" in
    --start) load_state; start_service; return;; --stop) stop_service; return;; --restart) load_state; restart_service; return;;
    --uninstall) uninstall_node; return;;
    ''|--menu) ;; *) fail "未知参数：$1";;
  esac
  install_menu
  local choice
  while true; do
    menu_screen
    printf 'Jack SS  %s\n\n' "$VERSION"
    printf '%s\n' '1. 新建节点' '2. 节点列表' '' '8. 卸载全部' '9. 更新' '0. 退出'
    ask '请选择：' choice
    case "$choice" in
      0) return;;
      1) add_node; pause_menu; current_required && node_menu;;
      2) select_node; if (( NODE_CHOSEN )); then node_menu; fi;;
      9) updates_menu;;
      8) uninstall_node;;
      *) echo '编号无效'; pause_menu;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
