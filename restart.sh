#!/usr/bin/env bash
# 改完 .env 后重启（重建容器以加载新环境变量）
set -euo pipefail
cd "$(dirname "$0")"
docker compose up -d --force-recreate
sleep 2
docker compose ps
