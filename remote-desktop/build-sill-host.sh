#!/bin/bash
# 从 vendor/sill 编出 release SillHost，包成 SillHost.app 并签名、压缩，打印 bundle id / 签名身份 / zip 的 sha256。
# 用法：bash remote-desktop/build-sill-host.sh [--out <目录>]
#   --out 默认 <repo>/build/sill-host（.gitignore 已忽略），产物：SillHost.app、SillHost.zip、SillHost.zip.sha256
# 为什么包 .app：屏幕录制和辅助功能按「bundle id + 签名的指定要求」记授权，裸二进制每次重编都丢。
# 固定 bundle id 和固定证书是升级后保住授权的前提；ad hoc 签名是这次构建的哈希，重编即失效。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SILL="$ROOT/vendor/sill"
OUT="$ROOT/build/sill-host"
BUNDLE_ID=dev.bybee.heeler.sillhost
IDENTITY=${SILL_SIGN_IDENTITY:-Apple Development: alex19960719@gmail.com (399B8A3B2L)}
NAME=SillHost

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }; OUT=$2; shift 2 ;;
    *) echo "usage: build-sill-host.sh [--out <dir>]" >&2; exit 2 ;;
  esac
done

die() { echo "error: $1" >&2; exit 1; }

[ -f "$SILL/Package.swift" ] || die "vendor/sill is missing (expected $SILL)"
mkdir -p "$OUT" || die "cannot create $OUT"
[ -z "$(ls -A "$OUT" 2>/dev/null | grep -vx 'SillHost.app\|SillHost.zip\|SillHost.zip.sha256')" ] \
  || die "$OUT holds something else; give an empty --out"

# 上游的构建缓存就放在 vendor/sill/.build（.gitignore 已忽略），重编只重链。
swift build -c release --product "$NAME" --package-path "$SILL" || die "swift build failed"
BIN="$(swift build -c release --product "$NAME" --package-path "$SILL" --show-bin-path)/$NAME"
[ -x "$BIN" ] || die "no binary at $BIN"

STAGE="$OUT/$NAME.app.partial"        # 先拼一个旁路目录，失败不留半个 bundle
rm -rf "$STAGE" "$OUT/$NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$NAME"
cp "$SILL/LICENSE" "$STAGE/Contents/Resources/LICENSE"    # Apache-2.0：许可证跟着二进制走
# Info.plist 用 printf 逐行写：Homebrew bash 5.3 遇到这类多行 XML heredoc 会卡死（2026-11-13 实测，
# /bin/bash 3.2 正常），而 App 里跑的是 /bin/bash，两种 shell 都得能跑。
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0">'
  printf '%s\n' '<dict>'
  printf '  <key>CFBundleIdentifier</key><string>%s</string>\n' "$BUNDLE_ID"
  printf '%s\n' '  <key>CFBundleName</key><string>SillHost</string>'
  printf '%s\n' '  <key>CFBundleExecutable</key><string>SillHost</string>'
  printf '%s\n' '  <key>CFBundlePackageType</key><string>APPL</string>'
  printf '%s\n' '  <key>CFBundleShortVersionString</key><string>0.0.0</string>'
  printf '%s\n' '  <key>CFBundleVersion</key><string>1</string>'
  printf '%s\n' '  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>'
  printf '%s\n' '  <key>LSMinimumSystemVersion</key><string>14.0</string>'
  # 无界面、无 Dock 图标：只由 LaunchAgent 按需起停
  printf '%s\n' '  <key>LSUIElement</key><true/>'
  printf '%s\n' '</dict>'
  printf '%s\n' '</plist>'
} > "$STAGE/Contents/Info.plist" || die "writing Info.plist failed"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# 整包签：先签二进制再签 bundle 会让 bundle 的印章作废，所以只签 bundle 一次。
codesign --force --options runtime --sign "$IDENTITY" "$STAGE" || die "codesign failed (identity: $IDENTITY)"
codesign --verify --strict "$STAGE" || die "codesign --verify failed"
mv "$STAGE" "$OUT/$NAME.app"

ditto -c -k --keepParent "$OUT/$NAME.app" "$OUT/$NAME.zip" || die "ditto failed"
( cd "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256" ) || die "shasum failed"

signed_id="$(codesign -dv --verbose=2 "$OUT/$NAME.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "built: $OUT/$NAME.app"
echo "bundle id: $(plutil -extract CFBundleIdentifier raw -o - "$OUT/$NAME.app/Contents/Info.plist")"
echo "signed by: ${signed_id:-unknown}"
echo "zip sha256: $(cut -d' ' -f1 "$OUT/$NAME.zip.sha256")"
