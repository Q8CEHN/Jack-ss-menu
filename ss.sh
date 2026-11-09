#!/usr/bin/env bash
# JACK_SS_MENU - standalone Shadowsocks manager; never uses /etc/sing-box.
set -Eeuo pipefail
umask 077
ROOT=/etc/jack-ss
BIN=/opt/jack-ss/sing-box
UNIT=/etc/systemd/system/jack-ss.service
MENU=/usr/local/bin/s-s
LEGACY_MENU=/usr/local/bin/ss
VERSION=1.0.1
TMP=''
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"' EXIT
die() { echo "错误：$*" >&2; exit 1; }
ask() { read -r -p "$1" "$2" </dev/tty; }
root_check() { [[ $EUID -eq 0 ]] || die '请使用 root 或 sudo bash ss.sh。'; }
install_menu() {
  if [[ -e "$MENU" ]] && ! grep -q 'JACK_SS_MENU' "$MENU"; then die "$MENU 已有其他程序，停止覆盖。"; fi
  if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$(readlink -f "$MENU")" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" "$MENU"
  fi
  if [[ -f "$LEGACY_MENU" ]] && grep -q 'JACK_SS_MENU' "$LEGACY_MENU"; then rm -f "$LEGACY_MENU"; fi
}
deps() {
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux。'
  local missing=0 c
  for c in curl python3 tar sha256sum; do command -v "$c" >/dev/null || missing=1; done
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || missing=1
  if (( missing )); then
    if command -v apt-get >/dev/null; then
      apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates python3 tar coreutils
    elif command -v dnf >/dev/null; then
      dnf install -y curl ca-certificates python3 tar coreutils
    elif command -v yum >/dev/null; then
      yum install -y curl ca-certificates python3 tar coreutils
    else die '支持 Debian/Ubuntu 与使用 dnf/yum 的系统。'; fi
  fi
}
download_core() {
  local arch url digest name
  case $(uname -m) in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) die '目前支持 amd64 / arm64。';; esac
  TMP=$(mktemp -d)
  curl -fLSs --retry 2 --connect-timeout 15 --max-time 60 https://api.github.com/repos/SagerNet/sing-box/releases/latest -o "$TMP/release.json"
  python3 - "$TMP/release.json" "$arch" >"$TMP/asset" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1]))
a=next(a for a in r['assets'] if a['name'].endswith('-linux-'+sys.argv[2]+'.tar.gz'))
assert re.fullmatch(r'sha256:[0-9a-f]{64}',a.get('digest','')), '官方未提供 SHA256，停止下载'
assert a['browser_download_url'].startswith('https://github.com/SagerNet/sing-box/releases/download/')
print(a['browser_download_url']); print(a['digest'][7:]); print(a['name'][:-7]+'/sing-box')
PY
  { read -r url; read -r digest; read -r name; } <"$TMP/asset"
  curl -fLSs --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$TMP/core.tar.gz"
  printf '%s  %s\n' "$digest" "$TMP/core.tar.gz" | sha256sum -c -
  tar -xzf "$TMP/core.tar.gz" -C "$TMP" -- "$name"
  install -d -m 755 /opt/jack-ss
  install -m 755 "$TMP/$name" "$BIN.new"
  "$BIN.new" version
  if [[ -f "$ROOT/config.json" ]]; then "$BIN.new" check -c "$ROOT/config.json"; fi
  [[ ! -f "$BIN" ]] || cp -p "$BIN" "$BIN.previous"
  mv -f "$BIN.new" "$BIN"
  rm -rf -- "$TMP"; TMP=''
}
require_config() { [[ -f "$ROOT/config.json" && -x "$BIN" ]] || die '请先选择 1 安装节点。'; }
get_value() {
  python3 - "$ROOT/config.json" "$1" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['inbounds'][0][sys.argv[2]])
PY
}
port_busy() {
  python3 - "$1" <<'PY'
import socket,sys
for kind in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
    s=socket.socket(socket.AF_INET,kind)
    try: s.bind(('0.0.0.0',int(sys.argv[1])))
    except OSError: sys.exit(1)
    finally: s.close()
PY
}
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
input_port() {
  ask '监听端口 [8388]：' PORT; PORT=${PORT:-8388}
  valid_port "$PORT" || die '端口必须为 1–65535。'
  PORT=$((10#$PORT)); port_busy "$PORT" || die '该 TCP 或 UDP 端口已被占用，请换一个。'
}
public_host() {
  local guess=''
  guess=$(curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org || true)
  ask "公网 IP / 域名 [$guess]：" HOST; HOST=${HOST:-$guess}
  python3 - "$HOST" <<'PY'
import ipaddress,re,sys
h=sys.argv[1]
try: ipaddress.ip_address(h)
except ValueError:
    assert len(h)<=253 and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?',p) for p in h.split('.')), '公网地址无效'
PY
}
write_config() {
  python3 - "$ROOT/config.json.new" "$PORT" <<'PY'
import json,secrets,sys
c={'log':{'level':'info','timestamp':True},'inbounds':[{'type':'shadowsocks','tag':'ss-in','listen':'::','listen_port':int(sys.argv[2]),'method':'chacha20-ietf-poly1305','password':secrets.token_urlsafe(24)}],'outbounds':[{'type':'direct','tag':'direct'}]}
with open(sys.argv[1],'w') as f: json.dump(c,f,indent=2)
PY
  "$BIN" check -c "$ROOT/config.json.new"
  mv -f "$ROOT/config.json.new" "$ROOT/config.json"
}
node_info() {
  require_config
  python3 - "$ROOT" <<'PY'
import base64,json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); c=json.loads((p/'config.json').read_text())['inbounds'][0]
h=(p/'host').read_text().strip(); host='['+h+']' if ':' in h else h
u=base64.urlsafe_b64encode((c['method']+':'+c['password']).encode()).decode().rstrip('=')
info=f"服务器：{h}\n端口：{c['listen_port']}\n加密：{c['method']}\n密码：{c['password']}\n协议：TCP + UDP\n\nss://{u}@{host}:{c['listen_port']}#{urllib.parse.quote('Jack SS')}\n"
(p/'node.txt').write_text(info); (p/'node.txt').chmod(0o600)
print(info)
PY
  echo '节点资料：/etc/jack-ss/node.txt（仅 root 可读）'
}
firewall_add() {
  local port=$1
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    local proto
    for proto in tcp udp; do
      if ! ufw show added | grep -Eq "^ufw allow $port/$proto([[:space:]]|$)"; then
        ufw allow "$port/$proto" comment jack-ss
        printf 'ufw %s %s\n' "$port" "$proto" >>"$ROOT/firewall"
      fi
    done
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    # Only record rules that did not exist before this install.
    local proto
    for proto in tcp udp; do
      if ! firewall-cmd --permanent --query-port="$port/$proto" >/dev/null; then
        firewall-cmd --permanent --add-port="$port/$proto"
        printf 'firewalld-permanent %s %s\n' "$port" "$proto" >>"$ROOT/firewall"
      fi
      if ! firewall-cmd --query-port="$port/$proto" >/dev/null; then
        firewall-cmd --add-port="$port/$proto"
        printf 'firewalld-runtime %s %s\n' "$port" "$proto" >>"$ROOT/firewall"
      fi
    done
  else
    echo "请在现有防火墙中放行 TCP/UDP $port；脚本不会清空防火墙。"
  fi
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
install_node() {
  if [[ -f "$ROOT/config.json" ]]; then echo '已安装，保留现有节点资料。'; node_info; return; fi
  deps; input_port; public_host
  if [[ -e "$MENU" ]] && ! grep -q 'JACK_SS_MENU' "$MENU"; then die "$MENU 已有其他程序，停止覆盖。"; fi
  install -d -m 700 "$ROOT"
  download_core; write_config
  printf '%s\n' "$HOST" >"$ROOT/host"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=Jack Shadowsocks
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/opt/jack-ss/sing-box run -c /etc/jack-ss/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
UNIT
  install_menu
  systemctl daemon-reload; systemctl enable --now jack-ss
  sleep 1; systemctl is-active --quiet jack-ss || die '启动失败，请查看 journalctl -u jack-ss。'
  firewall_add "$PORT"
  echo "安装完成。阿里云等云服务器还需在安全组放行 TCP/UDP $PORT。"
  node_info
}
apply_change() {
  "$BIN" check -c "$ROOT/config.json.new"
  cp -p "$ROOT/config.json" "$ROOT/config.json.previous"
  mv -f "$ROOT/config.json.new" "$ROOT/config.json"
  if ! systemctl restart jack-ss || ! systemctl is-active --quiet jack-ss; then
    mv -f "$ROOT/config.json.previous" "$ROOT/config.json"
    systemctl restart jack-ss || true
    die '新配置启动失败，已恢复旧配置。'
  fi
  rm -f "$ROOT/config.json.previous"
}
change_node() {
  require_config
  local field=$1
  if [[ "$field" == port ]]; then input_port; else
    ask '输入新密码（留空自动生成）：' PASSWORD
  fi
  printf '%s' "${PASSWORD:-}" | python3 -c '
import json,secrets,sys
p,field,value=sys.argv[1:]; c=json.load(open(p)); i=c["inbounds"][0]
if field=="port": i["listen_port"]=int(value)
else: i["password"]=sys.stdin.read() or secrets.token_urlsafe(24)
with open(p+".new","w") as f: json.dump(c,f,indent=2)
' "$ROOT/config.json" "$field" "${PORT:-0}"
  apply_change
  if [[ "$field" == port ]]; then firewall_remove; firewall_add "$PORT"; echo "云安全组请同步放行 TCP/UDP $PORT。"; fi
  unset PASSWORD
  node_info
}
update_core() {
  require_config; download_core
  if ! systemctl restart jack-ss || ! systemctl is-active --quiet jack-ss; then
    [[ ! -f "$BIN.previous" ]] || mv -f "$BIN.previous" "$BIN"
    systemctl restart jack-ss || true
    die '升级启动失败，已尝试回退内核。'
  fi
  rm -f "$BIN.previous"; echo '内核升级完成。'
}
uninstall_node() {
  ask '删除本菜单的节点、密码、内核和菜单？输入 YES：' answer
  [[ "$answer" == YES ]] || return 0
  systemctl disable --now jack-ss 2>/dev/null || true
  firewall_remove
  rm -f "$UNIT"
  rm -rf -- "$ROOT" /opt/jack-ss
  if [[ -f "$MENU" ]] && grep -q 'JACK_SS_MENU' "$MENU"; then rm -f "$MENU"; fi
  if [[ -f "$LEGACY_MENU" ]] && grep -q 'JACK_SS_MENU' "$LEGACY_MENU"; then rm -f "$LEGACY_MENU"; fi
  systemctl daemon-reload; systemctl reset-failed jack-ss 2>/dev/null || true
  echo '已卸载；云安全组规则请自行删除。原有 sing-box、哪吒、SSH 和其他服务不受影响。'
  exit 0
}
main() {
  if (( $# )); then
    case "$1" in --menu) shift;; --version) echo "$VERSION"; return;; --help) echo 's-s：打开中文菜单；--version：查看版本；--help：查看帮助。'; return;;
      *) die "未知参数：$1。使用 s-s --help 查看帮助。";;
    esac
  fi
  root_check
  if [[ -f "$ROOT/config.json" ]]; then install_menu; fi
  while true; do
    echo; echo "====== Jack SS 中文管理 $VERSION ======"
    if [[ -f "$ROOT/config.json" ]]; then systemctl is-active jack-ss || true; else echo '尚未安装本菜单的节点'; fi
    printf '%s\n' '1. 安装 SS 节点' '2. 查看节点 / 复制链接' '3. 修改端口' '4. 修改密码' '5. 启动' '6. 停止' '7. 重启' '8. 查看最近日志' '9. 更新内核' '10. 修改公网 IP / 域名' '11. 卸载' '0. 退出'
    ask '请选择：' choice
    case "$choice" in
      1) install_node;; 2) node_info;; 3) change_node port;; 4) change_node password;;
      5) require_config; systemctl start jack-ss;; 6) require_config; systemctl stop jack-ss;;
      7) require_config; systemctl restart jack-ss;;
      8) journalctl -u jack-ss -n 60 --no-pager;; 9) update_core;;
      10) require_config; public_host; printf '%s\n' "$HOST" >"$ROOT/host"; node_info;;
      11) uninstall_node;; 0) return;; *) echo '请输入有效编号。';;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
