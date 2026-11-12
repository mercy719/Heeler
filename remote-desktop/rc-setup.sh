#!/bin/bash
# Heeler 电脑端远程桌面安装器：拷 Sunshine、装 Moonlight Web v3.0.1、写配置、生成凭据、完成配对。
# 用法：bash rc-setup.sh install [--archive <本地 tar.gz>] [--creds]  |  bash rc-setup.sh status
# 只写 ~/Library/Application Support/Heeler/remote-desktop/，不碰 OpenBot 的目录和 LaunchAgents。
# stdout 只出一行 JSON；口令 / 凭据 / PIN 不进 stdout、stderr 和日志（不开 set -x）。
set -u

DIR="$HOME/Library/Application Support/Heeler/remote-desktop"
SUN="$DIR/Sunshine.app/Contents/MacOS/Sunshine"
CONF="$DIR/sunshine.conf"
PLIST="$DIR/dev.heeler.rc.sunshine.plist"
WEBUI="$DIR/.webui-cred"          # Sunshine Web UI 口令（heeler:<随机>），只给本脚本查 setup / pin
MLPW="$DIR/.moonlight-cred"       # Moonlight Web 管理员口令；它写进 data.json 的哈希里
PAIR_STATE="$DIR/pair-state.json" # {"hostId":..,"appId":..}，rc-session 据此判断已配对
ML="$DIR/moonlight"
LABEL=dev.heeler.rc.sunshine
SPORT=51989   # Sunshine GameStream
HPORT=51990   # Sunshine Web UI（/api/openbot/setup、/api/pin）
WHOST=52100   # Moonlight Web
DEV=heeler-rc  # 配对设备名，用来在 Sunshine 的 pending 列表里认自己那条
URL="https://github.com/MrCreativ3001/moonlight-web-stream/releases/download/v3.0.1/moonlight-web-aarch64-apple-darwin.tar.gz"
SHA=6f28c814ddfe3ffdef22f1e2f49c5b96722967a4b192eb28dd41e38c76422720
WORK="${TMPDIR:-/tmp}/heeler-rc-setup.$$"
ARCHIVE="" FORCE=0 WPID="" SUN_STARTED=0 SETUP=""

out() { printf '%s\n' "$1"; }
get() { plutil -extract "$1" raw -o - - 2>/dev/null; }   # 从 stdin 的 JSON 取键（plutil 是系统自带）
# 口令从独立的 -K 文件读：curl 的 -K - 会把 stdin 整份吞成配置，和 --data-binary @- 打架。
sunc() { curl -sk --max-time "${1:-5}" -K "$WORK/curlrc" "${@:2}"; }
rand() { openssl rand -hex 12; }

release() {
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  WPID=""
  [ "$SUN_STARTED" = 1 ] && launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  SUN_STARTED=0
}
die() {
  out "{\"installed\":false,\"error\":\"$1\",\"detail\":\"$2\"}"
  release
  exit 1
}
trap 'rm -rf "$WORK"' EXIT

# Sunshine 的 TCC 授权只读地查系统库：两项都 auth_value=2 才算已授权，全靠人在电脑前点。
needs_permission() {
  [ "$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select count(*) from access where client='dev.lizardbyte.app.Sunshine' and auth_value=2
     and service in ('kTCCServiceScreenCapture','kTCCServiceAccessibility');" 2>/dev/null)" = 2 ] && return 1
  return 0
}

install_files() {   # 拷贝、下载、写配置：只在缺的时候动，已装即跳过
  mkdir -p "$DIR" && chmod 700 "$DIR" || die notInstalled "cannot create $DIR"
  if [ ! -x "$SUN" ]; then
    [ "$(uname -m)" = arm64 ] || die notInstalled "this runtime is arm64 only"
    src=/Applications/OpenBot.app/Contents/Resources/remote-desktop-runtime/darwin/arm64/Sunshine.app
    [ -d "$src" ] || die notInstalled "OpenBot.app with the Sunshine runtime is required"
    ditto "$src" "$DIR/Sunshine.app" || die notInstalled "copying Sunshine.app failed"
  fi
  if [ ! -x "$ML/web-server" ] || [ ! -d "$ML/static" ]; then
    mkdir -p "$ML" "$WORK/unpack"; tar_gz=$ARCHIVE
    if [ -z "$tar_gz" ]; then
      tar_gz="$WORK/mlweb.tar.gz"
      curl -fsSL --max-time 120 -o "$tar_gz" "$URL" || die downloadFailed "downloading moonlight web v3.0.1 failed"
      [ "$(shasum -a 256 "$tar_gz" | cut -d' ' -f1)" = "$SHA" ] || die shaMismatch "archive sha256 mismatch"
    fi
    tar xzf "$tar_gz" -C "$WORK/unpack" || die downloadFailed "cannot unpack archive"
    p="$WORK/unpack/package"
    [ -f "$p/web-server" ] && [ -d "$p/static" ] || die downloadFailed "unexpected archive layout"
    install -m 755 "$p/web-server" "$ML/web-server" && rm -rf "$ML/static" && cp -R "$p/static" "$ML/static" \
      || die downloadFailed "installing web-server failed"
  fi
  cat > "$CONF" <<EOF || die sunshineFailed "writing sunshine.conf failed"
sunshine_name = Heeler Remote Desktop
port = $SPORT
upnp = disabled
stream_audio = disabled
origin_web_ui_allowed = pc
address_family = ipv4
bind_address = 127.0.0.1
credentials_file = $DIR/sunshine-credentials.json
file_state = $DIR/sunshine-state.json
file_apps = $DIR/sunshine-apps.json
pkey = $DIR/sunshine-key.pem
cert = $DIR/sunshine-cert.pem
log_path = $DIR/sunshine.log
system_tray = disabled
min_log_level = info
EOF
  printf '{"env":{},"apps":[{"name":"Desktop","image_path":"desktop.png"}]}\n' > "$DIR/sunshine-apps.json"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$SUN</string><string>$CONF</string></array>
  <key>EnvironmentVariables</key><dict><key>OPENBOT_REMOTE_SETUP</key><string>1</string></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err.log</string>
</dict>
</plist>
EOF
  cat > "$ML/config.json" <<EOF
{ "data_storage": {"type":"json","path":"$ML/data.json","session_expiration_check_interval":{"secs":300,"nanos":0}},
  "webrtc": {"ice_servers":[],"ice_server_script":null,"port_range":null,"nat_1to1":null,"include_loopback_candidates":true},
  "web_server": {"bind_address":"127.0.0.1:$WHOST","certificate":null,"url_path_prefix":"","session_cookie_secure":false,
    "session_cookie_expiration":{"secs":86400,"nanos":0},"first_login_create_admin":true,
    "first_login_assign_global_hosts":true,"forwarded_header":null},
  "moonlight": {"default_http_port":$SPORT,"pair_device_name":"$DEV"},
  "log": {"level_filter":"Info","file_path":"$ML/server.log","dev_venator":false} }
EOF
  chmod 600 "$CONF" "$ML/config.json"
}

make_creds() {   # Sunshine 自带 --creds 生成哈希凭据；Moonlight 没口令就没法登录既有数据，一并重来
  if [ "$FORCE" = 1 ] || [ ! -s "$WEBUI" ] || [ ! -s "$DIR/sunshine-credentials.json" ]; then
    p=$(rand)
    "$SUN" "$CONF" --creds heeler "$p" >/dev/null 2>&1 || die sunshineFailed "Sunshine --creds failed"
    printf 'heeler:%s' "$p" > "$WEBUI"; chmod 600 "$WEBUI"
  fi
  printf 'user = "%s"\n' "$(cat "$WEBUI")" > "$WORK/curlrc"; chmod 600 "$WORK/curlrc"
  if [ ! -s "$MLPW" ]; then
    rm -f "$ML/data.json"
    rand > "$MLPW"; chmod 600 "$MLPW"
  fi
}

bring_up() {   # 桌面上起 Sunshine（显示器睡着时会挂住，先点亮），再起 web-server
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  # 上一轮刚 bootstrap 过时，bootout 之后进程还要几百毫秒才退；不等它退，新的一轮会和它抢端口。
  i=0
  while [ $i -lt 50 ] && pgrep -f "$SUN" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || die noGuiSession "no Aqua session for this user"
  caffeinate -u -t 5 >/dev/null 2>&1 &
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || die sunshineFailed "launchctl bootstrap failed"
  SUN_STARTED=1
  i=0
  while [ $i -lt 40 ]; do
    SETUP=$(sunc 2 "https://127.0.0.1:$HPORT/api/openbot/setup")
    [ -n "$SETUP" ] && break
    i=$((i+1)); sleep 0.5
  done
  [ -n "$SETUP" ] || die sunshineFailed "Sunshine setup endpoint did not answer in 20s"
  [ "$(printf '%s' "$SETUP" | get guiSession)" = allowed ] || die noGuiSession "Sunshine has no GUI session"
  # 静态页按相对路径 "static" 找：必须在 moonlight 目录里启动，但 argv 仍用绝对路径给 pkill 认。
  ( cd "$ML" && exec nohup "$ML/web-server" --config-path "$ML/config.json" </dev/null >>"$ML/server.out.log" 2>&1 ) &
  WPID=$!
  i=0
  # 建管理员之前所有 /api 都回 401，所以只认「有 HTTP 应答」；根页面是静态文件。
  while [ $i -lt 40 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$WHOST/")" != 000 ] && break
    i=$((i+1)); sleep 0.5
  done
  [ $i -lt 40 ] || die webServerFailed "web-server did not answer on 127.0.0.1:$WHOST"
}

pair() {   # 建管理员 → 设为默认用户（免登录）→ 加主机 → 未配对就配对
  W="http://127.0.0.1:$WHOST"
  printf '{"name":"heeler","password":"%s"}' "$(cat "$MLPW")" | \
    curl -sf --max-time 10 -c "$WORK/ck" -X POST "$W/api/login" -H 'Content-Type: application/json' --data-binary @- >/dev/null \
    || die webServerFailed "moonlight web login failed"
  uid=$(curl -sf --max-time 5 -b "$WORK/ck" "$W/api/user" | get id)
  printf '{"id":%s}' "$uid" | curl -sf --max-time 5 -b "$WORK/ck" -X PUT "$W/api/user/default" \
    -H 'Content-Type: application/json' --data-binary @- >/dev/null \
    || die webServerFailed "cannot set the default user"
  hj=$(curl -sf --max-time 5 "$W/api/hosts") || die webServerFailed "cannot list hosts"
  hid=$(printf '%s' "$hj" | get hosts.0.host_id)
  if [ -z "$hid" ]; then
    hid=$(printf '{"address":"127.0.0.1","http_port":%s}' "$SPORT" | \
      curl -sf --max-time 5 -b "$WORK/ck" -X POST "$W/api/host" -H 'Content-Type: application/json' --data-binary @- | get host.host_id)
  fi
  [ -n "$hid" ] || die pairFailed "cannot create the moonlight host"

  if [ "$(printf '%s' "$hj" | get hosts.0.paired)" != Paired ]; then
    nd="$WORK/pair.ndjson"; : > "$nd"
    printf '{"host_id":%s}' "$hid" | curl -sN --max-time 40 -b "$WORK/ck" -X POST "$W/api/pair" \
      -H 'Content-Type: application/json' --data-binary @- > "$nd" 2>/dev/null &
    pair_pid=$!
    pin="" i=0
    while [ $i -lt 40 ]; do
      pin=$(head -1 "$nd" | get Pin)
      [ -n "$pin" ] && break
      i=$((i+1)); sleep 0.5
    done
    [ -n "$pin" ] || { kill "$pair_pid" 2>/dev/null; die pairFailed "no PIN from moonlight web"; }
    sunc 5 "https://127.0.0.1:$HPORT/api/pin" > "$WORK/pending.json"
    pid_="" i=0
    while :; do
      nm=$(get "pairings.$i.name" < "$WORK/pending.json")
      [ -z "$nm" ] && break
      [ "$nm" = "$DEV" ] && pid_=$(get "pairings.$i.id" < "$WORK/pending.json")
      i=$((i+1))
    done
    [ -n "$pid_" ] || { kill "$pair_pid" 2>/dev/null; die pairFailed "no pending pairing named $DEV in Sunshine"; }
    printf '{"pairing_id":"%s","pin":"%s","name":"Heeler Remote Desktop"}' "$pid_" "$pin" | \
      sunc 10 -X POST -H 'Content-Type: application/json' --data-binary @- "https://127.0.0.1:$HPORT/api/pin" \
      | grep -q '"status":true' || { kill "$pair_pid" 2>/dev/null; die pairFailed "Sunshine rejected the PIN"; }
    wait "$pair_pid" 2>/dev/null
    sed -n 2p "$nd" | grep -q Paired || die pairFailed "moonlight web did not report Paired"
  fi

  aid=$(curl -sf --max-time 5 "$W/api/apps?host_id=$hid" | get apps.0.app_id)
  [ -n "$aid" ] || die pairFailed "no Desktop app on the moonlight host"
  printf '{"hostId":%s,"appId":%s}\n' "$hid" "$aid" > "$PAIR_STATE"; chmod 600 "$PAIR_STATE"
}

do_install() {
  mkdir -p "$WORK" || die notInstalled "cannot create a temp directory"
  install_files
  make_creds
  bring_up
  pair
  perm=false
  if [ "$(printf '%s' "$SETUP" | get screenRecording)" != allowed ] || \
     [ "$(printf '%s' "$SETUP" | get accessibility)" != allowed ]; then perm=true; fi
  release
  out "{\"installed\":true,\"needsPermission\":$perm}"
}

do_status() {
  if [ ! -x "$SUN" ] || [ ! -f "$CONF" ] || [ ! -x "$ML/web-server" ] || [ ! -f "$ML/config.json" ]; then
    out '{"installed":false,"error":"notInstalled","detail":"run rc-setup install first"}'
    exit 1
  fi
  perm=false; needs_permission && perm=true
  paired=false
  hid=$(plutil -extract hostId raw -o - "$PAIR_STATE" 2>/dev/null)
  if [ -n "$hid" ] && [ -n "$(plutil -extract "hosts.$hid.pair_info.client_certificate" raw -o - "$ML/data.json" 2>/dev/null)" ]; then
    paired=true
  fi
  out "{\"installed\":true,\"needsPermission\":$perm,\"paired\":$paired}"
}

case "${1:-}" in
  install)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --archive) [ $# -ge 2 ] || { echo "install: --archive needs a path" >&2; exit 2; }; ARCHIVE=$2; shift 2 ;;
        --creds) FORCE=1; shift ;;
        *) echo "install: unknown option $1" >&2; exit 2 ;;
      esac
    done
    do_install ;;
  status) do_status ;;
  *) echo "usage: rc-setup.sh install [--archive <tar.gz>] [--creds] | status" >&2; exit 2 ;;
esac
