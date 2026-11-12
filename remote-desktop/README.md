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

## 许可证

Sunshine 与 moonlight-web-stream 是 GPL-3.0，只在用户自己的电脑上作为独立进程运行；随 Heeler 分发的
只有本目录这两个启动脚本。它们与 App 之间只隔 SSH 和 HTTP，不链接进 App。
