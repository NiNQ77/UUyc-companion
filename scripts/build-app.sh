#!/bin/zsh
# 构建 UUDisplay.app（ad-hoc 签名）。用法：scripts/build-app.sh [--install]
# --install：复制到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
APP="build/UUDisplay.app"

swift build -c release --build-system native --product UUDisplay
BIN="$(swift build -c release --build-system native --show-bin-path)/UUDisplay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UUDisplay"
# 看门狗用独立文件名，避免 killall/pkill UUDisplay 时连同看门狗一起结束
cp "$BIN" "$APP/Contents/MacOS/UUDisplayWatchdog"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.corndog.uudisplay</string>
  <key>CFBundleName</key><string>UUDisplay</string>
  <key>CFBundleDisplayName</key><string>UU远程分辨率伴侣</string>
  <key>CFBundleExecutable</key><string>UUDisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# 看门狗 LaunchAgent（SMAppService.agent 注册，KeepAlive 保证被杀后自动拉起）
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.corndog.uudisplay.watchdog.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.corndog.uudisplay.watchdog</string>
  <key>BundleProgram</key><string>Contents/MacOS/UUDisplayWatchdog</string>
  <key>ProgramArguments</key><array><string>UUDisplayWatchdog</string><string>--watchdog</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier com.corndog.uudisplay "$APP"
echo "✅ 已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x UUDisplay 2>/dev/null && sleep 1 || true
  pkill -x UUDisplayWatchdog 2>/dev/null || true
  rm -rf /Applications/UUDisplay.app
  cp -R "$APP" /Applications/
  open /Applications/UUDisplay.app
  echo "✅ 已安装到 /Applications 并启动"
fi
