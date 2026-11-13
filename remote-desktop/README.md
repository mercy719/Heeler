# 电脑端远程桌面（rc-setup / rc-session）

Heeler 手机端经 SSH 控制这台 Mac 时电脑端跑这一套：Sunshine 抓屏编码，Moonlight Web 在 127.0.0.1 上
提供页面和 WebSocket 视频流。只写 `~/Library/Application Support/Heeler/remote-desktop/`（0700），
不碰 OpenBot 的目录、进程和 LaunchAgent，不开机自启。

## 调用方式

App 先把两个脚本写到 `<上述目录>/bin/`（0700），再经 SSH 执行：

```bash
bash "<dir>/bin/rc-setup.sh" install   # 首次：拷贝、下载、写配置、生成凭据、配对
bash "<dir>/bin/rc-setup.sh" status    # 只读：installed / needsPermission / paired
bash "<dir>/bin/rc-session.sh" start   # 每次开远程桌面（心跳走 stdin）
```

`install` 选填 `--archive <本地 tar.gz>` 跳过下载、`--creds` 强制换口令。两个脚本单文件自包含、
兼容 macOS 自带的 `/bin/bash` 3.2，也能在电脑上直接跑。

## 目录布局

```
remote-desktop/
├── Sunshine.app                     从 OpenBot.app ditto 拷来的运行时
├── sunshine.conf  sunshine-apps.json  sunshine-credentials.json  *-key/cert.pem
├── sunshine-state.json              已配对设备
├── dev.heeler.rc.sunshine.plist     launchctl bootstrap gui/<uid> 用
├── .webui-cred  .moonlight-cred     口令，0600，只本机脚本读
├── pair-state.json                  {"hostId":..,"appId":..}
└── moonlight/  web-server  static/  config.json  data.json
```

端口全在回环：51989 GameStream、51984 HTTPS、51990 Web UI、52010 RTSP、52100 Moonlight Web。

## JSON 协议（stdout 只有一行）

- `rc-session start` 成功：`{"ready":true,"port":52100,"hostId":..,"appId":..,"width":..,"height":..,"locked":<bool>}`
- `rc-setup install` 成功：`{"installed":true,"needsPermission":<bool>}`
- `rc-setup status`：`{"installed":true,"needsPermission":<bool>,"paired":<bool>}`

失败一律 `{"ready":false,...}` / `{"installed":false,...}` 后退出 1。错误码：`notInstalled`、
`needsPermission`、`noGuiSession`、`sunshineFailed`、`webServerFailed`、`notPaired`、`downloadFailed`、
`shaMismatch`、`pairFailed`。

## 生命周期

`start` 先清残留 → `caffeinate -u -t 5` 点亮屏幕（显示器睡着时 Sunshine 起不来，点亮不需要密码、
不会解锁）→ `launchctl bootstrap gui/<uid>` 起 Sunshine → 轮询 `/api/openbot/setup` 最多 20 秒 →
起 web-server（静态页按相对路径找，必须在 moonlight 目录里启动）→ 打就绪行 → 等 stdin 心跳。

心跳每行一次 `read -t 45`；stdin 关闭、45 秒没心跳、收到 TERM/HUP/INT，都 `bootout` 关 Sunshine 并杀
web-server。锁屏只体现在 `locked` 字段，不阻止启动。

## 首次手动授权（只能人来点）

1. 跑一次 `install`，会报 `needsPermission`。
2. 系统设置 → 隐私与安全性 →「屏幕与系统音频录制」加入
   `~/Library/Application Support/Heeler/remote-desktop/Sunshine.app` 并勾上；「辅助功能」同样一次。
3. 再跑 `status`，`needsPermission` 变 `false`。

拷出来的 Sunshine 是独立 TCC 条目（`dev.lizardbyte.app.Sunshine`），不继承 OpenBot 的授权。
`system_tray = disabled` 是必须的：开着托盘会在配对时把 Sunshine 打崩（非主线程改 AppKit 状态 trap）。

## sill 引擎（`start sill`）

`bash rc-session.sh start sill`（或 `RC_ENGINE=sill`）起的是随 App 带过来的 SillHost，替下
Sunshine + Moonlight Web。默认仍是 `sunshine`，两条路共用同一套骨架：归属文件、清残留、
`caffeinate -u -t 5` 与 `caffeinate -d -w $$`、一行就绪 JSON、15 s 心跳 / 45 s 超时、锁着进来退出时熄屏重锁。
起哪套都先把另一套清掉：两边都占 Mac 的硬件编码器。

sill 的路子：`SillHost.app/Contents/MacOS/SillHost --virtual-display --no-advertise --no-clipboard`，
环境 `SILL_TEST_LOOPBACK=1`，由 `launchctl bootstrap gui/<uid> "$DIR/dev.heeler.rc.sillhost.plist"` 起。
`--no-advertise` 让它不上 Bonjour、只听 `127.0.0.1`；手机端经 App 自己的 SSH 隧道连到那个端口，
SSH 登录就是配对。端口是系统随机分的、CLI 不打印，脚本用 `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` 读出来，
填进就绪 JSON 的 `port`；Sunshine 专用的 `hostId / appId` 填 0。收尾先 `bootout`
（它收到 SIGTERM 会先把串流的窗口放回原位），等最多 10 s 再兜底 `pkill`。

### 构建 Mac 端

```bash
bash remote-desktop/build-sill-host.sh              # 产物在 build/sill-host/
bash remote-desktop/build-sill-host.sh --out <dir>
```

从 `vendor/sill` 编 release `SillHost`，包成 `SillHost.app`（固定 bundle id
`dev.bybee.heeler.sillhost`、最小 Info.plist、`LSUIElement`），用
`Apple Development: alex19960719@gmail.com (399B8A3B2L)` 整包签名，产出 `SillHost.zip` 和它的 sha256。
连续两次构建的 bundle id 和签名身份不变，这是升级后保住 TCC 授权的前提。

### 首次授权：授权对象是 SillHost.app

屏幕录制和辅助功能按「bundle id + 签名的指定要求」记，所以只有包成 .app、用固定证书签、
并且由 LaunchAgent 直接起 `.app` 里的可执行文件，授权才不会每次升级就丢。

1. 把 `SillHost.app` 放在
   `~/Library/Application Support/Heeler/remote-desktop/SillHost.app`
   （即 `Contents/MacOS/SillHost` 就是会话脚本起的那个）。
2. 系统设置 → 隐私与安全性 →「屏幕与系统音频录制」加入上面那个 `SillHost.app` 并勾上；
   「辅助功能」同样一次。
3. 同一个 LaunchAgent 跑一次自检，它打印这两个值：

   ```bash
   bash remote-desktop/rc-session.sh start sill   # 第一次会照常开流；授权前画面是黑的
   ```

   没有授权时，`~/Library/Application Support/Heeler/remote-desktop/sillhost.out.log` 里能看到
   `Input needs Accessibility permission` 一类的话。

检查授权状态可以用同一个 LaunchAgent 跑自检（它会顺带验证虚拟显示器）：

```bash
launchctl bootstrap gui/$(id -u) <plist>     # ProgramArguments 末尾换成 --virtual-display-selftest
```

输出里的 `Screen Recording preflight: …` 和 `Accessibility trusted: …` 都是 `true` 才算齐。

## 许可证

Sunshine 与 moonlight-web-stream 是 GPL-3.0，只在用户自己的电脑上作为独立进程运行；随 Heeler 分发的
只有本目录这两个启动脚本。它们与 App 之间只隔 SSH 和 HTTP，不链接进 App。

SillHost 来自 [Sill](https://github.com/Saffsanity/sill)（Apache-2.0），快照在 `vendor/sill`，
本仓库的改动在 `vendor/sill-patches`。`build-sill-host.sh` 会把 `LICENSE` 拷进
`SillHost.app/Contents/Resources/`。
