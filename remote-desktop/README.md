# 电脑端远程桌面（rc-session）

Heeler 手机端经 SSH 控制这台 Mac 时电脑端跑这一套：随 App 带来的 SillHost 由 launchd 起，
只监听 127.0.0.1，手机端经 SSH 隧道连到那个端口。只写
`~/Library/Application Support/Heeler/remote-desktop/`（0700），不开机自启。

## 调用方式

App 把脚本写到 `<上述目录>/bin/rc-session.sh`（0700），再经 SSH 执行：

```bash
bash "<dir>/bin/rc-session.sh" start   # 每次开远程桌面（心跳走 stdin）
```

`bash rc-session.sh start sill` 和不写引擎名等价；别的引擎名（包括旧版的 `sunshine`）是用法错误，
退出 2。脚本单文件自包含，兼容 macOS 自带的 `/bin/bash` 3.2，也能在电脑上直接跑。

## 目录布局

```
remote-desktop/
├── SillHost.app/Contents/MacOS/SillHost     随 App 带来的 Host（固定 bundle id 与签名）
├── dev.heeler.rc.sillhost.plist             launchctl bootstrap gui/<uid> 用
├── sillhost.out.log  sillhost.err.log       SillHost 的输出
└── .session-owner                           当前会话的 PID
```

## JSON 协议（stdout 只有一行）

- 成功：`{"ready":true,"port":<端口>,"locked":<bool>}`
- 失败：`{"ready":false,"error":"<code>","detail":"…"}` 后退出 1

错误码：`notInstalled`、`noGuiSession`、`sillFailed`。

## 生命周期

`start` 先清残留（`bootout` 旧版 Sunshine 的 label 和本套件的 label，再兜底按绝对路径杀掉还活着的
SillHost）→ `caffeinate -u -t 5` 点亮屏幕 → `launchctl bootstrap gui/<uid>` 起 SillHost →
从 `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` 读出监听端口（端口是系统随机分的，CLI 不打印）→
打就绪行 → 等 stdin 心跳。

心跳每行一次 `read -t 45`；stdin 关闭、45 秒没心跳、收到 TERM/HUP/INT，都 `bootout` 关 SillHost。
连上那一刻锁着屏的，退出时 `pmset displaysleepnow` 熄屏让它立刻再锁上。

### 旧版残留

升级前装过 Sunshine 的 Mac 可能还 loaded 着 `dev.heeler.rc.sunshine`，它占着硬件编码器。每次 `start`
都 `bootout` 一次那个 label，但**不删用户 Mac 上的任何文件**。

### SillHost 的启动参数

`SillHost.app/Contents/MacOS/SillHost --virtual-display --no-advertise --no-clipboard`，环境
`SILL_TEST_LOOPBACK=1`。`--no-advertise` 让它不上 Bonjour、只听 `127.0.0.1`；脚本还会核对一遍
监听地址，越出回环就报 `sillFailed`。收尾先 `bootout`（它收到 SIGTERM 会先把串流的窗口放回原位），
等最多 10 s 再兜底 `pkill`。

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

## 测试

```bash
bash remote-desktop/test-rc-session.sh
```

PATH 前置假的 `launchctl` / `caffeinate` / `ioreg` / `lsof`，不碰真的 launchd、屏幕和网络。

## 许可证

SillHost 来自 [Sill](https://github.com/Saffsanity/sill)（Apache-2.0），快照在 `vendor/sill`，
本仓库的改动在 `vendor/sill-patches`。`build-sill-host.sh` 会把 `LICENSE` 拷进
`SillHost.app/Contents/Resources/`。
