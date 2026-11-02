#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 紫微斗数自建站 · 一键部署
# 适用：Ubuntu 22.04 / 24.04 x86_64
# 用法：sudo ./deploy.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

say ""
say "紫微斗数自建站 · 部署"
say "────────────────────────────"

# 1. 依赖检查
command -v docker >/dev/null 2>&1 || die "未安装 Docker。请先执行：curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || die "未安装 Docker Compose v2（docker compose）。请升级 Docker 到 20.10+"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# 2. 数据检查
if [ ! -f data/interp.db ]; then
  die "缺少 data/interp.db（解读数据库，662 MB）。
    它不进 git 仓库，需要手动放到 data/ 一次：
      • 有安装包：tar xzf ziwei-selfhost-1.0.0.tar.gz -C /tmp \\
                  && cp /tmp/ziwei-selfhost-1.0.0/data/interp.db data/
      • 有 Release 直链：curl -L -o data/interp.db '<直链>'
      • 都没有：bash build/download.sh && python3 build/build_db.py"
fi
DBMB=$(( $(stat -c%s data/interp.db) / 1024 / 1024 ))
ok "解读数据库 ${DBMB} MB"

# 2b. 校验数据库完整性（662 MB 文件经上传/解压后可能损坏，坏库只会表现为「查不到盘」）
if [ -f data/interp.db.sha256 ] && [ "${SKIP_DB_VERIFY:-0}" != "1" ]; then
  printf '校验数据库（约 3 秒）'
  if ( cd data && sha256sum -c interp.db.sha256 --status 2>/dev/null ); then
    printf '\n'; ok "数据库校验通过"
  else
    printf '\n'
    die "数据库校验失败 —— 文件在传输或解压中损坏。
    请重新上传安装包并重新解压（不要用 FTP ASCII 模式）。
    若确认文件无误仍报错，可用 SKIP_DB_VERIFY=1 sudo ./deploy.sh 跳过校验。"
  fi
fi

# 3. 配置
if [ ! -f .env ]; then
  cp .env.example .env
  warn "已生成 .env，请填写 PACKYCODE_API_KEY"
fi
# Windows 记事本/VS Code 默认 CRLF，会让 HOST_PORT 变成 "28763\r"，
# 表现为端口解析异常或 compose 报 invalid port。这里直接修正。
# 用 tr 比较而非 grep -q $'\r'，后者在部分环境（Git Bash / busybox）不可靠。
if [ "$(cat .env)" != "$(tr -d '\r' < .env)" ]; then
  sed -i 's/\r$//' .env
  warn ".env 是 Windows 换行（CRLF），已自动转为 Unix 换行"
fi
set -a; . ./.env; set +a
PORT="${HOST_PORT:-28763}"

if [ -z "${PACKYCODE_API_KEY:-}" ]; then
  warn "PACKYCODE_API_KEY 为空 —— 站点可正常排盘和看 13 维解读，但 AI 追问会提示未配置。"
  warn "填好 .env 后执行 ./restart.sh 即可启用。"
else
  ok "AI 已配置：${PACKYCODE_MODEL:-未指定模型}"
fi

# 4. 端口占用检查
# 更新时端口必然已被本服务自己的容器占用，不能误判成「冲突」。
# 先看是不是我们自己的容器在监听这个端口，是就放行（后面会 recreate）。
OWN=$(docker ps -q --filter "name=^/ziwei$" --filter "publish=${PORT}" 2>/dev/null || true)
if [ -z "$OWN" ] && ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  die "端口 ${PORT} 已被其他程序占用，请修改 .env 里的 HOST_PORT"
fi

# 5. 构建镜像
say ""
say "构建镜像（首次约 3–6 分钟，取决于网络）…"
docker compose build

# 6. 启动
say ""
say "启动容器…"
docker compose up -d

# 7. 等待健康
say ""
printf '等待服务就绪'
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    printf '\n'; ok "服务已就绪"; READY=1; break
  fi
  printf '.'; sleep 2
  [ "$i" = 60 ] && { printf '\n'; READY=0; }
done

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "${IP:-}" ] && IP="<服务器IP>"

# 清理构建缓存，释放约 2–3 GB
docker builder prune -f >/dev/null 2>&1 || true

say ""
if [ "${READY:-0}" = "1" ]; then
  curl -fsS "http://127.0.0.1:${PORT}/api/health" | head -c 300; say ""
  say ""
  say "────────────────────────────"
  say "  访问地址： ${GRN}http://${IP}:${PORT}${RST}"
  say "────────────────────────────"
  say "  常用命令："
  say "    ./check-ai.sh  验证大模型是否连通"
  say "    ./start.sh     启动"
  say "    ./stop.sh      停止"
  say "    ./restart.sh   改完 .env 后重启"
  say "    ./status.sh    查看状态与日志"
  say ""
  say "  磁盘占用：$(df -h . | awk 'NR==2{print $3" / "$2"（可用 "$4"）"}')"
  say "  ${DIM}安装包已用完，可删除以再省 700 MB：rm -f $(ls ../*.tar.gz 2>/dev/null | head -1 || echo '<安装包>.tar.gz')${RST}"
  say ""
  say "${DIM}如在国内云服务器上，请到安全组放行 ${PORT} 端口。${RST}"
else
  warn "服务未在预期时间内就绪，请查看日志：docker compose logs --tail=80"
  exit 1
fi
