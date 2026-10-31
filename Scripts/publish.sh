#!/bin/bash
# 发布插件到市场：只重建被点名的插件，索引里其它插件沿用上一版包文件。
#
# 用法：
#   ./Scripts/publish.sh                          # 全部插件按当前清单版本重新打包并重建索引
#   ./Scripts/publish.sh SlowQuit                 # 只发布 SlowQuit（版本不变）
#   ./Scripts/publish.sh --bump patch SlowQuit    # 先把 SlowQuit 补丁号 +1，再发布
#   ./Scripts/publish.sh --bump minor DockActions WindowSwitcher
#
# 产物：Market/packages/<id>-<version>.zip 与签名后的 Market/index.json
# 之后把 Market/ 一起提交推送即可（推荐用 GitHub Pages 或 raw.githubusercontent 托管）。
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP=""
if [ "${1:-}" = "--bump" ]; then
  BUMP="${2:-patch}"
  shift 2
fi
TARGETS=("$@")

BASE="${MARKET_BASE_URL:-https://raw.githubusercontent.com/gaelthas/Chassis-Plugins/main/Market/packages}"
MARKET_DIR="Market"
PACKAGE_DIR="$MARKET_DIR/packages"
mkdir -p "$PACKAGE_DIR"

# 名称 → 插件 ID
plugin_id() {
  case "$1" in
    DockActions)      echo "com.gaelthas.plugin.dock-actions" ;;
    SlowQuit)         echo "com.gaelthas.plugin.slow-quit" ;;
    WindowSwitcher)   echo "com.gaelthas.plugin.window-switcher" ;;
    DockHoverPreview) echo "com.gaelthas.plugin.dock-hover-preview" ;;
    UsageStatistics)  echo "com.gaelthas.plugin.usage-statistics" ;;
    KeyboardStatistics) echo "com.gaelthas.plugin.keyboard-statistics" ;;
    *) echo "" ;;
  esac
}

ALL_PLUGINS=(DockActions SlowQuit WindowSwitcher DockHoverPreview UsageStatistics KeyboardStatistics)
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("${ALL_PLUGINS[@]}")
fi

for name in "${TARGETS[@]}"; do
  id="$(plugin_id "$name")"
  if [ -z "$id" ]; then
    echo "未知插件：$name（可选：${ALL_PLUGINS[*]}）" >&2
    exit 2
  fi
  manifest="Manifests/$id.json"

  if [ -n "$BUMP" ]; then
    python3 - "$manifest" "$BUMP" <<'PY'
import json, sys
path, kind = sys.argv[1], sys.argv[2]
data = json.load(open(path))
parts = [int(x) for x in data["version"].split(".")]
while len(parts) < 3:
    parts.append(0)
major, minor, patch = parts[:3]
if kind == "major":
    major, minor, patch = major + 1, 0, 0
elif kind == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1
data["version"] = f"{major}.{minor}.{patch}"
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
print(f"   {data['id']} → v{data['version']}")
PY
  fi

  version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")"
  echo "== 发布 $name v$version =="

  bash Scripts/package-plugins.sh "$name"

  archive="$PACKAGE_DIR/$id-$version.zip"
  rm -f "$archive"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "dist/$name.chassisplugin" "$archive"
  echo "   包：$archive"
done

echo "== 重建索引 =="
swift "$MARKET_DIR/make-index.swift" \
  --manifests Manifests \
  --packages "$PACKAGE_DIR" \
  --base "$BASE" \
  --out "$MARKET_DIR/index.json" \
  --key "$MARKET_DIR/.market-key"

echo
echo "下一步："
echo "  git add Manifests Market && git commit -m \"release: $(printf '%s ' "${TARGETS[@]}")\" && git push"
echo "  基座市场地址：${BASE%/packages}/index.json"
