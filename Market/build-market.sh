#!/bin/bash
# 生成插件市场索引（默认指向本地文件，便于开发期联调）。
set -euo pipefail
cd "$(dirname "$0")"

DIST="../Examples/dist"
BASE="${MARKET_BASE_URL:-file://$(cd .. && pwd)/Market/packages}"

if [ ! -d "$DIST" ]; then
  echo "未找到 $DIST，请先运行 ../Examples/build-hello.sh" >&2
  exit 1
fi

swift make-index.swift --dist "$DIST" --out-dir packages --base "$BASE" --out index.json --key .market-key

echo
echo "索引：$(pwd)/index.json"
echo "本地预览：python3 -m http.server 8765 --directory \"$(pwd)\""
