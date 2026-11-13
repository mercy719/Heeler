#!/bin/bash
# Heeler 电脑端远程桌面的会话入口：清残留 → 点亮屏幕 → 起 SillHost → 打一行就绪 JSON，
# 然后等 stdin 心跳；stdin 关闭 / 心跳超时 / 收到 TERM、HUP、INT 都会把它停干净。
# 用法：bash rc-session.sh start [sill]      （sill 是唯一引擎，不写也一样）
# sill 引擎起的是 SillHost.app 里的可执行文件（--virtual-display --no-advertise --no-clipboard，
# 环境 SILL_TEST_LOOPBACK=1），只监听 127.0.0.1；它占硬件编码器，所以起之前先清掉旧版留下的 Sunshine。
# stdout 只出一行 JSON；口令和凭据不进 stdout、stderr 和日志（不开调试输出）。
set -u

DIR="$HOME/Library/Application Support/Heeler/remote-desktop"
LABEL=dev.heeler.rc.sunshine   # 旧版 Sunshine 的 label，只用于清残留
HB=${RC_HEARTBEAT_TIMEOUT:-45}
WORK="${TMPDIR:-/tmp}/heeler-rc-session.$$"
WAS_LOCKED=false   # 连上那一刻锁着的，退出时熄屏让它立刻再锁上

# sill：预编译的 SillHost.app，固定 bundle id 和证书，TCC 授权才留得住
SILLAPP="$DIR/SillHost.app"
SILLBIN="$SILLAPP/Contents/MacOS/SillHost"
SLABEL=dev.heeler.rc.sillhost
SPLIST="$DIR/dev.heeler.rc.sillhost.plist"
SLOUT="$DIR/sillhost.out.log"
SLERR="$DIR/sillhost.err.log"

out() { printf '%s\n' "$1"; }

OWNER="$DIR/.session-owner"   # 当前会话的 PID：新会话起来后，旧会话迟到的收尾不许动新会话的进程
owns() { [ "$(cat "$OWNER" 2>/dev/null)" = "$$" ]; }

cleanup() {
  trap - EXIT INT TERM HUP
  owns || { rm -rf "$WORK"; return; }
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/$SLABEL" >/dev/null 2>&1
  i=0
  while [ $i -lt 100 ] && pgrep -f "$SILLBIN" >/dev/null 2>&1; do
    sleep 0.1; i=$((i+1))
  done
  # bootout 之后还有残留就按绝对路径收掉（只碰本套件自己的进程）；等待期间换了主人就不再动手。
  if owns; then
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
  # 旧版（Sunshine + Moonlight Web）留下的 job 可能还 loaded，它占着硬件编码器：bootout 一次。
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/$SLABEL" >/dev/null 2>&1
  # 上一轮的进程是 launchd 起的，bootout 之后还要几百毫秒才退；不等它退会抢端口。
  i=0
  while [ $i -lt 50 ] && pgrep -f "$SILLBIN" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
  pkill -f "$SILLBIN" 2>/dev/null
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
  [ -x "$SILLBIN" ] || fail notInstalled "the Host has no SillHost.app"
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

  out "{\"ready\":true,\"port\":$port,\"locked\":$(screen_locked)}"

  # 心跳：每行一次 read；read 返回非零就是 EOF 或 HB 秒没来一行，交给 EXIT 清理。
  while IFS= read -r -t "$HB" _line; do :; done
}

case "${1:-}" in
  start)
    shift
    case "${1:-sill}" in
      sill) ;;
      *) echo "rc-session.sh start: engine is sill, not $1" >&2; exit 2 ;;
    esac
    start_sill ;;
  *) echo "usage: rc-session.sh start [sill]" >&2; exit 2 ;;
esac
