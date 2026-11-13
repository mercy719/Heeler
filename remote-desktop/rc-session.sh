#!/bin/bash
# Heeler 电脑端远程桌面的会话入口：清残留 → 点亮屏幕 → 起 Sunshine 和 Moonlight Web → 打一行就绪 JSON，
# 然后等 stdin 心跳；stdin 关闭 / 心跳超时 / 收到 TERM、HUP、INT 都会把两个进程停干净。
# 用法：bash rc-session.sh start [sunshine|sill]     （默认 sunshine，也可用 RC_ENGINE=sill 指定）
# sill 引擎起的是 SillHost.app 里的可执行文件（--virtual-display --no-advertise --no-clipboard，
# 环境 SILL_TEST_LOOPBACK=1），只监听 127.0.0.1；两套都占硬件编码器，所以起哪套都先清掉另一套。
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
WAS_LOCKED=false   # 连上那一刻锁着的，退出时熄屏让它立刻再锁上
W=0 H=0
ENGINE=sunshine

# sill：预编译的 SillHost.app，固定 bundle id 和证书，TCC 授权才留得住
SILLAPP="$DIR/SillHost.app"
SILLBIN="$SILLAPP/Contents/MacOS/SillHost"
SLABEL=dev.heeler.rc.sillhost
SPLIST="$DIR/dev.heeler.rc.sillhost.plist"
SLOUT="$DIR/sillhost.out.log"
SLERR="$DIR/sillhost.err.log"

out() { printf '%s\n' "$1"; }
pj() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }   # 读 JSON 文件里的键
num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

OWNER="$DIR/.session-owner"   # 当前会话的 PID：新会话起来后，旧会话迟到的收尾不许动新会话的进程
owns() { [ "$(cat "$OWNER" 2>/dev/null)" = "$$" ]; }

cleanup() {
  trap - EXIT INT TERM HUP
  owns || { rm -rf "$WORK"; return; }
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  pkill -f "$ML/web-server" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/$SLABEL" >/dev/null 2>&1
  i=0
  while [ $i -lt 100 ] && { pgrep -f "$ML/web-server" >/dev/null || pgrep -f "$SUN" >/dev/null || pgrep -f "$SILLBIN" >/dev/null; }; do
    sleep 0.1; i=$((i+1))
  done
  # bootout 之后还有残留就按绝对路径收掉（只碰本套件自己的进程）；等待期间换了主人就不再动手。
  if owns; then
    pkill -f "$SUN" 2>/dev/null
    pkill -f "$ML/web-server" 2>/dev/null
    # SillHost 收到 TERM 会先把串流的窗口放回原位（HostShutdown），所以先等它自己退，再兜底。
    i=0
    while [ $i -lt 100 ] && pgrep -f "$SILLBIN" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
    pkill -f "$SILLBIN" 2>/dev/null
    rm -f "$OWNER"
    # 远程期间可能解了锁：熄屏，配合「熄屏后立即要求密码」就是马上锁上。本来没锁的（人在电脑前）不动。
    [ "$WAS_LOCKED" = true ] && pmset displaysleepnow >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

fail() { out "{\"ready\":false,\"error\":\"$1\",\"detail\":\"$2\"}"; exit 1; }

clear_leftovers() {
  pkill -f "$ML/web-server" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/$SLABEL" >/dev/null 2>&1
  # 上一轮的进程是 launchd 起的，bootout 之后还要几百毫秒才退；不等它退会抢端口。
  i=0
  while [ $i -lt 50 ] && { pgrep -f "$SUN" >/dev/null 2>&1 || pgrep -f "$SILLBIN" >/dev/null 2>&1; }; do sleep 0.1; i=$((i+1)); done
  pkill -f "$SUN" 2>/dev/null
  i=0
  while [ $i -lt 50 ] && pgrep -f "$ML/web-server" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
  pkill -f "$SILLBIN" 2>/dev/null
}

main_display() {   # 主显示器的逻辑分辨率（Sunshine 抓屏用的坐标）
  mkdir -p "$WORK"
  system_profiler SPDisplaysDataType -json > "$WORK/displays.json" 2>/dev/null
  i=0
  while [ $i -lt 8 ]; do
    if [ "$(pj "SPDisplaysDataType.0.spdisplays_ndrvs.$i.spdisplays_main" "$WORK/displays.json")" = spdisplays_yes ]; then
      r=$(pj "SPDisplaysDataType.0.spdisplays_ndrvs.$i.spdisplays_resolution" "$WORK/displays.json")
      # macOS 26/27 换成了带下划线的键名（实测 27.0.1）；两个都认，免得宽高读成 0。
      [ -n "$r" ] || r=$(pj "SPDisplaysDataType.0.spdisplays_ndrvs.$i._spdisplays_resolution" "$WORK/displays.json")
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

# 会话期间屏幕不许睡、也不许显示器睡着：sill 见输入会唤醒显示器但不保持常亮（文档说的），
# 虚拟显示器在睡着时 destroy 会残留（cn 实测），两边都要 caffeinate -d。脚本退出它跟着退。
wake_and_keep_awake() {
  caffeinate -u -t 5 >/dev/null 2>&1 &
  caffeinate -d -w $$ >/dev/null 2>&1 &
}

start_sill() {
  [ -x "$SILLBIN" ] || fail notInstalled "run rc-setup install first (no SillHost.app)"
  mkdir -p "$WORK"
  clear_leftovers
  printf '%s\n' "$$" > "$OWNER"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || fail noGuiSession "no Aqua session for this user"
  WAS_LOCKED=$(screen_locked)
  wake_and_keep_awake

  # plist 的 ProgramArguments 直接指向 .app 里的可执行文件：TCC 授权才记在 SillHost.app 自己名下。
  # 用 printf 逐行写而不是 heredoc：Homebrew bash 5.3 遇到多行 XML heredoc 会卡死（2026-11-13 实测）。
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '  <key>Label</key><string>%s</string>\n' "$SLABEL"
    printf '  <key>ProgramArguments</key><array>\n    <string>%s</string><string>--virtual-display</string>\n' "$SILLBIN"
    printf '%s\n' '    <string>--no-advertise</string><string>--no-clipboard</string></array>'
    printf '%s\n' '  <key>EnvironmentVariables</key><dict><key>SILL_TEST_LOOPBACK</key><string>1</string></dict>'
    printf '%s\n' '  <key>LimitLoadToSessionType</key><string>Aqua</string>'
    printf '%s\n' '  <key>ProcessType</key><string>Interactive</string>'
    printf '%s\n' '  <key>RunAtLoad</key><true/>'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "$SLOUT"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$SLERR"
    printf '%s\n' '</dict>' '</plist>'
  } > "$SPLIST" || fail sillFailed "writing $SPLIST failed"
  chmod 600 "$SPLIST"
  launchctl bootstrap "gui/$(id -u)" "$SPLIST" >/dev/null 2>&1 || fail sillFailed "launchctl bootstrap failed"

  # 就绪 = 读到监听端口。端口是系统随机分的，CLI 不打印（它靠 Bonjour 解析），所以从 lsof 读。
  port=0
  i=0
  while [ $i -lt 100 ]; do
    for pid in $(pgrep -f "$SILLBIN" 2>/dev/null); do
      p=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { n = split($9, a, ":"); print a[n]; exit }')
      [ -n "$p" ] && { port=$p; break; }
    done
    [ "$port" != 0 ] && break
    pgrep -f "$SILLBIN" >/dev/null 2>&1 || break   # 进程根本没起来，别空等
    i=$((i+1)); sleep 0.2
  done
  [ "$port" != 0 ] || fail sillFailed "SillHost did not listen in 20s (see $SLERR)"
  # 只认回环：--no-advertise 加了 SILL_TEST_LOOPBACK=1，别的地址一个都不该有。
  for pid in $(pgrep -f "$SILLBIN" 2>/dev/null); do
    bad=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 && $9 !~ /^127\.0\.0\.1:/ { print $9 }')
    [ -n "$bad" ] && fail sillFailed "SillHost listens beyond loopback: $bad"
  done

  # Sunshine 专用的字段对 sill 无意义，按任务书全填 0；手机端只看 port。
  out "{\"ready\":true,\"port\":$port,\"hostId\":0,\"appId\":0,\"width\":0,\"height\":0,\"locked\":$(screen_locked)}"

  # 心跳：每行一次 read；read 返回非零就是 EOF 或 HB 秒没来一行，交给 EXIT 清理。
  while IFS= read -r -t "$HB" _line; do :; done
}

start() {
  if [ "$ENGINE" = sill ]; then start_sill; return; fi
  [ -x "$SUN" ] && [ -f "$CONF" ] && [ -f "$PLIST" ] && [ -x "$ML/web-server" ] && [ -f "$ML/config.json" ] \
    || fail notInstalled "run rc-setup install first"
  [ -s "$WEBUI" ] || fail notInstalled "missing Sunshine credentials; run rc-setup install"
  mkdir -p "$WORK"
  printf 'user = "%s"\n' "$(cat "$WEBUI")" > "$WORK/curlrc"   # 口令不进 argv
  chmod 600 "$WORK/curlrc"
  sunc() { curl -sk --max-time "${1}" -K "$WORK/curlrc" "${@:2}"; }

  clear_leftovers
  printf '%s\n' "$$" > "$OWNER"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || fail noGuiSession "no Aqua session for this user"
  WAS_LOCKED=$(screen_locked)
  # Sunshine 在显示器睡着时起不来：先点亮（不需要密码，也不会解锁）。
  caffeinate -u -t 5 >/dev/null 2>&1 &
  # 会话期间屏幕不许睡：Sunshine 每次开流都要先从屏幕拿一帧，屏幕睡着就一直卡住（实测 11-13）。脚本退出它跟着退。
  caffeinate -d -w $$ >/dev/null 2>&1 &
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
  start)
    shift
    case "${1:-${RC_ENGINE:-sunshine}}" in
      sunshine|sill) ENGINE="${1:-${RC_ENGINE:-sunshine}}" ;;
      *) echo "rc-session.sh start: engine is sunshine or sill, not $1" >&2; exit 2 ;;
    esac
    start ;;
  *) echo "usage: rc-session.sh start [sunshine|sill]" >&2; exit 2 ;;
esac
