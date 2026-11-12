#!/bin/bash
# rc-session.sh 的替身测试：PATH 前置假的 launchctl / caffeinate / curl / system_profiler / ioreg，
# 不碰真的 launchd、屏幕和网络。跑法：bash remote-desktop/test-rc-session.sh
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
cat > "$T/bin/launchctl" <<'EOF'
#!/bin/bash
# 只记事件并一律成功（真机 bootout 返回 0/3/113 都算已停）
echo "$*" >> "$STUB_LOG"
exit 0
EOF
cat > "$T/bin/caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate $*" >> "$STUB_LOG"
exit 0
EOF
cat > "$T/bin/system_profiler" <<'EOF'
#!/bin/bash
echo '{"SPDisplaysDataType":[{"spdisplays_ndrvs":[
 {"_name":"x","spdisplays_resolution":"2560 x 1440 @ 120.00Hz"},
 {"_name":"main","spdisplays_main":"spdisplays_yes","spdisplays_resolution":"1440 x 900 @ 60.00Hz"}]}]}'
EOF
cat > "$T/bin/ioreg" <<'EOF'
#!/bin/bash
echo '      "IOConsoleUsers" = ({"CGSSessionScreenIsLocked"=Yes})'
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
url="" fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-K) shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    --max-time) shift 2 ;;
    *) url=$1; shift ;;
  esac
done
echo "curl $url" >> "$STUB_LOG"
case "$url" in
  */api/openbot/setup) printf '%s' "$STUB_SETUP" ;;
  *) [ -n "$fmt" ] && printf '404' ;;   # 任意 HTTP 应答 = web-server 已就绪
esac
exit 0
EOF
chmod +x "$T/bin/"*

# ---- 假安装目录 ----
export HOME="$T/home"
D="$HOME/Library/Application Support/Heeler/remote-desktop"
ML="$D/moonlight"
SUNBIN="$D/Sunshine.app/Contents/MacOS/Sunshine"
mkdir -p "$ML" "$(dirname "$SUNBIN")"
# 假 web-server / Sunshine：argv 留着绝对路径以便 pgrep -f 认出，进程要一直活着
cat > "$ML/web-server" <<'EOF'
#!/bin/bash
while :; do sleep 1; done
EOF
chmod +x "$ML/web-server"
cp "$ML/web-server" "$SUNBIN"
touch "$D/sunshine.conf" "$D/dev.heeler.rc.sunshine.plist"
printf 'heeler:stub-secret-password' > "$D/.webui-cred"
printf '{"bind_address":"127.0.0.1:52100"}' > "$ML/config.json"
printf '{"hostId":42,"appId":7}\n' > "$D/pair-state.json"
printf '{"version":"3","hosts":{"42":{"pair_info":{"client_certificate":"x"}}}}\n' > "$ML/data.json"

export PATH="$T/bin:$PATH" STUB_LOG="$T/stub.log" RC_HEARTBEAT_TIMEOUT=2
export STUB_SETUP='{"accessibility":"allowed","displays":"allowed","guiSession":"allowed","screenRecording":"allowed"}'

# 起一条会话，stdin 接 FIFO 写端（fd 9），可随时写心跳或关掉制造 EOF
open_session() {   # $1 = 名字
  rm -f "$T/$1.fifo"; mkfifo "$T/$1.fifo"
  : > "$T/$1.out"; : > "$T/$1.err"; : > "$STUB_LOG"
  /bin/bash "$SCRIPT" start < "$T/$1.fifo" > "$T/$1.out" 2> "$T/$1.err" &
  SESS_PID=$!
  exec 9> "$T/$1.fifo"
  local i=0
  while [ $i -lt 60 ] && [ ! -s "$T/$1.out" ]; do sleep 0.1; i=$((i+1)); done
}
close_stdin() { exec 9>&-; }
wait_gone() {   # $1=pid $2=秒：等它自己退出
  local i=0 n=$(($2*10))
  while [ $i -lt $n ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
running() { pgrep -f "$1" >/dev/null 2>&1; }
no_stub_left() { ! running "$ML/web-server" && ! running "$SUNBIN"; }
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

# ---- 1. 就绪：一行 JSON、字段、主显示器尺寸、先清残留再点亮再 bootstrap、web-server 在跑 ----
open_session ready
check "就绪：stdout 只有一行" '[ "$(grep -c . "$T/ready.out")" = 1 ]'
check "就绪：JSON 字段齐全（含 locked）" \
  '[ "$(jget ready "$T/ready.out")" = true ] && [ "$(jget port "$T/ready.out")" = 52100 ] && \
   [ "$(jget hostId "$T/ready.out")" = 42 ] && [ "$(jget appId "$T/ready.out")" = 7 ] && \
   [ "$(jget locked "$T/ready.out")" = true ]'
check "就绪：宽高取主显示器 1440x900" \
  '[ "$(jget width "$T/ready.out")" = 1440 ] && [ "$(jget height "$T/ready.out")" = 900 ]'
check "就绪：先 bootout 清残留、再 caffeinate、再 bootstrap" \
  'grep -q "^bootout gui/" "$STUB_LOG" && grep -q "^caffeinate -u" "$STUB_LOG" && \
   [ "$(grep -n "^bootout" "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n "^bootstrap" "$STUB_LOG" | head -1 | cut -d: -f1)" ]'
check "就绪：web-server 在跑" 'running "$ML/web-server"'

# ---- 2. stdin EOF：10 秒内清理 ----
close_stdin
check "EOF：2 秒内进程退出" 'wait_gone $SESS_PID 2'
check "EOF：web-server 与 Sunshine 都不在" 'no_stub_left'
check "EOF：launchctl bootout 被调用" 'grep -q "^bootout gui/" "$STUB_LOG"'

# ---- 3. 无心跳（测试里 2 秒）：10 秒内清理 ----
open_session timeout
check "超时前：会话还活着" 'kill -0 $SESS_PID 2>/dev/null'
check "超时：2 秒无心跳后退出且清理" 'wait_gone $SESS_PID 12 && no_stub_left'
close_stdin

# ---- 4. 心跳续命：每 1 秒一行，跨过 2 秒超时仍活着 ----
open_session heartbeat
for i in 1 2 3; do echo tick >&9; sleep 1; done
check "心跳：3 秒里每 1 秒一行，会话仍活着" 'kill -0 $SESS_PID 2>/dev/null && running "$ML/web-server"'
close_stdin
check "心跳：关 stdin 后 10 秒内清理" 'wait_gone $SESS_PID 10 && no_stub_left'

# ---- 5. TERM：10 秒内清理 ----
open_session term
check "TERM 前：web-server 在跑" 'running "$ML/web-server"'
kill -TERM $SESS_PID 2>/dev/null
check "TERM：10 秒内退出且两个进程都不在" 'wait_gone $SESS_PID 10 && no_stub_left'
close_stdin 2>/dev/null

# ---- 6. 启动前清残留（先确认上一节已完全退出，不然计数会撞车）----
close_stdin; wait_gone $SESS_PID 10
check "上一节收尾：没有残留进程" 'no_stub_left'
"$ML/web-server" & STALE1=$!
"$SUNBIN" & STALE2=$!
sleep 0.4
open_session leftover
check "残留：上一轮的两个进程已被收掉" 'reap $STALE1 && reap $STALE2 && ! kill -0 $STALE1 2>/dev/null && ! kill -0 $STALE2 2>/dev/null'
check "残留：本轮只有一个 web-server" '[ "$(pgrep -f "$ML/web-server" | wc -l | tr -d " ")" = 1 ] || pgrep -fl "$ML/web-server" >&2'
close_stdin; wait_gone $SESS_PID 10

# ---- 7. 口令不进 stdout / stderr，也不开 xtrace ----
check "口令：所有 stdout/stderr 里都没有明文" '! grep -q "stub-secret-password" "$T"/*.out "$T"/*.err'
check "口令：脚本里没有 xtrace 语句" '! grep -qE "^[[:space:]]*set[[:space:]]+-[a-zA-Z]*x" "$SCRIPT"'
check "口令：口令走 curl 的 -K 文件，不进 argv" '! grep -q "stub-secret" "$STUB_LOG"'

# ---- 8. 权限未授权：needsPermission，单行，退出 1 ----
: > "$T/perm.out"
STUB_SETUP='{"accessibility":"blocked","displays":"allowed","guiSession":"allowed","screenRecording":"blocked"}' \
  /bin/bash "$SCRIPT" start < /dev/null > "$T/perm.out" 2>&1
check "needsPermission：单行 JSON 且 error=needsPermission" \
  '[ "$(grep -c . "$T/perm.out")" = 1 ] && [ "$(jget ready "$T/perm.out")" = false ] && \
   [ "$(jget error "$T/perm.out")" = needsPermission ]'
check "needsPermission：清理过、没留下进程" 'grep -q "^bootout" "$T/stub.log" && no_stub_left'

# ---- 9. 未安装：notInstalled ----
: > "$T/ni.out"
HOME="$T/home2" /bin/bash "$SCRIPT" start < /dev/null > "$T/ni.out" 2>&1
check "notInstalled：单行 JSON 且 error=notInstalled" \
  '[ "$(grep -c . "$T/ni.out")" = 1 ] && [ "$(jget ready "$T/ni.out")" = false ] && \
   [ "$(jget error "$T/ni.out")" = notInstalled ]'

echo
if [ $FAILED -eq 0 ]; then echo "全部通过"; else echo "$FAILED 项失败"; fi
[ $FAILED -eq 0 ]
