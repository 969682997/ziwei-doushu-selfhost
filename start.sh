#!/usr/bin/env bash
# 启动服务（幂等，可重复执行）
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || cp .env.example .env
docker compose up -d
PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r' || echo 28763)"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "已启动 → http://${IP:-127.0.0.1}:${PORT:-28763}"
docker compose ps
