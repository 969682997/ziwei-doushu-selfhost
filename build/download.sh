#!/usr/bin/env bash
# 下载 v4.0 数据集全部 77 个年份文件（带重试，GitHub release 偶发 502）
set -u
cd "$(dirname "$0")"
mkdir -p raw
BASE="https://github.com/Renhuai123/ziwei-doushu/releases/download/v4.0-13d"

fetch() {
  local y=$1
  local f="raw/year-$y.jsonl.zst"
  if [ -s "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 1500000 ]; then
    echo "SKIP $y"
    return 0
  fi
  for i in 1 2 3 4 5 6 7 8; do
    if curl -sfL --retry 2 --retry-delay 1 --connect-timeout 20 --max-time 240 \
         "$BASE/year-$y.jsonl.zst" -o "$f"; then
      echo "OK   $y  $(stat -c%s "$f")"
      return 0
    fi
    sleep 2
  done
  echo "FAIL $y"
  return 1
}
export -f fetch
export BASE

seq 1950 2026 | xargs -P 6 -I{} bash -c 'fetch {}'

echo "=== 汇总 ==="
ls raw/*.zst 2>/dev/null | wc -l
du -sh raw 2>/dev/null
