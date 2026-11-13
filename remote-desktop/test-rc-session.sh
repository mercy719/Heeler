#!/bin/bash
# rc-session.sh 的替身测试：PATH 前置假的 launchctl / caffeinate / ioreg / lsof，
# 不碰真的 launchd、屏幕和网络。跑法：bash remote-desktop/test-rc-session.sh
# 只覆盖 sill 一套引擎（假 SillHost 由假 launchctl 起停）。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/rc-session.sh"
T="${TMPDIR:-/tmp}/rc-session-test.$$"
mkdir -p "$T/bin" "$T/home"
FAILED=0
SESS_PID=""
trap 'kill $SESS_PID 2>/dev/null; rm -rf "$T"' EXIT

ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAILED=$((FAILED+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi }
# 测试自身也用系统自带的 plutil，别依赖 jq（CI 与用户 Mac 未必装）
jget() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

# ---- 替身 ----
# 逐行 printf 而不是 heredoc：Homebrew bash 5.3.15 解析「heredoc 内文含 8>&- 9>&-」会卡死（实测，
# rc-session.sh 写 plist 时也踩过同一个坑）。
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '# 只记事件并一律成功（真机 bootout 返回 0/3/113 都算已停）。'
  printf '%s\n' '# sill 的 label 例外：一个 label 只有一个 job，按 launchd 的语义模拟——bootstrap 先收掉已在跑的'
  printf '%s\n' '# 那个再起新的，bootout 收掉在跑的那个。收的时候按「可执行文件路径」找，和 launchd 一样不管'
  printf '%s\n' '# pidfile 里记的是谁；这样 pgrep / lsof / 收尾都有真的对象可看。'
  printf '%s\n' 'echo "$*" >> "$STUB_LOG"'
  printf '%s\n' 'sill_stop() {   # $1 = 可执行文件路径'
  printf '%s\n' '  [ -n "${1:-}" ] || return 0'
  printf '%s\n' '  pkill -TERM -f "$1" 2>/dev/null'
  printf '%s\n' '  i=0; while [ $i -lt 30 ] && pgrep -f "$1" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done'
  printf '%s\n' '  rm -f "${STUB_SILL_PIDFILE:-/nonexistent}"'
  printf '%s\n' '}'
  printf '%s\n' 'case "${1:-}" in'
  printf '%s\n' '  bootstrap)'
  printf '%s\n' '    exe=$(sed -n '"'"'s|.*<string>\(/.*/MacOS/SillHost\)</string>.*|\1|p'"'"' "${3:-}" 2>/dev/null | head -1)'
  printf '%s\n' '    [ -n "$exe" ] || exit 0'
  printf '%s\n' '    sill_stop "$exe"'
  printf '%s\n' '    # 8>&- 9>&-：真 launchd 起进程时不带调用者的 fd，而这个假 launchctl 是测试 shell 的子壳，'
  printf '%s\n' '    # 不关的话假 SillHost 会攥着会话的 stdin FIFO，测试里关掉写端也收不到 EOF。'
  printf '%s\n' '    nohup "$exe" >/dev/null 2>&1 8>&- 9>&- &'
  printf '%s\n' '    i=0; while [ $i -lt 50 ] && [ ! -s "${STUB_SILL_PIDFILE:-/nonexistent}" ]; do sleep 0.1; i=$((i+1)); done'
  printf '%s\n' '    ;;'
  printf '%s\n' '  bootout)'
  printf '%s\n' '    case "${2:-}" in'
  printf '%s\n' '      */dev.heeler.rc.sillhost) sill_stop "$D/SillHost.app/Contents/MacOS/SillHost" ;;'
  printf '%s\n' '    esac'
  printf '%s\n' '    ;;'
  printf '%s\n' 'esac'
  printf '%s\n' 'exit 0'
} > "$T/bin/launchctl"
cat > "$T/bin/lsof" <<'EOF'
#!/bin/bash
# lsof 替身：只为假 SillHost 自己的 pid 报一行监听；STUB_SILL_BIND 换成别的地址就是「越出回环」。
pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid=$a; prev=$a; done
[ -s "${STUB_SILL_PIDFILE:-/nonexistent}" ] && [ "$pid" = "$(cat "$STUB_SILL_PIDFILE")" ] || exit 0
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
printf 'SillHost %s duola 7u IPv4 0x0 0t0 TCP %s (LISTEN)\n' "$pid" "${STUB_SILL_BIND:-127.0.0.1:52345}"
EOF
cat > "$T/bin/caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate $*" >> "$STUB_LOG"
exit 0
EOF
cat > "$T/bin/ioreg" <<'EOF'
#!/bin/bash
echo "      \"IOConsoleUsers\" = ({\"CGSSessionScreenIsLocked\"=${STUB_LOCKED:-Yes}})"
EOF
cat > "$T/bin/pmset" <<'EOF'
#!/bin/bash
echo "pmset $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$T/bin/"*

# ---- 假安装目录 ----
export HOME="$T/home"
D="$HOME/Library/Application Support/Heeler/remote-desktop"
mkdir -p "$D"
# 旧版 Sunshine 留下的 plist：只为了确认 bootout 被叫到，脚本不该去读它
touch "$D/dev.heeler.rc.sunshine.plist"

export PATH="$T/bin:$PATH" STUB_LOG="$T/stub.log" RC_HEARTBEAT_TIMEOUT=2

wait_gone() {   # $1=pid $2=秒：等它自己退出
  local i=0 n=$(($2*10))
  while [ $i -lt $n ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
reap() {   # 自己起的子进程被杀后会留僵尸，kill -0 / pgrep 仍认；收掉再判断
  local i=0 st
  while [ $i -lt 50 ]; do
    st=$(ps -o state= -p "$1" 2>/dev/null | tr -d ' ')
    [ -z "$st" ] && return 0
    case "$st" in Z*) wait "$1" 2>/dev/null; return 0 ;; esac
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# ---- 假 SillHost：被假 launchctl 起，自己写 pidfile（记的是最后起的那个）、装着在监听 ----
SILLBIN="$D/SillHost.app/Contents/MacOS/SillHost"
SILLPID="$T/sill.pid"
mkdir -p "$(dirname "$SILLBIN")"
cat > "$SILLBIN" <<'EOF'
#!/bin/bash
echo $$ > "$STUB_SILL_PIDFILE"
trap 'exit 0' TERM   # 真 SillHost 收到 TERM 也先把窗口放回原位再退
while :; do sleep 0.1; done
EOF
chmod +x "$SILLBIN"
export STUB_SILL_PIDFILE="$SILLPID"
sill_running() { pgrep -f "$SILLBIN" >/dev/null 2>&1; }
no_sill_left() { ! sill_running; }

open_sill() {   # $1 = 名字；$2 = 额外环境（可选，如 STUB_SILL_BIND=0.0.0.0:1）
  rm -f "$SILLPID" "$T/$1.fifo"; mkfifo "$T/$1.fifo"
  : > "$T/$1.out"; : > "$T/$1.err"; : > "$STUB_LOG"
  # set -u 下不能写 env $2：没有 $2 时它会把测试 shell 本身打死。
  # 8>&- 9>&-：真会话是从 SSH 起的，不会有测试 shell 的 fd；不关的话会话的子进程（假 SillHost）
  # 会攥着上一条会话的 FIFO 写端，交接用例里旧会话就永远等不到 EOF。
  env "${2:-STUB_NONE=1}" /bin/bash "$SCRIPT" start < "$T/$1.fifo" > "$T/$1.out" 2> "$T/$1.err" 8>&- 9>&- &
  SESS_PID=$!
  exec 9> "$T/$1.fifo"
  local i=0
  while [ $i -lt 60 ] && [ ! -s "$T/$1.out" ]; do sleep 0.1; i=$((i+1)); done
}
close_stdin() { exec 9>&-; }

# ---- 1. 就绪 ----
open_sill ready
check "就绪：stdout 只有一行" '[ "$(grep -c . "$T/ready.out")" = 1 ]'
check "就绪：port 取自 lsof 的监听端口，locked 取自屏幕" \
  '[ "$(jget ready "$T/ready.out")" = true ] && [ "$(jget port "$T/ready.out")" = 52345 ] && \
   [ "$(jget locked "$T/ready.out")" = true ]'
check "就绪：plist 的 ProgramArguments 指向 .app 里的可执行文件、带三个参数" \
  'grep -q "<string>$SILLBIN</string>" "$D/dev.heeler.rc.sillhost.plist" && \
   grep -q "<string>--virtual-display</string>" "$D/dev.heeler.rc.sillhost.plist" && \
   grep -q "<string>--no-advertise</string>" "$D/dev.heeler.rc.sillhost.plist" && \
   grep -q "<string>--no-clipboard</string>" "$D/dev.heeler.rc.sillhost.plist" && \
   grep -q "<key>SILL_TEST_LOOPBACK</key><string>1</string>" "$D/dev.heeler.rc.sillhost.plist"'
check "就绪：拉起前先 bootout 旧版 Sunshine 的 label（它会占着硬件编码器）" \
  'grep -q "^bootout gui/[0-9]*/dev.heeler.rc.sunshine" "$STUB_LOG"'
check "就绪：caffeinate -u 点亮 + caffeinate -d -w 保亮" \
  'grep -q "^caffeinate -u" "$STUB_LOG" && grep -q "^caffeinate -d -w" "$STUB_LOG"'
check "就绪：假 SillHost 在跑" 'sill_running'

close_stdin; wait_gone $SESS_PID 5
check "EOF：会话退出、SillHost 被 bootout 后收到 TERM 退出" 'no_sill_left'
check "EOF：退出时熄屏重新锁上" 'grep -q "^pmset displaysleepnow" "$STUB_LOG"'
check "EOF：plist 里的 label 被 bootout" 'grep -q "^bootout gui/[0-9]*/dev.heeler.rc.sillhost" "$STUB_LOG"'

# ---- 1b. 连上时没锁（人在电脑前）：退出不熄屏 ----
STUB_LOCKED=No open_sill unlocked
close_stdin
check "没锁：退出后清理但不熄屏" 'wait_gone $SESS_PID 10 && no_sill_left && ! grep -q "^pmset" "$STUB_LOG"'

# ---- 2. 越出回环就报错：--no-advertise 的前提是不该有 0.0.0.0 或局域网地址 ----
: > "$T/sillbind.out"
STUB_SILL_BIND=0.0.0.0:52345 open_sill sillbind
check "越出回环：ready=false 且 error=sillFailed" \
  '[ "$(jget ready "$T/sillbind.out")" = false ] && [ "$(jget error "$T/sillbind.out")" = sillFailed ]'
close_stdin; wait_gone $SESS_PID 5; unset STUB_SILL_BIND

# ---- 3. 心跳超时（测试里 2 秒）：清理掉 SillHost ----
open_sill silltimeout
check "超时前：假 SillHost 在跑" 'sill_running'
check "超时：2 秒无心跳后退出并收掉 SillHost" 'wait_gone $SESS_PID 12 && no_sill_left'
close_stdin 2>/dev/null

# ---- 4. 心跳续命：每 1 秒一行，跨过 2 秒超时仍活着 ----
open_sill heartbeat
for i in 1 2 3; do echo tick >&9; sleep 1; done
check "心跳：3 秒里每 1 秒一行，会话仍活着" 'kill -0 $SESS_PID 2>/dev/null && sill_running'
close_stdin
check "心跳：关 stdin 后 10 秒内清理" 'wait_gone $SESS_PID 10 && no_sill_left'

# ---- 5. TERM：10 秒内清理 ----
open_sill term
check "TERM 前：假 SillHost 在跑" 'sill_running'
kill -TERM $SESS_PID 2>/dev/null
check "TERM：10 秒内退出且 SillHost 不在" 'wait_gone $SESS_PID 10 && no_sill_left'
close_stdin 2>/dev/null

# ---- 6. 启动前清残留（先确认上一节已完全退出，不然计数会撞车）----
close_stdin; wait_gone $SESS_PID 10
check "上一节收尾：没有残留进程" 'no_sill_left'
"$SILLBIN" & STALE=$!
sleep 0.4
open_sill leftover
check "残留：上一轮的 SillHost 已被收掉" 'reap $STALE && ! kill -0 $STALE 2>/dev/null'
check "残留：本轮只有一个 SillHost" '[ "$(pgrep -f "$SILLBIN" | wc -l | tr -d " ")" = 1 ] || pgrep -fl "$SILLBIN" >&2'
close_stdin; wait_gone $SESS_PID 10

# ---- 7. 交接：新会话起来后，旧会话迟到的收尾不动新会话的 SillHost ----
open_sill handoff_a; exec 8>&9; A_PID=$SESS_PID
open_sill handoff_b
exec 8>&-
# 等 A 退出的同时给 B 喂心跳：心跳超时只有 2 秒，干等会把 B 也等超时。
a_gone=1
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  reap "$A_PID" && { a_gone=0; break; }
  echo tick >&9; sleep 0.2
done
check "交接：旧会话退出" '[ $a_gone = 0 ]'
check "交接：旧会话不熄屏（新会话还在用）" '! grep -q "^pmset" "$STUB_LOG"'
check "交接：新会话和它的 SillHost 还在" 'kill -0 $SESS_PID 2>/dev/null && sill_running'
close_stdin
check "交接：新会话自己收尾仍清干净" 'reap $SESS_PID && no_sill_left'

# ---- 8. 引擎参数：只认 sill，别的名字（含旧的 sunshine）是用法错误 exit 2 ----
sunshine_status=0
/bin/bash "$SCRIPT" start sunshine < /dev/null > /dev/null 2>&1 || sunshine_status=$?
check "引擎 sunshine：exit 2，不开会话" '[ "$sunshine_status" = 2 ]'
unknown_status=0
/bin/bash "$SCRIPT" start moonlight < /dev/null > /dev/null 2>&1 || unknown_status=$?
check "引擎别的名字：exit 2" '[ "$unknown_status" = 2 ]'
check "不写引擎：默认走 sill，未安装时报 notInstalled" \
  'HOME="$T/home2" /bin/bash "$SCRIPT" start < /dev/null 2>&1 | grep -q "\"error\":\"notInstalled\""'

# ---- 9. 未安装：notInstalled ----
: > "$T/ni.out"
HOME="$T/home2" /bin/bash "$SCRIPT" start < /dev/null > "$T/ni.out" 2>&1
check "notInstalled：单行 JSON 且 error=notInstalled" \
  '[ "$(grep -c . "$T/ni.out")" = 1 ] && [ "$(jget ready "$T/ni.out")" = false ] && \
   [ "$(jget error "$T/ni.out")" = notInstalled ]'

echo
if [ $FAILED -eq 0 ]; then echo "全部通过"; else echo "$FAILED 项失败"; fi
[ $FAILED -eq 0 ]
