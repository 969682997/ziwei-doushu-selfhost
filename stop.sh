#!/usr/bin/env bash
# 停止服务（保留容器与镜像，可用 start.sh 快速拉起）
set -euo pipefail
cd "$(dirname "$0")"
docker compose stop
echo "已停止。重新启动： ./start.sh"
