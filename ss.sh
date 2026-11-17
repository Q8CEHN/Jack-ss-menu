#!/usr/bin/env bash
# JACK_SS_MENU — lightweight Shadowsocks manager.
set -Eeuo pipefail
umask 077
VERSION=3.0.0
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
  node_info
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
  printf '\n===== 更新 =====\n%s\n' '1. 更新菜单（获取新功能）' '2. 更新 SS 内核' '0. 返回'
  ask '请选择：' choice
  case "$choice" in 1) update_menu;; 2) update_core;; 0) return;; *) echo '编号无效';; esac
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
  is_systemd || fail 'IP 限制目前需要 systemd；节点其他功能不受影响。'
  if command -v nft >/dev/null && command -v ss >/dev/null && /usr/bin/python3 -c 'import netfilterqueue' 2>/dev/null; then return; fi
  command -v apt-get >/dev/null || fail 'IP 限制目前支持 Debian / Ubuntu，需软件源提供 python3-netfilterqueue。'
  apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=true update
  apt-cache show python3-netfilterqueue >/dev/null 2>&1 || fail '当前软件源没有 python3-netfilterqueue，未启用限制。'
  local dependency
  for dependency in nftables python3 python3-netfilterqueue iproute2; do
    if ! dpkg-query -W -f='${db:Status-Abbrev}' "$dependency" 2>/dev/null | grep -q '^ii'; then
      printf '%s\n' "$dependency" >>"$ROOT/ip-packages.direct"
    fi
  done
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u >"$ROOT/packages.before"
  # Installing a firewall utility must not start its example ruleset service.
  if [[ ! -e "$POLICY_FILE" ]]; then
    cat >"$POLICY_FILE" <<'POLICY'
#!/bin/sh
# JACK_SS_PACKAGE_GUARD
case "$1" in nftables*) exit 101;; *) exit 0;; esac
POLICY
    chmod 755 "$POLICY_FILE"; POLICY_OWN=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -o APT::Keep-Downloaded-Packages=false install -y --no-install-recommends nftables python3 python3-netfilterqueue iproute2
  record_packages_after
  cleanup; POLICY_OWN=0
}
write_ip_guard() {
  cat >"$ROOT/ip_guard.py.new" <<'JACK_IP_GUARD_PY' || return 1
#!/usr/bin/python3
"""JACK_SS_IP_GUARD: packet admission for this node only, no proxy decryption."""
import argparse
import collections
import ipaddress
import json
import os
import re
import select
import signal
import socket
import subprocess
import time
from pathlib import Path

TABLE = "jack_ss_iplimit"
QUEUE = 29083
IDLE = 300
COOLDOWN = 60


def nft(script):
    return subprocess.run(["nft", "-f", "-"], input=script, text=True,
                          capture_output=True, check=True, timeout=5)


def rules(port, udp, table=TABLE, queue=QUEUE):
    ports = [f"tcp sport {port}"]  # output responses to the node's clients
    if udp:
        ports.append(f"udp sport {port}")
    inputs = [p.replace("sport", "dport") for p in ports]
    lines = [f"add table inet {table}"]
    for family, kind in ((4, "ipv4_addr"), (6, "ipv6_addr")):
        for name, timeout in (("active", IDLE), ("banned", COOLDOWN)):
            lines.append(f"add set inet {table} {name}{family} "
                         f"{{ type {kind}; flags dynamic,timeout; timeout {timeout}s; size 65536; }}")
    lines += [f"add chain inet {table} input {{ type filter hook input priority -10; policy accept; }}",
              f"add chain inet {table} output {{ type filter hook output priority -10; policy accept; }}",
              f"add chain inet {table} admit"]
    for p in inputs:
        lines.append(f"add rule inet {table} input {p} jump admit")
    for version, proto in ((4, "ip"), (6, "ip6")):
        lines.append(f"add rule inet {table} admit {proto} saddr @banned{version} drop")
        lines.append(f"add rule inet {table} admit {proto} saddr @active{version} "
                     f"update @active{version} {{ {proto} saddr timeout {IDLE}s }} return")
        for p in ports:
            lines.append(f"add rule inet {table} output {p} {proto} daddr @banned{version} drop")
            lines.append(f"add rule inet {table} output {p} {proto} daddr @active{version} "
                         f"update @active{version} {{ {proto} daddr timeout {IDLE}s }} return")
    # No bypass: an unavailable controller must not silently remove the limit.
    lines.append(f"add rule inet {table} admit queue num {queue}")
    for p in ports:
        lines.append(f"add rule inet {table} output {p} drop")
    return "\n".join(lines) + "\n"


def packet_source(payload):
    if not payload:
        raise ValueError("empty packet")
    version = payload[0] >> 4
    if version == 4 and len(payload) >= 20:
        return str(ipaddress.ip_address(payload[12:16]))
    if version == 6 and len(payload) >= 40:
        return str(ipaddress.ip_address(payload[8:24]))
    raise ValueError("invalid IP packet")


class Admission:
    def __init__(self, limit, port, status, table=TABLE):
        self.limit, self.port, self.status = limit, port, Path(status)
        self.table = table
        self.active = collections.OrderedDict()
        self.banned = {}

    def publish(self):
        status = {"limit": self.limit, "active": list(self.active),
                  "banned": list(self.banned), "updated": time.time(),
                  "idle_seconds": IDLE, "cooldown_seconds": COOLDOWN}
        tmp = self.status.with_suffix(".new")
        tmp.write_text(json.dumps(status))
        tmp.replace(self.status)

    def sync(self):
        data = subprocess.run(["nft", "-j", "list", "table", "inet", self.table],
                              capture_output=True, text=True, check=True, timeout=5)
        live, banned = set(), set()
        for obj in json.loads(data.stdout)["nftables"]:
            entry = obj.get("set", {})
            if not entry.get("name", "").startswith(("active", "banned")):
                continue
            target = live if entry["name"].startswith("active") else banned
            for elem in entry.get("elem", []):
                if isinstance(elem, str):
                    target.add(elem)
                elif isinstance(elem, dict):
                    value = elem.get("elem", elem).get("val")
                    if isinstance(value, str):
                        target.add(value)
        self.active = collections.OrderedDict((ip, t) for ip, t in self.active.items() if ip in live)
        self.banned = {ip: t for ip, t in self.banned.items() if ip in banned}
        self.publish()

    def admit(self, ip):
        if ip in self.banned:
            return False
        if ip in self.active:
            return True
        # A slot may have expired since the periodic status refresh.
        self.sync()
        version = ipaddress.ip_address(ip).version
        victim = next(reversed(self.active), None) if len(self.active) >= self.limit else None
        script = []
        if victim:
            family = ipaddress.ip_address(victim).version
            script += [f"delete element inet {self.table} active{family} {{ {victim} }}",
                       f"add element inet {self.table} banned{family} {{ {victim} timeout {COOLDOWN}s }}"]
        script.append(f"add element inet {self.table} active{version} {{ {ip} timeout {IDLE}s }}")
        # One atomic kernel transaction: remove victim before accepting newcomer.
        nft("\n".join(script) + "\n")
        if victim:
            del self.active[victim]
            self.banned[victim] = time.monotonic()
            # Terminate only sockets on this node's listening port.
            try:
                subprocess.run(["ss", "-K", "dst", victim, "sport", "=", f":{self.port}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                # Firewall denies both directions even when socket destroy is unsupported.
                pass
        self.active[ip] = time.monotonic()
        self.publish()
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--udp", action="store_true")
    parser.add_argument("--table", default=TABLE)
    parser.add_argument("--queue", type=int, default=QUEUE)
    parser.add_argument("--status", default="/run/jack-ss-iplimit/status.json")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.limit <= 4096:
        parser.error("invalid port or limit")
    if not re.fullmatch(r"jack_ss_iplimit(?:_n[1-9][0-9]{0,4})?", args.table) or not 1 <= args.queue <= 65535:
        parser.error("invalid node table or queue")
    from netfilterqueue import NetfilterQueue
    os.umask(0o077)
    Path(args.status).parent.mkdir(parents=True, exist_ok=True)
    guard = Admission(args.limit, args.port, args.status, args.table)
    queue = NetfilterQueue()
    running = True
    failed = False

    def receive(packet):
        nonlocal running, failed
        try:
            ip = packet_source(packet.get_payload())
            allowed = guard.admit(ip)
        except Exception as exc:
            print(f"IP admission failed: {exc}", flush=True)
            packet.drop()
            # Callback exceptions can be swallowed by the C binding. Exit the loop.
            running = False
            failed = True
            return
        if allowed:
            packet.accept()
        else:
            packet.drop()

    # Bind before installing packet rules; a queue conflict leaves other rules alone.
    queue.bind(args.queue, receive, max_len=4096)
    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Replace only our own named table. Keep an existing table on startup failure.
    existing = subprocess.run(["nft", "list", "table", "inet", args.table],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    nft((f"delete table inet {args.table}\n" if existing else "") + rules(args.port, args.udp, args.table, args.queue))
    guard.publish()
    # Type=notify starts the SS service only after the kernel rules are installed.
    notify = os.environ.get("NOTIFY_SOCKET")
    if notify:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect("\0" + notify[1:] if notify.startswith("@") else notify)
            sock.sendall(b"READY=1")
    try:
        next_sync = time.monotonic() + 1
        while running:
            if select.select([queue.get_fd()], [], [], 1)[0]:
                queue.run(block=False)
            if time.monotonic() >= next_sync:
                guard.sync()
                next_sync = time.monotonic() + 1
    finally:
        queue.unbind()
        Path(args.status).unlink(missing_ok=True)
        # Leave rules fail-closed until restart or an explicit disable operation.
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
JACK_IP_GUARD_PY
  chmod 700 "$ROOT/ip_guard.py.new" || return 1
  mv -f "$ROOT/ip_guard.py.new" "$ROOT/ip_guard.py"
}
iplimit_apply() {
  local limit udp=''
  read -r limit <"$ROOT/ip-limit"
  [[ "$limit" =~ ^[0-9]{1,4}$ ]] && (( limit >= 1 && limit <= 4096 )) || fail 'IP 限制配置无效。'
  load_state
  [[ "$MODE" != tcp_and_udp ]] || udp='--udp'
  write_ip_guard || return 1
  cat >"$SYSTEMD_DIR/$GUARD.service" <<UNIT || return 1
[Unit]
Description=Jack SS IP limit
After=network.target
Before=$SERVICE.service
PartOf=$SERVICE.service
[Service]
Type=notify
NotifyAccess=main
ExecStart=/usr/bin/python3 $ROOT/ip_guard.py --port $LOCAL_PORT --limit $limit $udp --table $TABLE --queue $QUEUE --status /run/$GUARD/status.json
Restart=on-failure
RestartSec=2
TimeoutStartSec=15
RuntimeDirectory=$GUARD
RuntimeDirectoryMode=0700
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run/$GUARD
CapabilityBoundingSet=CAP_NET_ADMIN
UNIT
  install -d -m 755 "$SYSTEMD_DIR/$SERVICE.service.d" || return 1
  cat >"$SYSTEMD_DIR/$SERVICE.service.d/iplimit.conf" <<UNIT || return 1
[Unit]
Requires=$GUARD.service
After=$GUARD.service
UNIT
  systemctl daemon-reload || return 1
  systemctl restart "$GUARD" || return 1
  systemctl is-active --quiet "$GUARD"
}
iplimit_disable() {
  if is_systemd; then
    systemctl stop "$GUARD" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$GUARD"; then echo 'IP 限制服务无法停止。' >&2; return 1; fi
  fi
  # Remove only the node's own table; never flush the host firewall.
  if command -v nft >/dev/null && nft list table inet "$TABLE" >/dev/null 2>&1; then
    nft delete table inet "$TABLE" || return 1
  fi
  rm -f "$SYSTEMD_DIR/$GUARD.service" "$SYSTEMD_DIR/$SERVICE.service.d/iplimit.conf"
  rmdir "$SYSTEMD_DIR/$SERVICE.service.d" 2>/dev/null || true
  rm -f "$ROOT/ip-limit" "$ROOT/ip_guard.py" "$ROOT/ip_guard.py.new"
  if is_systemd; then systemctl daemon-reload; systemctl reset-failed "$GUARD" >/dev/null 2>&1 || true; fi
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
  if ! systemctl is-active --quiet "$GUARD"; then echo '限制服务未运行，请启动节点或重新设置。'; return; fi
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
  local choice value previous=''
  while true; do
    printf '\n===== %s · IP 数量限制 =====\n' "$NAME"
    iplimit_status
    printf '%s\n' '按服务器看到的来源 IP 计数；同一公网 IP 合并，IPv4/IPv6 分别计数。' '5 分钟无流量释放名额；被替换 IP 等待 60 秒，避免反复互踢。' '按端口来源流量识别，不代表已通过 SS 密码验证。' '1. 设置 / 修改上限' '2. 查看当前 IP' '3. 清空接入顺序与等待记录' '4. 关闭限制' '0. 返回'
    ask '请选择：' choice
    case "$choice" in
      1)
        ask '最多允许几个 IP？[1–4096，0 关闭]：' value
        [[ "$value" =~ ^[0-9]{1,4}$ ]] && (( 10#$value <= 4096 )) || { echo '请输入 0–4096。'; continue; }
        value=$((10#$value))
        if (( value == 0 )); then iplimit_disable; echo '已关闭限制'; continue; fi
        iplimit_install_deps
        previous=''; [[ ! -f "$ROOT/ip-limit" ]] || read -r previous <"$ROOT/ip-limit"
        printf '%s\n' "$value" >"$ROOT/ip-limit"
        if iplimit_apply; then echo '设置完成'; else
          if [[ -n "$previous" ]]; then
            printf '%s\n' "$previous" >"$ROOT/ip-limit"
            iplimit_apply || fail '限制服务无法恢复，请关闭限制或查看 journalctl -u jack-ss-iplimit。'
          else iplimit_disable; fi
          echo '启用失败，已恢复原设置。'
        fi;;
      2) iplimit_status;;
      3) if [[ -f "$ROOT/ip-limit" ]]; then iplimit_apply; echo '已清空，新流量重新排序。'; else echo '尚未启用限制。'; fi;;
      4) iplimit_disable; echo '已关闭限制';;
      0) return;; *) echo '编号无效';;
    esac
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
  printf '\n%-6s %-16s %-8s %-10s %s\n' '编号' '名称' '端口' '状态' 'IP 上限'
  while IFS= read -r id; do
    number=$((number + 1))
    (
      node_context "$id"; load_state
      local state=已停止 limit=不限
      healthy && state=运行中
      [[ ! -f "$ROOT/ip-limit" ]] || read -r limit <"$ROOT/ip-limit"
      printf '%-6s %-16s %-8s %-10s %s\n' "$number" "$NAME" "$LOCAL_PORT" "$state" "$limit"
    )
  done < <(node_ids)
  (( number )) || echo '暂无节点。'
  return 0
}
select_node() {
  local answer index
  local -a ids=()
  mapfile -t ids < <(node_ids)
  list_nodes
  (( ${#ids[@]} )) || return 0
  ask '选择节点编号（0 返回）：' answer
  [[ "$answer" =~ ^[0-9]{1,5}$ ]] || { echo '编号无效'; return 0; }
  index=$((10#$answer))
  (( index )) || return 0
  (( index <= ${#ids[@]} )) || { echo '编号无效'; return 0; }
  node_context "${ids[index-1]}"; load_state
  echo "当前节点：$NAME（$LOCAL_PORT）"
  node_info
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
  local -a ids=(); mapfile -t ids < <(node_ids)
  if (( ${#ids[@]} )); then node_context "${ids[0]}"; fi
  local choice current
  while true; do
    current=未选择
    if [[ -f "$ROOT/settings" ]]; then load_state; current="$NAME（$LOCAL_PORT）"; fi
    printf '\n===== Jack SS 多节点版 %s =====\n当前节点：%s\n' "$VERSION" "$current"
    printf '%s\n' '1. 新建节点 / 旧版迁移' '2. 节点列表 / 切换节点' '3. 修改当前节点端口' '4. 修改当前节点密码' '5. 启动当前节点' '6. 停止当前节点' '7. 重启当前节点' '8. 查看当前节点日志' '9. 更新菜单 / 内核' '10. 修改当前节点公网地址' '11. 卸载全部节点及本项目' '12. 当前节点 TCP / UDP 设置' '13. 当前节点 IP 数量限制' '14. 删除当前节点' '15. 修改当前节点名称' '0. 退出'
    ask '请选择：' choice
    case "$choice" in
      0) return;; 1) add_node;; 2) select_node;; 9) updates_menu;; 11) uninstall_node;;
      3|4|5|6|7|8|10|12|13|14|15)
        current_required || continue
        case "$choice" in
          3) change_settings ports;; 4) change_settings password;; 5) load_state; start_service;;
          6) stop_service;; 7) load_state; restart_service;; 8) show_logs;; 10) change_settings address;;
          12) change_settings mode;; 13) iplimit_menu;; 14) delete_selected_node;; 15) change_settings name;;
        esac;;
      *) echo '编号无效';;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
