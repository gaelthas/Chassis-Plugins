#!/bin/bash
# 把仓库里的 Swift 插件编译成可导入的 .chassisplugin 包。
#
# 用法：
#   ./Scripts/package-plugins.sh              # 打包全部
#   ./Scripts/package-plugins.sh UsageStatistics
#
# 原理：插件与基座共享 PluginAPI 类型，因此插件编译成动态库并用
# `-undefined dynamic_lookup` 在加载时从基座可执行文件解析符号（基座已用
# `-export_dynamic` 导出）。这样既不需要 C ABI 胶水，也不会出现两份 PluginAPI。
set -euo pipefail
cd "$(dirname "$0")/.."

HOST_ROOT="$(cd .. && pwd)"
MODULES="$HOST_ROOT/.build/debug/Modules"
ATOMICS="$HOST_ROOT/.build/arm64-apple-macosx/debug/AtomicsShim.build"
DIST="$(pwd)/dist"
ONLY="${1:-}"

# 与基座使用同一个开发证书签名：这样插件与基座 Team 相同，
# 安装策略（默认只信任同 Team）与 Library Validation 都自然满足，
# UI 也能据此区分「官方」与「第三方」。
IDENTITY="${CHASSIS_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
  echo "签名身份：$IDENTITY"
else
  echo "⚠️  未找到 Apple Development 证书，插件将使用 ad-hoc 签名（基座会视为第三方）" >&2
fi

if [ ! -f "$MODULES/PluginAPI.swiftmodule" ]; then
  echo "== 准备 PluginAPI 模块 =="
  (cd "$HOST_ROOT" && swift build >/dev/null)
fi

mkdir -p "$DIST"

package() {
  local name="$1" id="$2"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi

  local src="Packages/$name"
  local bundle="$DIST/$name.chassisplugin"
  local manifest="Manifests/$id.json"

  [ -d "$src" ] || { echo "跳过 $name：源码目录不存在" >&2; return 0; }
  [ -f "$manifest" ] || { echo "跳过 $name：缺少清单 $manifest" >&2; return 0; }

  echo "== 打包 $name =="
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

  local sources=()
  while IFS= read -r file; do sources+=("$file"); done < <(find "$src" -name '*.swift' | sort)

  swiftc -emit-library -O -swift-version 5 \
    -module-name "$name" \
    -I "$MODULES" \
    -I "$ATOMICS" \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -framework SwiftUI -framework AppKit -framework CoreGraphics \
    -framework ApplicationServices -framework ScreenCaptureKit \
    -framework Carbon -framework UserNotifications \
    -target arm64-apple-macos14.0 \
    -o "$bundle/Contents/MacOS/$name" \
    "${sources[@]}"

  if [ -d "$src/Resources" ]; then
    cp -R "$src/Resources/"*.lproj "$bundle/Contents/Resources/" 2>/dev/null || true
  fi
  cp "$manifest" "$bundle/Contents/Resources/manifest.json"

  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$id</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleExecutable</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

  if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$bundle" >/dev/null
  else
    codesign --force --sign - --timestamp=none "$bundle" >/dev/null
  fi
  codesign --verify --strict "$bundle"
  echo "   → $bundle"
}

package DockActions        com.gaelthas.plugin.dock-actions
package SlowQuit           com.gaelthas.plugin.slow-quit
package WindowSwitcher     com.gaelthas.plugin.window-switcher
package DockHoverPreview   com.gaelthas.plugin.dock-hover-preview
package UsageStatistics    com.gaelthas.plugin.usage-statistics

echo
echo "插件包目录：$DIST"
