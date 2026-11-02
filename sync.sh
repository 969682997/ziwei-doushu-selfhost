#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 一条命令同步线上代码
#
#   ./sync.sh
#
# 做的事：拉代码 → 判断该不该重建镜像 → 部署 → 健康检查
#         → 失败则自动回滚到上一个提交并重新部署
#
# 大数据（data/interp.db）不进 git，这里完全不碰它。
# 用普通用户执行，需要 root 时会自己调 sudo。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

say ""
say "同步线上代码"
say "─────────────────────────────────────────────"

# ── 0. 必须是 git 仓库 ──
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "当前目录不是 git 仓库（很可能是从安装包解压的）"
  say ""
  say "  想改用 git 同步，执行下面四步即可接管，不会动 data/ 和 .env："
  say "    git init -b main"
  say "    git remote add origin <仓库地址>"
  say "    git fetch origin main"
  say "    git reset --hard origin/main"
  say ""
  say "  ${DIM}data/interp.db 与 .env 都在 .gitignore 里，不会被覆盖。${RST}"
  exit 1
fi
git remote get-url origin >/dev/null 2>&1 || die "未配置远程仓库，先执行：git remote add origin <仓库地址>"

# ── 1. 工作区必须干净 ──
if [ -n "$(git status --porcelain)" ]; then
  warn "工作区有未提交的改动，先处理再同步："
  git status --short | sed 's/^/    /'
  say ""
  say "  ${DIM}保留改动：git stash    放弃改动：git checkout -- .${RST}"
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
OLD="$(git rev-parse HEAD)"

# ── 2. 拉取并比较 ──
say "拉取 origin/${BRANCH} …"
git fetch --quiet origin "$BRANCH" || die "拉取失败：检查网络，或 git remote 配置是否正确"

NEW="$(git rev-parse "origin/${BRANCH}")"

if [ "$OLD" = "$NEW" ]; then
  ok "已是最新（$(git log -1 --format='%h %s')）"
  say "  服务未重启。"
  exit 0
fi

say "  ${DIM}本次更新 $(git rev-parse --short "$OLD") → $(git rev-parse --short "$NEW")${RST}"
say ""

CHANGED="$(git diff --name-only "$OLD" "$NEW")"
COUNT="$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')"
say "变更 ${COUNT} 个文件："
printf '%s\n' "$CHANGED" | head -20 | sed 's/^/    /'
[ "$COUNT" -gt 20 ] && say "    … 其余 $((COUNT - 20)) 个"

git merge --ff-only -q "origin/${BRANCH}" || die "快进合并失败（本地有分叉），需要手动处理"
ok "代码已更新到 $(git rev-parse --short HEAD)"

# ── 3. 判断需要做到哪一步 ──
NEED_BUILD=0
NEED_RECREATE=0
printf '%s\n' "$CHANGED" | grep -q '^app/'                     && NEED_BUILD=1
printf '%s\n' "$CHANGED" | grep -q '^docker-compose\.yml$'     && NEED_RECREATE=1

if printf '%s\n' "$CHANGED" | grep -q '^\.env\.example$'; then
  say ""
  warn ".env.example 有变化，请核对 .env 是否需要补新配置项（不会自动覆盖你的 .env）"
  git diff "$OLD" "$NEW" -- .env.example | grep '^[+-][A-Z]' | sed 's/^/    /' || true
fi

if [ "$NEED_BUILD" = "0" ] && [ "$NEED_RECREATE" = "0" ]; then
  say ""
  ok "只有文档或部署脚本变化，镜像无需重建，容器无需重启"
  exit 0
fi

# ── 4. 部署 ──
run_deploy() {
  if [ "$NEED_BUILD" = "1" ]; then
    say ""
    say "代码有变化，重建镜像并部署（约 1–4 分钟）…"
    sudo ./deploy.sh
  else
    say ""
    say "仅编排配置变化，重建容器（不重建镜像）…"
    sudo docker compose up -d --force-recreate
  fi
}

if run_deploy; then
  say ""
  ok "同步完成：$(git log -1 --format='%h %s')"
  exit 0
fi

# ── 5. 失败回滚 ──
say ""
warn "部署失败，回滚到 $(git rev-parse --short "$OLD") 并重新部署"
say "  ${DIM}失败的那次提交仍留在 origin/${BRANCH} 上，日志在上面${RST}"

git reset --hard -q "$OLD"
NEED_BUILD=1   # 回滚后必须重建，否则镜像还是坏的那版
if run_deploy; then
  say ""
  warn "已回滚到 $(git rev-parse --short "$OLD")，服务恢复。请修好 $(git rev-parse --short "$NEW") 后再推。"
else
  say ""
  die "回滚后仍未就绪，需要人工介入：
    sudo docker compose logs --tail=100
    sudo ./deploy.sh"
fi
exit 1
