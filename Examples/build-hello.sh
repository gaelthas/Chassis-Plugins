#!/bin/bash
# 构建示例外部插件并打包成 .chassisplugin（ad-hoc 签名，仅本地测试）。
set -euo pipefail

cd "$(dirname "$0")/HelloPlugin"

echo "== 构建动态库 =="
swift build -c release --product HelloPlugin
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/libHelloPlugin.dylib"
[ -f "$BIN" ] || { echo "未找到 $BIN" >&2; exit 1; }

DIST="$(cd .. && pwd)/dist"
BUNDLE="$DIST/HelloPlugin.chassisplugin"

echo "== 组装插件包 =="
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/HelloPlugin"
cp manifest.json "$BUNDLE/Contents/Resources/manifest.json"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.chassis.hello</string>
    <key>CFBundleName</key>
    <string>HelloPlugin</string>
    <key>CFBundleExecutable</key>
    <string>HelloPlugin</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

echo "== 签名（ad-hoc，仅本地测试）=="
# 整包签名：清单放在 Contents/Resources，Contents 根下只有 Info.plist，不会被当作嵌套代码。
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"

echo "BUNDLE: $BUNDLE"
