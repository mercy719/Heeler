#!/bin/bash
# Heeler 电脑端远程桌面的会话入口：清残留 → 点亮屏幕 → 起 Sunshine 和 Moonlight Web → 打一行就绪 JSON，
# 然后等 stdin 心跳；stdin 关闭 / 心跳超时 / 收到 TERM、HUP、INT 都会把两个进程停干净。
# 用法：bash rc-session.sh start
# stdout 只出一行 JSON；口令和凭据不进 stdout、stderr 和日志（不开调试输出）。
set -u

DIR="$HOME/Library/Application Support/Heeler/remote-desktop"
SUN="$DIR/Sunshine.app/Contents/MacOS/Sunshine"
CONF="$DIR/sunshine.conf"
PLIST="$DIR/dev.heeler.rc.sunshine.plist"
WEBUI="$DIR/.webui-cred"          # Sunshine Web UI 的 user:password，只用于本机查接口
STATE="$DIR/pair-state.json"      # {"hostId":..,"appId":..}，rc-setup 写的
ML="$DIR/moonlight"
LABEL=dev.heeler.rc.sunshine
HPORT=51990            # Sunshine Web UI
WHOST=52100            # Moonlight Web
HB=${RC_HEARTBEAT_TIMEOUT:-45}
WORK="${TMPDIR:-/tmp}/heeler-rc-session.$$"
WPID=""
W=0 H=0

out() { printf '%s\n' "$1"; }
pj() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }   # 读 JSON 文件里的键
num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

cleanup() {
  trap - EXIT INT TERM HUP
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  pkill -f "$ML/web-server" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  i=0
  while [ $i -lt 100 ] && { pgrep -f "$ML/web-server" >/dev/null || pgrep -f "$SUN" >/dev/null; }; do
    sleep 0.1; i=$((i+1))
  done
  # bootout 之后还有残留就按绝对路径收掉（只碰本套件自己的进程）。
  pkill -f "$SUN" 2>/dev/null
  pkill -f "$ML/web-server" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

fail() { out "{\"ready\":false,\"error\":\"$1\",\"detail\":\"$2\"}"; exit 1; }

clear_leftovers() {
  pkill -f "$ML/web-server" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  i=0
  while [ $i -lt 50 ] && { pgrep -f "$ML/web-server" >/dev/null || pgrep -f "$SUN" >/dev/null; }; do
    sleep 0.1; i=$((i+1))
  done
  pkill -f "$SUN" 2>/dev/null
}

main_display() {   # 主显示器的逻辑分辨率（Sunshine 抓屏用的坐标）
  mkdir -p "$WORK"
  system_profiler SPDisplaysDataType -json > "$WORK/displays.json" 2>/dev/null
  i=0
  while [ $i -lt 8 ]; do
    if [ "$(pj "SPDisplaysDataType.0.spdisplays_ndrvs.$i.spdisplays_main" "$WORK/displays.json")" = spdisplays_yes ]; then
      r=$(pj "SPDisplaysDataType.0.spdisplays_ndrvs.$i.spdisplays_resolution" "$WORK/displays.json")
      W=$(num "$(printf '%s' "$r" | sed -n 's/^\([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1/p')")
      H=$(num "$(printf '%s' "$r" | sed -n 's/^\([0-9][0-9]*\) x \([0-9][0-9]*\).*/\2/p')")
      break
    fi
    i=$((i+1))
  done
}

screen_locked() {
  if ioreg -n Root -d1 2>/dev/null | grep -q 'CGSSessionScreenIsLocked"=Yes'; then echo true; else echo false; fi
}

start() {
  [ -x "$SUN" ] && [ -f "$CONF" ] && [ -f "$PLIST" ] && [ -x "$ML/web-server" ] && [ -f "$ML/config.json" ] \
    || fail notInstalled "run rc-setup install first"
  [ -s "$WEBUI" ] || fail notInstalled "missing Sunshine credentials; run rc-setup install"
  mkdir -p "$WORK"
  printf 'user = "%s"\n' "$(cat "$WEBUI")" > "$WORK/curlrc"   # 口令不进 argv
  chmod 600 "$WORK/curlrc"
  sunc() { curl -sk --max-time "${1}" -K "$WORK/curlrc" "${@:2}"; }

  clear_leftovers
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || fail noGuiSession "no Aqua session for this user"
  # Sunshine 在显示器睡着时起不来：先点亮（不需要密码，也不会解锁）。
  caffeinate -u -t 5 >/dev/null 2>&1 &
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || fail sunshineFailed "launchctl bootstrap failed"

  i=0
  while [ $i -lt 40 ]; do
    sunc 2 "https://127.0.0.1:$HPORT/api/openbot/setup" > "$WORK/setup.json"
    [ -s "$WORK/setup.json" ] && break
    i=$((i+1)); sleep 0.5
  done
  [ -s "$WORK/setup.json" ] || fail sunshineFailed "Sunshine setup endpoint did not answer in 20s"
  [ "$(pj guiSession "$WORK/setup.json")" = allowed ] || fail noGuiSession "Sunshine has no GUI session"
  if [ "$(pj screenRecording "$WORK/setup.json")" != allowed ] || \
     [ "$(pj accessibility "$WORK/setup.json")" != allowed ]; then
    fail needsPermission "grant Screen Recording and Accessibility to Sunshine.app"
  fi

  # 静态页按相对路径 "static" 找：必须在 moonlight 目录里启动，但 argv 仍用绝对路径给 pkill 认。
  ( cd "$ML" && exec nohup "$ML/web-server" --config-path "$ML/config.json" </dev/null >>"$ML/server.out.log" 2>&1 ) &
  WPID=$!
  i=0
  # 根路径是 404（静态页挂在 /stream.html），只认「有 HTTP 应答」。
  while [ $i -lt 40 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$WHOST/")" != 000 ] && break
    i=$((i+1)); sleep 0.5
  done
  [ $i -lt 40 ] || fail webServerFailed "web-server did not answer on 127.0.0.1:$WHOST"

  hid=$(pj hostId "$STATE")
  aid=$(pj appId "$STATE")
  [ -n "$hid" ] && [ -n "$aid" ] || fail notPaired "run rc-setup install to pair"
  [ -n "$(pj "hosts.$hid.pair_info.client_certificate" "$ML/data.json")" ] || fail notPaired "the host is not paired"

  main_display
  out "{\"ready\":true,\"port\":$WHOST,\"hostId\":$hid,\"appId\":$aid,\"width\":$W,\"height\":$H,\"locked\":$(screen_locked)}"

  # 心跳：每行一次 read；read 返回非零就是 EOF 或 HB 秒没来一行，交给 EXIT 清理。
  while IFS= read -r -t "$HB" _line; do :; done
}

case "${1:-}" in
  start) start ;;
  *) echo "usage: rc-session.sh start" >&2; exit 2 ;;
esac
