#!/usr/bin/env bash
# 查看运行状态、健康检查与最近日志
set -uo pipefail
cd "$(dirname "$0")"
PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r' || echo 28763)"
echo "── 容器状态 ──"
docker compose ps
echo
echo "── 健康检查 ──"
curl -fsS "http://127.0.0.1:${PORT:-28763}/api/health" 2>/dev/null || echo "（无响应）"
echo
echo
echo "── 资源占用 ──"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | head -3
echo
echo "── 最近 30 行日志 ──"
docker compose logs --tail=30
